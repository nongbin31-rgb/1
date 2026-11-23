import Foundation

/// 在线漫画源 J 标准在线图源适配器
public struct JmMangaSource: MangaSourceProtocol {
    public let config: MangaSourceConfig

    public var exploreCategories: [MangaCategoryOption] {
        [
            MangaCategoryOption(id: "0", title: "全部"),
            MangaCategoryOption(id: "doujin", title: "同人"),
            MangaCategoryOption(id: "single", title: "单本"),
            MangaCategoryOption(id: "hanman", title: "韩漫"),
        ]
    }

    public var supportedSearchSorts: [MangaSearchSort] {
        [.latest, .popular, .favorites, .mostPages]
    }

    public init(config: MangaSourceConfig) {
        self.config = config
    }

    public func fetchPopular(page: Int) async throws -> [Manga] {
        try await JmApiClient.shared.getExplore(sourceID: config.id, category: "0", order: "mr", page: page)
    }

    public func fetchPopular(category: String, page: Int) async throws -> [Manga] {
        try await JmApiClient.shared.getExplore(sourceID: config.id, category: category, order: "mr", page: page)
    }

    public func fetchPopularPaged(page: Int) async throws -> MangaPagedResult {
        try await JmApiClient.shared.getExplorePaged(sourceID: config.id, category: "0", order: "mr", page: page)
    }

    public func fetchPopularPaged(category: String, page: Int) async throws -> MangaPagedResult {
        try await JmApiClient.shared.getExplorePaged(sourceID: config.id, category: category, order: "mr", page: page)
    }

    public func search(query: String, page: Int) async throws -> [Manga] {
        try await search(query: query, sort: .latest, page: page)
    }

    public func search(query: String, sort: MangaSearchSort, page: Int) async throws -> [Manga] {
        let order: String
        switch sort {
        case .latest:    order = "mr"
        case .popular:   order = "mv"
        case .favorites: order = "tf"
        case .mostPages: order = "mp"
        }
        return try await JmApiClient.shared.search(sourceID: config.id, query: query, order: order, page: page)
    }

    public func fetchDetail(for manga: Manga) async throws -> (manga: Manga, chapters: [MangaChapter]) {
        try await JmApiClient.shared.getDetail(sourceID: config.id, manga: manga)
    }

    public func fetchChapters(for manga: Manga) async throws -> [MangaChapter] {
        let (_, chapters) = try await fetchDetail(for: manga)
        return chapters
    }

    public func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage] {
        try await JmApiClient.shared.getChapterPages(photoId: chapter.id)
    }

    public func resetPaginationCache(scope: PaginationCacheScope) async {
        await JmApiClient.shared.resetPaginationCache(scope: scope)
    }
}
