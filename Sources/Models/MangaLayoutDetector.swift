import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// 漫画阅读排版类型分类（用于智能匹配最适阅读模式）
public enum MangaLayoutCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case koreanWebtoon = "korean_webtoon" // 韩漫 / 条漫 (推荐：垂直长图滚动)
    case japaneseManga = "japanese_manga" // 日漫 (单行本/同人志，推荐：右→左日漫翻页)
    case normal        = "normal"         // 常规漫画 (未命中特殊模式，遵循全局默认)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .koreanWebtoon: return "韩漫 (条漫)"
        case .japaneseManga: return "日漫 (右→左)"
        case .normal:        return "常规漫画"
        }
    }

    public var systemIcon: String {
        switch self {
        case .koreanWebtoon: return "rectangle.portrait.and.arrow.forward"
        case .japaneseManga: return "book.closed"
        case .normal:        return "doc.text"
        }
    }

    /// 对应推荐的阅读排版模式
    public var recommendedLayoutMode: ReaderLayoutMode {
        switch self {
        case .koreanWebtoon: return .verticalWebtoon
        case .japaneseManga: return .pagedRTL
        case .normal:        return .verticalWebtoon
        }
    }
}

/// 智能漫画排版检测器：结合标签、标题、作者、简介与图片宽高比，精准识别韩漫与日漫
public enum MangaLayoutDetector {
    // MARK: - 正则规则库

    /// 标题韩漫标记正则
    private static let koreanTitlePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\[|【|\(|（)?\s*(?:韩漫|webtoon|条漫|條漫|韩国漫画|韓國漫畫)\s*(?:\]|】|\)|）)?"#,
        options: []
    )

    /// 标题日漫常见开本与类型标记正则
    private static let japaneseTitlePattern = try! NSRegularExpression(
        pattern: #"(?i)(?:\[|【|\(|（)\s*(?:单行本|單行本|同人志|同人誌|日漫|c\d{2,3}|comic1|例大祭|成年コミック|dl版|無修正|中国翻訳|漢化|汉化)\s*(?:\]|】|\)|）)"#,
        options: []
    )

    // MARK: - 关键词集合

    /// 韩漫强特征标签（全部小写）
    private static let koreanTagKeywords: Set<String> = [
        "韩漫", "韩国", "韩国漫画", "韓國漫畫", "韩漫汉化", "韩漫生肉",
        "webtoon", "webtoons", "条漫", "條漫", "长条漫", "长条", "长图",
        "korean", "korea", "만화", "웹툰",
        "toptoon", "lezhin", "bomtoon", "kakaopage", "naver webtoon", "漫蛙"
    ]

    /// 日漫强特征标签（全部小写）
    private static let japaneseTagKeywords: Set<String> = [
        "日漫", "日本", "单行本", "單行本", "同人志", "同人誌",
        "manga", "japanese", "tankoubon", "doujinshi",
        "成年コミック", "コミック", "同人", "短篇", "全彩本子"
    ]

    // MARK: - 核心检测方法

    /// 静态元数据检测（通过漫画标题、标签、作者、简介以及图源信息推断分类）
    public static func detectCategory(for manga: Manga) -> MangaLayoutCategory {
        // 1. 优先检测韩漫（韩漫排版特征鲜明且阅读方式特殊，必须使用条漫模式）
        if isKoreanWebtoon(manga: manga) {
            return .koreanWebtoon
        }

        // 2. 检测日漫
        if isJapaneseManga(manga: manga) {
            return .japaneseManga
        }

        // 3. 业务图源默认启发式规则：
        // 在在线漫画源中，除了韩漫分类，多数为日漫同人志或单行本
        if manga.sourceID.contains("jm") || manga.sourceID.contains("wnacg") {
            return .japaneseManga
        }

        return .normal
    }

    /// 结合页面首批图片的物理尺寸长宽比进行二次校验与兜底推断
    public static func detectCategory(
        for manga: Manga,
        sampleImageSizes: [CGSize]
    ) -> MangaLayoutCategory {
        let initial = detectCategory(for: manga)

        // 如果已经通过元数据明确判定为韩漫，维持判定
        if initial == .koreanWebtoon {
            return .koreanWebtoon
        }

        // 如果有已下载的原图尺寸，分析高宽比 (Height / Width)
        let validSizes = sampleImageSizes.filter { $0.width > 0 && $0.height > 0 }
        if !validSizes.isEmpty {
            let aspectRatios = validSizes.map { $0.height / $0.width }
            let averageRatio = aspectRatios.reduce(0, +) / Double(aspectRatios.count)

            // 条漫/韩漫长图特征：高宽比通常 >= 1.85 (常见为 2.5 ~ 8.0)
            if averageRatio >= 1.85 {
                return .koreanWebtoon
            }

            // 日漫/实体书刊特征：高宽比在 1.25 ~ 1.6 之间 (单页比例 ~1.41) 或 < 0.8 (跨页双页)
            if averageRatio <= 1.6 && initial == .normal {
                return .japaneseManga
            }
        }

        return initial
    }

    // MARK: - 私有辅助检测

    /// 判断是否为韩漫
    private static func isKoreanWebtoon(manga: Manga) -> Bool {
        // 1. 检查标签 Tags
        for rawTag in manga.tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if koreanTagKeywords.contains(tag) {
                return true
            }
            for keyword in koreanTagKeywords where tag.contains(keyword) {
                return true
            }
        }

        // 2. 检查标题 Title 中的明确标记
        let title = manga.title
        let titleRange = NSRange(title.startIndex..<title.endIndex, in: title)
        if koreanTitlePattern.firstMatch(in: title, range: titleRange) != nil {
            return true
        }

        // 3. 检查标题或作者中是否包含韩文字符 (Hangul Syllables: AC00-D7AF, Hangul Jamo: 1100-11FF)
        if containsHangul(title) || containsHangul(manga.author) {
            return true
        }

        // 4. 检查简介 Summary
        let summary = manga.summary.lowercased()
        if summary.contains("韩漫") || summary.contains("韩国漫画") || summary.contains("webtoon") || summary.contains("条漫") {
            return true
        }

        return false
    }

    /// 判断是否为日漫
    private static func isJapaneseManga(manga: Manga) -> Bool {
        // 1. 检查标签 Tags
        for rawTag in manga.tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if japaneseTagKeywords.contains(tag) {
                return true
            }
            for keyword in japaneseTagKeywords where tag.contains(keyword) {
                return true
            }
            // 包含 C99, C100, C101, C102 等 Comiket 标签
            if tag.hasPrefix("c") && tag.count >= 3, Int(tag.dropFirst()) != nil {
                return true
            }
        }

        // 2. 检查标题 Title 中的典型日漫标识
        let title = manga.title
        let titleRange = NSRange(title.startIndex..<title.endIndex, in: title)
        if japaneseTitlePattern.firstMatch(in: title, range: titleRange) != nil {
            return true
        }

        // 3. 检查标题或作者是否包含日文假名 (平假名 3040-309F, 片假名 30A0-30FF)
        if containsKana(title) || containsKana(manga.author) {
            return true
        }

        return false
    }

    /// 判断字符串是否包含韩文字符（至少 2 个韩文音节或字母）
    public static func containsHangul(_ text: String) -> Bool {
        var count = 0
        for scalar in text.unicodeScalars {
            // Hangul Syllables (AC00-D7AF), Hangul Jamo (1100-11FF), Hangul Compatibility Jamo (3130-318F)
            if (scalar.value >= 0xAC00 && scalar.value <= 0xD7AF) ||
               (scalar.value >= 0x1100 && scalar.value <= 0x11FF) ||
               (scalar.value >= 0x3130 && scalar.value <= 0x318F) {
                count += 1
                if count >= 2 { return true }
            }
        }
        return false
    }

    /// 判断字符串是否包含日文假名（平假名或片假名）
    public static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            // Hiragana (3040-309F) or Katakana (30A0-30FF)
            if (scalar.value >= 0x3040 && scalar.value <= 0x309F) ||
               (scalar.value >= 0x30A0 && scalar.value <= 0x30FF) {
                return true
            }
        }
        return false
    }
}
