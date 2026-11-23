import Foundation

/// 在线漫画源 J 标准在线图源适配器
public struct JmMangaSource: MangaSourceProtocol {
    public let config: MangaSourceConfig

    public var exploreCategories: [MangaCategoryOption] {
        [
            MangaCategoryOption(id: "0:mr", title: "最新"),
            MangaCategoryOption(id: "0:mv_w", title: "周排行"),
            MangaCategoryOption(id: "0:mv_m", title: "月排行"),
            MangaCategoryOption(id: "0:mv", title: "总排行"),
            MangaCategoryOption(id: "doujin:mr", title: "同人"),
            MangaCategoryOption(id: "single:mr", title: "单本"),
            MangaCategoryOption(id: "hanman:mr", title: "韩漫"),
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
        let filter = parseExploreFilter(category)
        return try await JmApiClient.shared.getExplore(
            sourceID: config.id,
            category: filter.category,
            order: filter.order,
            page: page
        )
    }

    public func fetchPopularPaged(page: Int) async throws -> MangaPagedResult {
        try await JmApiClient.shared.getExplorePaged(sourceID: config.id, category: "0", order: "mr", page: page)
    }

    public func fetchPopularPaged(category: String, page: Int) async throws -> MangaPagedResult {
        let filter = parseExploreFilter(category)
        return try await JmApiClient.shared.getExplorePaged(
            sourceID: config.id,
            category: filter.category,
            order: filter.order,
            page: page
        )
    }

    /// 解析 `category:order` 复合筛选标识；兼容仅传裸分类 ID 的调用（默认按最新 `mr` 排序）
    private func parseExploreFilter(_ raw: String) -> (category: String, order: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ("0", "mr") }
        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let cat = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let ord = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return (cat.isEmpty ? "0" : cat, ord.isEmpty ? "mr" : ord)
        }
        return (trimmed, "mr")
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
