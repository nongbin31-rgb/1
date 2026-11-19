import Foundation

/// 绅士漫画 (WNACG) 标准在线图源适配器
public struct WnacgMangaSource: MangaSourceProtocol {
    public let config: MangaSourceConfig

    public var exploreCategories: [MangaCategoryOption] {
        [
            MangaCategoryOption(id: "all", title: "全部"),
            MangaCategoryOption(id: "9", title: "单行本·汉化"),
            MangaCategoryOption(id: "1", title: "同人·汉化"),
            MangaCategoryOption(id: "10", title: "短篇·汉化"),
            MangaCategoryOption(id: "2", title: "CG画集"),
            MangaCategoryOption(id: "20", title: "韩漫·汉化"),
        ]
    }

    public init(config: MangaSourceConfig) {
        self.config = config
    }

    public func fetchPopular(page: Int) async throws -> [Manga] {
        try await WnacgClient.shared.getExplore(sourceID: config.id, cateId: "all", page: page)
    }

    public func fetchPopular(category: String, page: Int) async throws -> [Manga] {
        try await WnacgClient.shared.getExplore(sourceID: config.id, cateId: category, page: page)
    }

    public func search(query: String, page: Int) async throws -> [Manga] {
        try await WnacgClient.shared.search(sourceID: config.id, query: query, page: page)
    }

    public func fetchDetail(for manga: Manga) async throws -> (manga: Manga, chapters: [MangaChapter]) {
        try await WnacgClient.shared.getDetail(sourceID: config.id, manga: manga)
    }

    public func fetchChapters(for manga: Manga) async throws -> [MangaChapter] {
        let (_, chapters) = try await fetchDetail(for: manga)
        return chapters
    }

    public func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage] {
        try await WnacgClient.shared.getChapterPages(chapterId: chapter.id)
    }

    public func resetPaginationCache(scope: PaginationCacheScope) async {
        await WnacgClient.shared.resetPaginationCache(scope: scope)
    }
}
