import Foundation

/// 在线漫画图源类型
public enum MangaSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case demo = "demo"
    case genericJSON = "generic_json"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .demo:
            return "内置在线演示源"
        case .genericJSON:
            return "自定义 JSON 接口源"
        }
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
    public var summary: String
    public var tags: [String]
    public var statusText: String

    public init(
        id: String,
        sourceID: String,
        title: String,
        author: String = "",
        coverURL: String = "",
        summary: String = "",
        tags: [String] = [],
        statusText: String = "连载中"
    ) {
        self.id = id
        self.sourceID = sourceID
        self.title = title
        self.author = author
        self.coverURL = coverURL
        self.summary = summary
        self.tags = tags
        self.statusText = statusText
    }

    public var compositeKey: String {
        "\(sourceID)::\(id)"
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
    public var updatedAt: Date

    public init(
        mangaKey: String,
        chapterID: String,
        chapterTitle: String,
        pageIndex: Int,
        updatedAt: Date = Date()
    ) {
        self.mangaKey = mangaKey
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.updatedAt = updatedAt
    }
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
