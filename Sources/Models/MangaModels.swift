import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif

/// 在线漫画图源类型
public enum MangaSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case demo = "demo"
    case genericJSON = "generic_json"
    case jm = "jm"
    case wnacg = "wnacg"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .demo:
            return "内置在线演示源"
        case .genericJSON:
            return "自定义 JSON 接口源"
        case .jm:
            return "禁漫天堂 (JMComic)"
        case .wnacg:
            return "绅士漫画 (WNACG)"
        }
    }

    public var isBuiltin: Bool {
        self == .demo || self == .jm || self == .wnacg
    }
}

/// 在线图源分类筛选选项
public enum DiscoverPaginationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case pageByPage = "page_by_page"       // 按页翻阅（上一页/下一页/跳页，独立加载）
    case infiniteScroll = "infinite_scroll" // 瀑布流（向下滚动自动加载追加）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pageByPage:
            return "按页翻阅"
        case .infiniteScroll:
            return "瀑布流滚动"
        }
    }

    public var iconName: String {
        switch self {
        case .pageByPage:
            return "book.pages"
        case .infiniteScroll:
            return "arrow.down.circle"
        }
    }
}

/// 发现页视图排布样式（保留经典三列网格为默认，新增 5 套高阶视图）
public enum DiscoverLayoutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case classicGrid = "classic_grid"             // 经典三列网格（保留默认）
    case editorialList = "editorial_list"         // 详情信息流（Apple Books 经典列表）
    case immersiveWall = "immersive_wall"         // 沉浸海报墙（2 列全画幅）
    case editorialGallery = "editorial_gallery"   // 双列呼吸画廊（2 列大卡 + 环境光投影）
    case tactileBookshelf = "tactile_bookshelf"   // 拟物精装书架（3 列书脊 + 悬浮层板）
    case magazineToday = "magazine_today"         // 焦点杂志流（App Store Today 风格）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classicGrid:
            return "经典三列网格"
        case .editorialList:
            return "详情信息流"
        case .immersiveWall:
            return "沉浸海报墙"
        case .editorialGallery:
            return "双列呼吸画廊"
        case .tactileBookshelf:
            return "拟物精装书架"
        case .magazineToday:
            return "焦点杂志流"
        }
    }

    public var subtitle: String {
        switch self {
        case .classicGrid:
            return "默认紧凑三列"
        case .editorialList:
            return "Apple Books 经典列表"
        case .immersiveWall:
            return "视觉纯粹流 · 全画幅"
        case .editorialGallery:
            return "高级留白流 · 平衡美学"
        case .tactileBookshelf:
            return "Apple Books 实体书感"
        case .magazineToday:
            return "App Store Today 风格"
        }
    }

    public var iconName: String {
        switch self {
        case .classicGrid:
            return "square.grid.3x2"
        case .editorialList:
            return "rectangle.grid.1x2"
        case .immersiveWall:
            return "rectangle.grid.2x2"
        case .editorialGallery:
            return "square.grid.2x2"
        case .tactileBookshelf:
            return "books.vertical"
        case .magazineToday:
            return "newspaper"
        }
    }
}

/// 书架视图排布样式（4 套原生高阶书架视图）
public enum BookshelfLayoutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case focusShelf = "focus_shelf"           // 聚焦续读（默认：置顶续读焦点卡 + 筛选胶囊 + 三列精排）
    case progressList = "progress_list"       // 进度列表（立体书封 + 独立元信息胶囊 + 线性进度条 + 续读按钮）
    case geekMatrix = "geek_matrix"           // 极客矩阵（四列紧排 + 纯图/标题切换 + 微缩进度环）
    case readingTimeline = "reading_timeline" // 阅读时间轴（按真实阅读与收藏时间分组 + 吸顶头 + 竖轨卡片）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .focusShelf:
            return "聚焦续读"
        case .progressList:
            return "进度列表"
        case .geekMatrix:
            return "极客矩阵"
        case .readingTimeline:
            return "阅读时间轴"
        }
    }

    public var subtitle: String {
        switch self {
        case .focusShelf:
            return "续读焦点卡 · 三列精排"
        case .progressList:
            return "元信息拆分 · 显式进度"
        case .geekMatrix:
            return "四列高密 · 单屏速览"
        case .readingTimeline:
            return "按阅读时间 · 脉络回溯"
        }
    }

    public var iconName: String {
        switch self {
        case .focusShelf:
            return "square.grid.3x2"
        case .progressList:
            return "list.bullet.rectangle"
        case .geekMatrix:
            return "square.grid.4x3.fill"
        case .readingTimeline:
            return "clock.arrow.circlepath"
        }
    }
}

/// 书架排序方式（全部基于本地真实持久化的阅读时间、收藏时间与进度比例）
public enum BookshelfSortOrder: String, Codable, CaseIterable, Identifiable, Sendable {
    case recentRead = "recent_read"
    case recentAdded = "recent_added"
    case progress = "progress"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .recentRead:
            return "按最近阅读"
        case .recentAdded:
            return "按最近收藏"
        case .progress:
            return "按阅读进度"
        }
    }

    public var iconName: String {
        switch self {
        case .recentRead:
            return "clock"
        case .recentAdded:
            return "bookmark"
        case .progress:
            return "chart.bar"
        }
    }
}

/// 在线图源分类筛选选项
public struct MangaCategoryOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// 漫画搜索排序方式
public enum MangaSearchSort: String, Codable, CaseIterable, Identifiable, Sendable {
    case latest = "latest"
    case popular = "popular"
    case favorites = "favorites"
    case mostPages = "most_pages"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .latest:    return "最新"
        case .popular:   return "热门"
        case .favorites: return "最多收藏"
        case .mostPages: return "最多图集"
        }
    }
}

/// 搜索范围（全启用源聚合 或 指定单图源）
public enum MangaSearchScope: Hashable, Sendable {
    case allEnabled
    case source(String)
}

/// 导航栈搜索路由参数（供发现页、书架页、漫画详情页统一压栈进入搜索中心）
public struct MangaSearchRoute: Hashable, Sendable {
    public var initialQuery: String
    public var initialSourceID: String?
    public var suggestedTags: [String]
    public var autoSubmit: Bool

    public init(
        initialQuery: String = "",
        initialSourceID: String? = nil,
        suggestedTags: [String] = [],
        autoSubmit: Bool = false
    ) {
        self.initialQuery = initialQuery
        self.initialSourceID = initialSourceID
        self.suggestedTags = suggestedTags
        self.autoSubmit = autoSubmit
    }
}

/// 在线图源配置
public struct MangaSourceConfig: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var kind: MangaSourceKind
    public var baseURL: String
    public var headers: [String: String]
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        kind: MangaSourceKind,
        baseURL: String,
        headers: [String: String] = [:],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.headers = headers
        self.isEnabled = isEnabled
    }
}

/// 漫画基础信息
public struct Manga: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var sourceID: String
    public var title: String
    public var author: String
    public var coverURL: String
    public var coverHeaders: [String: String]
    public var summary: String
    public var tags: [String]
    public var statusText: String

    public init(
        id: String,
        sourceID: String,
        title: String,
        author: String = "",
        coverURL: String = "",
        coverHeaders: [String: String] = [:],
        summary: String = "",
        tags: [String] = [],
        statusText: String = "连载中"
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        let formattedAuthor = MangaAuthorFormatter.format(author)
        self.author = formattedAuthor.isEmpty ? author : formattedAuthor
        self.coverURL = coverURL
        self.coverHeaders = coverHeaders
        self.summary = summary
        self.tags = tags
        self.statusText = statusText
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceID, title, author, coverURL, coverHeaders, summary, tags, statusText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sourceID = try container.decode(String.self, forKey: .sourceID)
        self.title = try container.decode(String.self, forKey: .title)
        let rawAuthor = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        let formattedAuthor = MangaAuthorFormatter.format(rawAuthor)
        self.author = formattedAuthor.isEmpty ? rawAuthor : formattedAuthor
        self.coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL) ?? ""
        self.coverHeaders = try container.decodeIfPresent([String: String].self, forKey: .coverHeaders) ?? [:]
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? ""
    }

    public var displayAuthor: String {
        let formatted = MangaAuthorFormatter.format(author)
        return formatted.isEmpty ? (author.isEmpty ? "佚名" : author) : formatted
    }

    public var compositeKey: String {
        "\(sourceID)::\(id)"
    }
}

/// 作者字符串解码与规整格式化工具
public enum MangaAuthorFormatter {
    private static let unicodeEscapeRegex = try! NSRegularExpression(
        pattern: #"\\([uU])([0-9a-fA-F]{4,8})"#,
        options: []
    )
    private static let nsArrayItemRegex = try! NSRegularExpression(
        pattern: #""([^"]*)""#,
        options: []
    )
    private static let titleAuthorBracketRegex = try! NSRegularExpression(
        pattern: #"(?:\[|\()(.*?)(?:\]|\))"#,
        options: []
    )

    /// 解码 \Uxxxx / \uxxxx Unicode 转义字符为标准字符
    public static func decodeUnicodeEscape(_ text: String) -> String {
        guard text.contains("\\u") || text.contains("\\U") else { return text }
        let nsString = text as NSString
        let matches = unicodeEscapeRegex.matches(in: text, options: [], range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var lastLocation = 0

        for match in matches {
            let fullRange = match.range
            if fullRange.location > lastLocation {
                result += nsString.substring(with: NSRange(location: lastLocation, length: fullRange.location - lastLocation))
            }
            let hexRange = match.range(at: 2)
            let hexStr = nsString.substring(with: hexRange)
            if let code = UInt32(hexStr, radix: 16), let scalar = UnicodeScalar(code) {
                result.append(Character(scalar))
            } else {
                result += nsString.substring(with: fullRange)
            }
            lastLocation = fullRange.location + fullRange.length
        }
        if lastLocation < nsString.length {
            result += nsString.substring(with: NSRange(location: lastLocation, length: nsString.length - lastLocation))
        }
        return result
    }

    /// 将任意对象（字符串、NSArray 描述、[Any] 列表、字典）规范化为以 " / " 分隔的人类可读作者名
    public static func format(_ raw: Any?) -> String {
        guard let raw, !(raw is NSNull) else { return "" }

        if let array = raw as? [Any] {
            let parts = array.compactMap { item -> String? in
                let formatted = format(item)
                return formatted.isEmpty ? nil : formatted
            }
            return parts.joined(separator: " / ")
        }

        if let dict = raw as? [String: Any] {
            if let name = dict["name"] ?? dict["author"] ?? dict["title"] {
                return format(name)
            }
        }

        var str = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        if str.isEmpty || str == "<null>" { return "" }

        // 处理形如 (\n  "\\U65e5...",\n  "\\U5800..."\n) 的 NSArray description 字符串
        if str.hasPrefix("(") && str.hasSuffix(")") {
            let nsStr = str as NSString
            let matches = nsArrayItemRegex.matches(in: str, options: [], range: NSRange(location: 0, length: nsStr.length))
            if !matches.isEmpty {
                let items = matches.map { match -> String in
                    let itemStr = nsStr.substring(with: match.range(at: 1))
                    return decodeUnicodeEscape(itemStr).trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                if !items.isEmpty {
                    return items.joined(separator: " / ")
                }
            }
        }

        str = decodeUnicodeEscape(str)
        return str
    }

    /// 从漫画标题中提取括号中的作者名作为 fallback
    public static func extractAuthorFromTitle(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let ns = title as NSString
        let matches = titleAuthorBracketRegex.matches(in: title, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let content = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            // 过滤明显是话数、语言或版本标识的内容
            if content.contains("话") || content.contains("話") || content.contains("卷")
                || content.contains("汉化") || content.contains("漢化") || content.contains("中文")
                || content.contains("DL版") || content.contains("同人") {
                continue
            }
            return content
        }
        return nil
    }
}

/// 从原始漫画标题剥离前后括号标签后的结构化展示信息（用于高阶发现视图）
public struct MangaTitleMetadata: Sendable, Equatable {
    public let cleanTitle: String
    public let groupName: String?
    public let extractedBadges: [String]

    public init(cleanTitle: String, groupName: String?, extractedBadges: [String]) {
        self.cleanTitle = cleanTitle
        self.groupName = groupName
        self.extractedBadges = extractedBadges
    }
}

/// 标题前后缀元数据清洗器：剥离 `[汉化组]` / `【翻译】` / `(C104)` 等头尾括号标签，保留清爽书名
public enum MangaTitleMetadataParser {
    private static let leadingBracketRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:\[([^\[\]]{1,28})\]|【([^【】]{1,28})】|\(([^()]{1,24})\)|（([^（）]{1,24})）)\s*"#,
        options: []
    )
    private static let trailingBracketRegex = try! NSRegularExpression(
        pattern: #"\s*(?:\[([^\[\]]{1,28})\]|【([^【】]{1,28})】|\(([^()]{1,24})\)|（([^（）]{1,24})）)\s*$"#,
        options: []
    )

    private static let groupKeywords: [String] = [
        "汉化", "漢化", "翻译", "翻譯", "字幕", "嵌字", "修图", "修圖", "个人", "個人", "社", "组", "組", "屋"
    ]

    public static func parse(title: String, author: String = "") -> MangaTitleMetadata {
        let original = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else {
            return MangaTitleMetadata(cleanTitle: title, groupName: nil, extractedBadges: [])
        }

        var working = original
        var badges: [String] = []
        var seenLower: Set<String> = []

        func appendBadge(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 20 else { return }
            let lower = trimmed.lowercased()
            guard !seenLower.contains(lower) else { return }
            seenLower.insert(lower)
            badges.append(trimmed)
        }

        // 最多剥离 4 个头部括号块
        for _ in 0..<4 {
            let ns = working as NSString
            guard let match = leadingBracketRegex.firstMatch(in: working, range: NSRange(location: 0, length: ns.length)) else {
                break
            }
            if let captured = firstNonEmptyCapture(in: ns, match: match) {
                appendBadge(captured)
            }
            let remainder = ns.substring(from: match.range.location + match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty { break }
            working = remainder
        }

        // 最多剥离 3 个尾部括号块
        for _ in 0..<3 {
            let ns = working as NSString
            guard let match = trailingBracketRegex.firstMatch(in: working, range: NSRange(location: 0, length: ns.length)) else {
                break
            }
            if let captured = firstNonEmptyCapture(in: ns, match: match) {
                appendBadge(captured)
            }
            let remainder = ns.substring(to: match.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if remainder.isEmpty { break }
            working = remainder
        }

        let cleanTitle = working.isEmpty ? original : working
        let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 优先匹配汉化组/社团关键词
        let groupName = badges.first(where: { badge in
            groupKeywords.contains(where: { badge.contains($0) })
        }) ?? badges.first(where: { badge in
            let lower = badge.lowercased()
            return lower != normalizedAuthor
                && !badge.contains("中国")
                && !badge.contains("中文")
                && !badge.contains("無修正")
                && !badge.contains("无修正")
                && !badge.contains("DL版")
        })

        return MangaTitleMetadata(
            cleanTitle: cleanTitle,
            groupName: groupName,
            extractedBadges: badges
        )
    }

    public static func displayTags(for manga: Manga, metadata: MangaTitleMetadata? = nil, limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var result: [String] = []
        var seen: Set<String> = []

        func appendIfValid(_ raw: String) {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty,
                  tag.count <= 14,
                  !MangaSerialStatusHelper.isStatusTag(tag),
                  tag != "绅士漫画",
                  tag != "禁漫单行本" else {
                return
            }
            let key = tag.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(tag)
        }

        for tag in manga.tags {
            appendIfValid(tag)
            if result.count >= limit { return result }
        }

        let meta = metadata ?? parse(title: manga.title, author: manga.displayAuthor)
        for badge in meta.extractedBadges where badge != meta.groupName {
            appendIfValid(badge)
            if result.count >= limit { return result }
        }
        return result
    }

    private static func firstNonEmptyCapture(in ns: NSString, match: NSTextCheckingResult) -> String? {
        for idx in 1..<match.numberOfRanges {
            let range = match.range(at: idx)
            if range.location != NSNotFound, range.length > 0 {
                let text = ns.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
}

/// 结合标题、标签与接口字段推导漫画连载状态
public enum MangaSerialStatusHelper {
    private static let incompleteRegex = try! NSRegularExpression(
        pattern: "未完结|未完結|未完|连载中|連載中|连载|連載|更新中|持续更新|持續更新|更新至|ongoing|serializ",
        options: [.caseInsensitive]
    )
    private static let completedRegex = try! NSRegularExpression(
        pattern: "已完结|已完結|完结|完結|全一话|全一話|全一卷|全本|终章|終章|最终话|最終話|\\bcomplete(d)?\\b|\\bfinished\\b",
        options: [.caseInsensitive]
    )
    private static let stripIncompleteRegex = try! NSRegularExpression(
        pattern: "未完结|未完結|未完",
        options: []
    )
    private static let chapterNumberIndicatorRegex = try! NSRegularExpression(
        pattern: "(?:第\\s*\\d+\\s*[话話卷]|\\b(?:ch|ep|vol)[\\.\\s]*\\d+|\\[\\d+[\\]话話]|\\b\\d+\\s*話|\\b\\d+\\s*话)",
        options: [.caseInsensitive]
    )
    private static let singleVolumeCategoryKeywords: [String] = [
        "单本", "單本", "单行本", "單行本", "同人", "短篇", "杂志", "雜誌",
        "画集", "畫集", "cg", "cosplay", "写真", "寫真", "禁漫单行本", "绅士漫画", "紳士漫畫"
    ]
    private static let ongoingCategoryKeywords: [String] = [
        "韩漫", "韓漫", "连载", "連載"
    ]

    public static func isOngoingStatus(_ status: String) -> Bool {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return s == "连载中" || s == "連載中" || s == "连载" || s == "連載" || s == "更新中"
    }

    public static func isCompletedStatus(_ status: String) -> Bool {
        let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
        return s == "已完结" || s == "已完結" || s == "完结" || s == "完結" || s == "全一话" || s == "全一話"
    }

    /// 判断标签文本是否为连载状态相关的词汇
    public static func isStatusTag(_ tag: String) -> Bool {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isOngoingStatus(trimmed) || isCompletedStatus(trimmed) { return true }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if incompleteRegex.firstMatch(in: trimmed, range: range) != nil {
            return true
        }
        if completedRegex.firstMatch(in: trimmed, range: range) != nil {
            return true
        }
        return false
    }

    /// 从标签列表中移除所有连载状态相关的标签，确保标签与连载状态独立
    public static func sanitizeTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isStatusTag(trimmed) else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    /// 连载状态与标签已独立，标签列表不再混入连载状态（兼容旧调用，直接返回清洗后的纯标签）
    public static func ensureStatusTagInTags(tags: [String], statusText: String) -> [String] {
        sanitizeTags(tags)
    }

    public static func inferStatusText(
        title: String? = nil,
        latestChapter: String? = nil,
        tags: [String] = [],
        rawStatus: Any? = nil,
        rawIsEnd: Any? = nil,
        isSeries: Bool = false,
        chapterCount: Int = 0
    ) -> String {
        if let rawIsEnd {
            let v = String(describing: rawIsEnd).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if v == "1" || v == "true" || v == "yes" {
                return "已完结"
            }
            if v == "0" || v == "false" || v == "no" {
                return "连载中"
            }
        }

        var samples: [String] = []
        if let rawStatus {
            let s = String(describing: rawStatus).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, s != "<null>" { samples.append(s) }
        }
        for tag in tags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { samples.append(trimmed) }
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            samples.append(title)
        }
        if let latest = latestChapter?.trimmingCharacters(in: .whitespacesAndNewlines), !latest.isEmpty {
            samples.append(latest)
        }

        var hasCompleted = false
        var hasOngoing = false
        for sample in samples {
            let fullRange = NSRange(sample.startIndex..<sample.endIndex, in: sample)
            if incompleteRegex.firstMatch(in: sample, range: fullRange) != nil {
                hasOngoing = true
            }
            let stripped = stripIncompleteRegex.stringByReplacingMatches(in: sample, range: fullRange, withTemplate: "")
            let strippedRange = NSRange(stripped.startIndex..<stripped.endIndex, in: stripped)
            if completedRegex.firstMatch(in: stripped, range: strippedRange) != nil {
                hasCompleted = true
            }
        }

        if hasCompleted { return "已完结" }
        if hasOngoing { return "连载中" }
        if isSeries || chapterCount > 1 { return "连载中" }

        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            if chapterNumberIndicatorRegex.firstMatch(in: title, range: range) != nil {
                return "连载中"
            }
        }

        if chapterCount == 1 {
            return "已完结"
        }

        // 列表页无 chapterCount 时，对典型单本/同人/短篇品类（且无连载章节标识、非韩漫连载）推导为「已完结」
        let cleanedLatest = latestChapter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let latestLooksLikePageMeta = cleanedLatest.isEmpty
            || cleanedLatest.contains("張圖片")
            || cleanedLatest.contains("张图片")
            || cleanedLatest.contains(" P")
        if latestLooksLikePageMeta, !tags.isEmpty {
            let loweredTags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            let isOngoingCategory = loweredTags.contains { tag in
                ongoingCategoryKeywords.contains(where: { tag.contains($0) })
            }
            if !isOngoingCategory {
                let isSingleVolumeCategory = loweredTags.contains { tag in
                    singleVolumeCategoryKeywords.contains(where: { tag.contains($0) })
                }
                if isSingleVolumeCategory {
                    return "已完结"
                }
            }
        }

        return ""
    }
}

/// 漫画章节
public struct MangaChapter: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var mangaID: String
    public var title: String
    public var number: Double
    public var updatedAt: String

    public init(
        id: String,
        mangaID: String,
        title: String,
        number: Double,
        updatedAt: String = ""
    ) {
        self.id = id
        self.mangaID = mangaID
        self.title = title
        self.number = number
        self.updatedAt = updatedAt
    }
}

/// 漫画单页信息
public struct MangaPage: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(index)_\(imageURL)" }
    public var index: Int
    public var imageURL: String
    public var headers: [String: String]

    public init(index: Int, imageURL: String, headers: [String: String] = [:]) {
        self.index = index
        self.imageURL = imageURL
        self.headers = headers
    }
}

/// 阅读进度记录
public struct ReadingProgress: Codable, Equatable, Sendable {
    public var mangaKey: String
    public var chapterID: String
    public var chapterTitle: String
    public var pageIndex: Int
    public var totalPages: Int?
    public var chapterIndex: Int?
    public var totalChapters: Int?
    public var updatedAt: Date

    public init(
        mangaKey: String,
        chapterID: String,
        chapterTitle: String,
        pageIndex: Int,
        totalPages: Int? = nil,
        chapterIndex: Int? = nil,
        totalChapters: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.mangaKey = mangaKey
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.chapterIndex = chapterIndex
        self.totalChapters = totalChapters
        self.updatedAt = updatedAt
    }

    /// 综合阅读进度比例（0.0 ~ 1.0）：单话按页码占比计算，多话结合当前话序数与页码综合计算
    public var progressRatio: Double? {
        guard let totalPages, totalPages > 0 else { return nil }
        let pageFraction = min(1.0, max(0.0, Double(pageIndex + 1) / Double(totalPages)))
        if let totalChapters, totalChapters > 1, let chapterIndex, chapterIndex >= 0 {
            let clampedChapter = min(chapterIndex, totalChapters - 1)
            return min(1.0, max(0.0, (Double(clampedChapter) + pageFraction) / Double(totalChapters)))
        }
        return pageFraction
    }

    /// 是否已读完（综合比例达到 100%）
    public var isCompleted: Bool {
        guard let ratio = progressRatio else { return false }
        return ratio >= 0.999
    }

    /// 是否通过书架快捷操作手动标记为已读（无具体章节记录时避免界面展示 P1 / 1 假页码）
    public var isManuallyMarkedCompleted: Bool {
        chapterID.isEmpty && totalPages == 1 && pageIndex == 0
    }

    /// 整数百分比（0 ~ 100）
    public var percentageInt: Int? {
        guard let ratio = progressRatio else { return nil }
        return Int((ratio * 100).rounded())
    }
}

/// 单日阅读统计（按本地日历日聚合：有效阅读秒数 + 翻阅页数）
public struct DailyReadingStat: Codable, Equatable, Sendable {
    public var seconds: Double
    public var pages: Int

    public init(seconds: Double = 0, pages: Int = 0) {
        self.seconds = seconds
        self.pages = pages
    }

    /// 是否计入连续阅读打卡（≥ 1 分钟或翻阅 ≥ 3 页）
    public var isActiveDay: Bool {
        seconds >= 60 || pages >= 3
    }
}

/// 阅读统计图表单日数据点
public struct ReadingStatsDayPoint: Identifiable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var seconds: Double
    public var pages: Int
    public var isToday: Bool
}

/// 阅读统计汇总（本周 / 连续打卡 / 累计 / 近 7 日）
public struct ReadingStatsSummary: Equatable, Sendable {
    public var weekSeconds: Double
    public var weekPages: Int
    public var streakDays: Int
    public var totalSeconds: Double
    public var totalPages: Int
    public var recentDays: [ReadingStatsDayPoint]
}

/// 阅读方向与排版模式
public enum ReaderLayoutMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case verticalWebtoon = "vertical"
    case pagedRTL = "paged_rtl"
    case pagedLTR = "paged_ltr"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .verticalWebtoon: return "条漫滚动"
        case .pagedRTL: return "日漫翻页 (右→左)"
        case .pagedLTR: return "普通翻页 (左→右)"
        }
    }
}

/// 阅读器进度条交互与视觉风格（5 套双模态设计）
public enum ReaderProgressStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case edgeDock    = "edge_dock"     // 灵动纸缘微轨（默认：沉浸发丝轨 + 纵向拉离精调）
    case foreEdge    = "fore_edge"     // 纸书切口厚度（书底纸页切口 + 红丝带 + 拇指拨页叶阵）
    case vernierDial = "vernier_dial"  // 精密游标卡尺（沉浸微胶囊 + 游标刻度尺 + 缓存超分微点）
    case sideRail    = "side_rail"     // 侧边隐形纵轨（右缘呼吸竖轨 + 拖动页码气泡，零占底部画幅）
    case heatmapSeg  = "heatmap_seg"   // 缓冲与超分热力轨（多段微轨 + 缓存/2x超分可视化热力段）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .edgeDock:    return "灵动纸缘微轨"
        case .foreEdge:    return "纸书切口厚度"
        case .vernierDial: return "精密游标卡尺"
        case .sideRail:    return "侧边隐形纵轨"
        case .heatmapSeg:  return "缓冲与超分热力轨"
        }
    }

    public var shortName: String {
        switch self {
        case .edgeDock:    return "灵动微轨"
        case .foreEdge:    return "纸书切口"
        case .vernierDial: return "精密游标"
        case .sideRail:    return "侧边纵轨"
        case .heatmapSeg:  return "热力分段"
        }
    }

    public var subtitle: String {
        switch self {
        case .edgeDock:    return "底缘发丝轨 + 上拉精细逐页调速"
        case .foreEdge:    return "纸页厚度切口 + 拇指拨页叶阵"
        case .vernierDial: return "居中游标刻度尺，单手零死角拨动"
        case .sideRail:    return "右侧隐形竖轨，条漫零占上下画幅"
        case .heatmapSeg:  return "实时展示已缓存与 2x 超分页段"
        }
    }

    public var iconName: String {
        switch self {
        case .edgeDock:    return "slider.horizontal.below.rectangle"
        case .foreEdge:    return "book.pages"
        case .vernierDial: return "ruler"
        case .sideRail:    return "rectangle.righthalf.inset.filled"
        case .heatmapSeg:  return "chart.bar.xaxis"
        }
    }
}

/// 左右翻页过渡与动画特效
public enum PageTurningEffect: String, Codable, CaseIterable, Identifiable, Sendable {
    case curling  = "curling"    // 仿真书本卷页 (PageCurl 3D立体网格折叠与中缝阴影)
    case cover    = "cover"      // 层叠覆盖 (纸页平移抽离与边缘落影)
    case snapPage = "snap_page"  // 吸附滑动 (阻尼弹簧磁吸整页对齐)
    case instant  = "instant"    // 零延迟模式 (无动画即时刷新)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .curling:  return "仿真卷页 (PageCurl)"
        case .cover:    return "层叠覆盖 (Cover)"
        case .snapPage: return "吸附滑动 (SnapPage)"
        case .instant:  return "零延迟模式 (无动画)"
        }
    }

    public var shortName: String {
        switch self {
        case .curling:  return "仿真卷页"
        case .cover:    return "层叠覆盖"
        case .snapPage: return "吸附滑动"
        case .instant:  return "零延迟"
        }
    }
}

/// 阅读器页面预载入策略
public enum ReaderPreloadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off      = "off"       // 关闭预载入（省流模式）
    case light    = "light"     // 轻量（后 2 页，前 1 页）
    case standard = "standard"  // 标准（推荐：后 4 页，前 1 页）
    case fast     = "fast"      // 极速（后 6 页，前 2 页）

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off:      return "关闭"
        case .light:    return "轻量 (后2前1)"
        case .standard: return "标准 (后4前1)"
        case .fast:     return "极速 (后6前2)"
        }
    }

    public var shortName: String {
        switch self {
        case .off:      return "关闭"
        case .light:    return "轻量"
        case .standard: return "标准"
        case .fast:     return "极速"
        }
    }

    /// 向后预载页数
    public var aheadCount: Int {
        switch self {
        case .off:      return 0
        case .light:    return 2
        case .standard: return 4
        case .fast:     return 6
        }
    }

    /// 向前预载页数
    public var behindCount: Int {
        switch self {
        case .off:      return 0
        case .light:    return 1
        case .standard: return 1
        case .fast:     return 2
        }
    }

    public var isEnabled: Bool {
        self != .off
    }
}

/// 软件全局外观主题偏好（跟随系统 / 浅色 / 深色）
public enum AppColorSchemePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case followSystem = "follow_system"
    case light        = "light"
    case dark         = "dark"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .followSystem: return "跟随系统"
        case .light:        return "浅色模式"
        case .dark:         return "深色模式"
        }
    }

    public var shortName: String {
        switch self {
        case .followSystem: return "跟随系统"
        case .light:        return "浅色"
        case .dark:         return "深色"
        }
    }

    public var iconName: String {
        switch self {
        case .followSystem: return "circle.lefthalf.filled"
        case .light:        return "sun.max.fill"
        case .dark:         return "moon.stars.fill"
        }
    }

    #if canImport(UIKit)
    public var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .followSystem: return .unspecified
        case .light:        return .light
        case .dark:         return .dark
        }
    }
    #endif
}

/// 阅读背景模式（100% 对齐原版可达阅读器 ReaderBackground）
public enum ReaderBackground: Int, Codable, CaseIterable, Identifiable, Sendable {
    case followSystem = 0   // 跟随系统主题
    case light = 1          // 白色模式
    case dark = 2           // 黑色模式
    case immersive = 3      // 沉浸式 (动态高斯模糊/弥散光晕)
    case texture = 4        // 纸张纹理 (正片叠底)

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .followSystem: return "跟随系统"
        case .light:        return "白色"
        case .dark:         return "黑色"
        case .immersive:    return "沉浸式"
        case .texture:      return "纹理"
        }
    }

    public var systemIcon: String {
        switch self {
        case .followSystem: return "circle.lefthalf.filled"
        case .light:        return "sun.max.fill"
        case .dark:         return "moon.stars.fill"
        case .immersive:    return "sparkles"
        case .texture:      return "newspaper.fill"
        }
    }
}

/// 真实纸张与材质纹理类型（严格对齐原版可达阅读器 Kedamanga 规范）
public enum ReaderTextureType: String, Codable, CaseIterable, Identifiable, Sendable {
    case classic        = "Texture_0_classic_paper"       // 经典纸张
    case brownPaper     = "Texture_1_brown_paper"         // 包装纸/牛皮纸
    case whiteWall      = "Texture_2_white_wall"          // 白墙灰泥
    case grungePaper    = "Texture_3_grunge_paper"        // 草稿纸
    case tissueMarble   = "Texture_4_tissue_marble"       // 厕纸/大理石纹
    case wood           = "Texture_5_wood"                // 木板

    public var id: String { rawValue }

    /// 是否采用程序化高密 256pt 无缝浮雕微粒平铺（经典纸张：复刻 MangaPrism 立体微粒纸感引擎）
    public var usesFineTilePattern: Bool {
        self == .classic
    }

    public var displayName: String {
        switch self {
        case .classic:      return "经典"
        case .brownPaper:   return "包装纸"
        case .whiteWall:    return "白墙"
        case .grungePaper:  return "草稿纸"
        case .tissueMarble: return "厕纸"
        case .wood:         return "木板"
        }
    }

    public var shortName: String {
        switch self {
        case .classic:      return "经典"
        case .brownPaper:   return "包装纸"
        case .whiteWall:    return "白墙"
        case .grungePaper:  return "草稿"
        case .tissueMarble: return "厕纸"
        case .wood:         return "木板"
        }
    }

    #if canImport(UIKit)
    /// 真实材质对应的物理原生纸浆基准底色 (UIKit)
    public var basePaperColor: UIColor {
        switch self {
        case .classic:
            // 经典粉刷纯白纸基：1:1 对齐 MangaPrism 纯白底布 (#FFFFFF)，确保漫画留白与彩漫零色差
            return UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        case .brownPaper:
            // 进口包装牛皮纸：经典温厚牛皮棕 (RGB: 230, 215, 189)
            return UIColor(red: 0.902, green: 0.843, blue: 0.741, alpha: 1.0)
        case .whiteWall:
            // 浮雕白墙灰泥：纯净微灰冷白 (RGB: 245, 245, 243)
            return UIColor(red: 0.960, green: 0.960, blue: 0.953, alpha: 1.0)
        case .grungePaper:
            // 复古做旧草稿：岁月沉淀羊皮纸色 (RGB: 236, 228, 210)
            return UIColor(red: 0.925, green: 0.894, blue: 0.824, alpha: 1.0)
        case .tissueMarble:
            // 大理石云纹：柔润素净云白 (RGB: 242, 241, 237)
            return UIColor(red: 0.949, green: 0.945, blue: 0.929, alpha: 1.0)
        case .wood:
            // 浅色实木肌理：温润轻木原色 (RGB: 237, 228, 211)
            return UIColor(red: 0.929, green: 0.894, blue: 0.827, alpha: 1.0)
        }
    }
    #endif

    #if canImport(SwiftUI)
    /// 真实材质对应的物理原生纸浆基准底色 (SwiftUI)
    public var basePaperSwiftUIColor: Color {
        #if canImport(UIKit)
        return Color(uiColor: basePaperColor)
        #else
        return Color.white
        #endif
    }
    #endif
}

/// 真实物理纸张材质纹理的作用范围与目标
public enum ReaderTextureTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case both           = "both"           // 全屏覆盖 (图片与背景同时生效)
    case imageOnly      = "image_only"     // 仅漫画画面 (图片本身)
    case backgroundOnly = "background_only" // 仅阅读器背景 (四周留白底色)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .both:           return "全屏覆盖"
        case .imageOnly:      return "仅图片本身"
        case .backgroundOnly: return "仅阅读器背景"
        }
    }

    public var subtitle: String {
        switch self {
        case .both:           return "漫画画面与周围背景同时融合材质，营造整本实体纸书沉浸感"
        case .imageOnly:      return "纹理仅渗透漫画线稿墨水与画面，四周留白保持清爽纸色"
        case .backgroundOnly: return "纹理仅铺设于四周阅读底色，漫画原图保持数字无损原貌"
        }
    }

    public var systemIcon: String {
        switch self {
        case .both:           return "rectangle.fill.on.rectangle.fill"
        case .imageOnly:      return "photo"
        case .backgroundOnly: return "square.dashed"
        }
    }
}

/// 当纹理作用目标设为「仅图片本身」时，四周留白区域的拼接背景模式
public enum ReaderImageOnlyBackdrop: String, Codable, CaseIterable, Identifiable, Sendable {
    case paperTint    = "paper_tint"
    case followSystem = "follow_system"
    case light        = "light"
    case dark         = "dark"
    case immersive    = "immersive"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paperTint:    return "纸浆底色"
        case .followSystem: return "跟随系统"
        case .light:        return "白色"
        case .dark:         return "黑色"
        case .immersive:    return "沉浸式"
        }
    }

    public var systemIcon: String {
        switch self {
        case .paperTint:    return "doc.plaintext"
        case .followSystem: return "circle.lefthalf.filled"
        case .light:        return "sun.max.fill"
        case .dark:         return "moon.stars.fill"
        case .immersive:    return "sparkles"
        }
    }

    #if canImport(SwiftUI)
    public var placeholderTextColor: Color {
        switch self {
        case .paperTint:        return Color(red: 0.2, green: 0.18, blue: 0.15)
        case .followSystem:     return .primary
        case .light:            return .black
        case .dark, .immersive: return .white
        }
    }
    #endif
}
