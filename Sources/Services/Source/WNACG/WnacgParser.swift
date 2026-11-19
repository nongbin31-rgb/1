import Foundation
import SwiftSoup

/// 绅士漫画 (WNACG) 分类、URL 清洗与 DOM/FastLoad 解析工具
public enum WnacgParser {
    public static let cateLabelMap: [String: String] = [
        "1": "同人志 / 汉化",
        "2": "同人志 / CG画集",
        "3": "写真 & Cosplay",
        "5": "同人志",
        "6": "单行本",
        "7": "杂志&短篇",
        "9": "单行本 / 汉化",
        "10": "杂志&短篇 / 汉化",
        "12": "同人志 / 日语",
        "13": "单行本 / 日语",
        "14": "杂志&短篇 / 日语",
        "16": "同人志 / English",
        "17": "单行本 / English",
        "18": "杂志&短篇 / English",
        "19": "韩漫",
        "20": "韩漫 / 汉化",
        "21": "韩漫 / 生肉",
        "22": "3D&漫画",
        "23": "3D&漫画 / 汉化",
        "24": "3D&漫画 / 其他",
        "37": "AI&图集",
    ]

    private static let cateClassRegex = try! NSRegularExpression(pattern: #"\bcate-(\d+)\b"#)
    private static let aidRegex = try! NSRegularExpression(pattern: #"aid-(\d+)"#)
    private static let pageUrlArrayRegex = try! NSRegularExpression(
        pattern: #""?page_url"?\s*:\s*\[(.*?)\]"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let quotedUrlRegex = try! NSRegularExpression(
        pattern: #"(?:"|')((?:https?:)?(?://|/)[^"'\s]+)(?:"|')"#
    )

    public static func extractCategoryTagFromClass(_ rawClass: String) -> String? {
        let range = NSRange(rawClass.startIndex..<rawClass.endIndex, in: rawClass)
        guard let match = cateClassRegex.firstMatch(in: rawClass, range: range),
              match.numberOfRanges > 1,
              let r1 = Range(match.range(at: 1), in: rawClass) else {
            return nil
        }
        return cateLabelMap[String(rawClass[r1])]
    }

    public static func cleanWnacgUrl(_ raw: String, baseUrl: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return "" }

        if url.hasPrefix("//") {
            let trimmedSlashes = url.drop(while: { $0 == "/" })
            url = "https://\(trimmedSlashes)"
        } else if url.hasPrefix("/") {
            var base = baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            while base.hasSuffix("/") { base.removeLast() }
            url = "\(base)\(url)"
        } else if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") {
            if let range = url.range(of: #"^https?:/+"#, options: [.regularExpression, .caseInsensitive]) {
                url.replaceSubrange(range, with: "https://")
            }
        }
        return url
    }

    public static func normalizeCategory(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "／", with: " / ")
            .replacingOccurrences(of: #"\s*/\s*"#, with: " / ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstAidMatch(in text: String) -> String? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = aidRegex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let r1 = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[r1])
    }

    public static func parseListHtml(_ html: String, baseUrl: String, sourceID: String) -> [Manga] {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        guard let doc = try? SwiftSoup.parse(html),
              let elements = try? doc.select(".gallary_item") else {
            return []
        }

        var items: [Manga] = []
        for el in elements.array() {
            let aLink = (try? el.select(".title a").first()) ?? (try? el.select("a").first())
            let href = (try? aLink?.attr("href")) ?? ""
            guard let aid = firstAidMatch(in: href) else { continue }

            let rawTitle = (try? aLink?.text())?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : "WNACG \(aid)"

            let imgEl = try? el.select(".pic_box img").first()
            let dataOrig = (try? imgEl?.attr("data-original")) ?? ""
            let src = (try? imgEl?.attr("src")) ?? ""
            let rawCover = dataOrig.isEmpty ? src : dataOrig
            let coverURL = cleanWnacgUrl(rawCover, baseUrl: baseUrl)

            let picBoxClass = (try? el.select(".pic_box").first()?.attr("class")) ?? ""
            let category = extractCategoryTagFromClass(picBoxClass) ?? "绅士漫画"

            var infoCol = ((try? el.select(".info_col").first()?.text()) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let tailRange = infoCol.range(of: #"[,，\s]+$"#, options: .regularExpression) {
                infoCol.removeSubrange(tailRange)
            }

            let statusText = MangaSerialStatusHelper.inferStatusText(
                title: title,
                latestChapter: infoCol
            )

            items.append(
                Manga(
                    id: aid,
                    sourceID: sourceID,
                    title: title,
                    author: "绅士本",
                    coverURL: coverURL,
                    coverHeaders: ["Referer": "\(baseUrl)/"],
                    summary: infoCol,
                    tags: [category],
                    statusText: statusText.isEmpty ? infoCol : statusText
                )
            )
        }
        return items
    }

    public static func parseDetailHtml(
        aid: String,
        html: String,
        baseUrl: String,
        sourceID: String,
        fallbackManga: Manga
    ) -> (manga: Manga, chapters: [MangaChapter])? {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doc = try? SwiftSoup.parse(html) else {
            return nil
        }

        let title = ((try? doc.select("#bodywrap h2").first()?.text())
            ?? (try? doc.select(".uwuinfo h2").first()?.text())
            ?? fallbackManga.title).trimmingCharacters(in: .whitespacesAndNewlines)

        let coverEl = try? doc.select(".uwthumb img").first()
        let dataOrig = (try? coverEl?.attr("data-original")) ?? ""
        let src = (try? coverEl?.attr("src")) ?? ""
        let rawCover = dataOrig.isEmpty ? src : dataOrig
        let coverURL = rawCover.isEmpty ? fallbackManga.coverURL : cleanWnacgUrl(rawCover, baseUrl: baseUrl)

        var author = "佚名"
        if let paragraphs = try? doc.select(".uwuinfo p") {
            for p in paragraphs.array() {
                let text = ((try? p.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.contains("作者：") || text.contains("出處：") || text.contains("出处：") {
                    author = text.replacingOccurrences(
                        of: #"^(作者|出處|出处)："#,
                        with: "",
                        options: .regularExpression
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
        }

        let desc = ((try? doc.select(".uwconn p:not(#rm-state)").first()?.text())
            ?? (try? doc.select(".uwconn").first()?.text())
            ?? "暂无简介").trimmingCharacters(in: .whitespacesAndNewlines)

        var tags: [String] = []
        if let tagLinks = try? doc.select(".addtags a.tagshow") {
            for a in tagLinks.array() {
                let t = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty, !tags.contains(t) { tags.append(t) }
            }
        }

        if let labels = try? doc.select(".uwconn label") {
            for label in labels.array() {
                let text = ((try? label.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix("分類：") || text.hasPrefix("分类：") {
                    let raw = String(text.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = normalizeCategory(raw)
                    if !normalized.isEmpty, !tags.contains(normalized) {
                        tags.insert(normalized, at: 0)
                    }
                    break
                }
            }
        }

        var chapters: [MangaChapter] = []
        let selectLinks = (try? doc.select(".selectlist .sr_compact a").array()) ?? []
        if !selectLinks.isEmpty {
            for (idx, a) in selectLinks.enumerated() {
                let href = (try? a.attr("href")) ?? ""
                let chAid = firstAidMatch(in: href) ?? aid
                let chTitleRaw = ((try? a.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let chTitle = chTitleRaw.isEmpty ? "第 \(idx + 1) 话" : chTitleRaw
                chapters.append(
                    MangaChapter(
                        id: chAid,
                        mangaID: aid,
                        title: chTitle,
                        number: Double(idx + 1)
                    )
                )
            }
        } else {
            let readerBtn = (try? doc.select("#reader-btn").first()) ?? (try? doc.select(".read-btn a").first())
            var targetAid = aid
            if let readerBtn {
                let href = (try? readerBtn.attr("href")) ?? ""
                if let matched = firstAidMatch(in: href) {
                    targetAid = matched
                }
            }
            chapters.append(MangaChapter(id: targetAid, mangaID: aid, title: "全本阅览", number: 1))
        }

        let statusText = MangaSerialStatusHelper.inferStatusText(
            title: title,
            tags: tags,
            isSeries: !selectLinks.isEmpty,
            chapterCount: chapters.count
        )

        let updatedManga = Manga(
            id: aid,
            sourceID: sourceID,
            title: title.isEmpty ? "WNACG \(aid)" : title,
            author: author.isEmpty ? "佚名" : author,
            coverURL: coverURL,
            coverHeaders: ["Referer": "\(baseUrl)/"],
            summary: desc.isEmpty ? "暂无简介" : desc,
            tags: tags,
            statusText: statusText
        )
        return (updatedManga, chapters)
    }

    public static func extractPageImageUrls(html: String, baseUrl: String) -> [String] {
        var urls: [String] = []
        let fullRange = NSRange(html.startIndex..<html.endIndex, in: html)

        if let match = pageUrlArrayRegex.firstMatch(in: html, range: fullRange),
           match.numberOfRanges > 1,
           let contentRange = Range(match.range(at: 1), in: html) {
            let content = String(html[contentRange])
            let contentNSRange = NSRange(content.startIndex..<content.endIndex, in: content)
            for m in quotedUrlRegex.matches(in: content, range: contentNSRange) {
                if m.numberOfRanges > 1, let r1 = Range(m.range(at: 1), in: content) {
                    let raw = String(content[r1]).replacingOccurrences(of: "\\/", with: "/")
                    let cleaned = cleanWnacgUrl(raw, baseUrl: baseUrl)
                    if !cleaned.isEmpty, !urls.contains(cleaned) {
                        urls.append(cleaned)
                    }
                }
            }

            if urls.isEmpty {
                var inner = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if inner.hasSuffix(",") {
                    inner.removeLast()
                    inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let data = "[\(inner)]".data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                    for item in parsed {
                        let cleaned = cleanWnacgUrl(String(describing: item), baseUrl: baseUrl)
                        if !cleaned.isEmpty, !urls.contains(cleaned) {
                            urls.append(cleaned)
                        }
                    }
                }
            }
        }

        if urls.isEmpty, let doc = try? SwiftSoup.parse(html),
           let imgs = try? doc.select(".photo-pic img, #pic_box img, .pic_box img") {
            for img in imgs.array() {
                let src = ((try? img.attr("src")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let orig = ((try? img.attr("data-original")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let raw = src.isEmpty ? orig : src
                let cleaned = cleanWnacgUrl(raw, baseUrl: baseUrl)
                if !cleaned.isEmpty, !urls.contains(cleaned) {
                    urls.append(cleaned)
                }
            }
        }

        return urls
    }
}
