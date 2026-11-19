import Foundation

/// 在线漫画图源统一协议
/// 后续接入 Komga、OPDS、WebDAV 或任意自定义在线图源，只需实现此协议并在 SourceManager 注册
public protocol MangaSourceProtocol: Sendable {
    var config: MangaSourceConfig { get }

    /// 获取热门 / 推荐列表
    func fetchPopular(page: Int) async throws -> [Manga]

    /// 关键词搜索
    func search(query: String, page: Int) async throws -> [Manga]

    /// 获取漫画章节列表
    func fetchChapters(for manga: Manga) async throws -> [MangaChapter]

    /// 获取章节的所有页面图片 URL
    func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage]
}

public enum MangaSourceError: LocalizedError {
    case invalidURL(String)
    case httpError(Int)
    case decodingFailed(String)
    case sourceNotFound

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "无效的接口地址：\(url)"
        case let .httpError(code):
            return "在线源返回错误状态码：HTTP \(code)"
        case let .decodingFailed(detail):
            return "在线源数据解析失败：\(detail)"
        case .sourceNotFound:
            return "未找到对应的在线图源配置"
        }
    }
}
