import Foundation

/// 绅士漫画 (WNACG) 客户端
/// 集成官方 App JSON API 主链路、免盾镜像池 3 路并发竞速容灾与 SwiftSoup DOM 解析回退
public actor WnacgClient {
    public static let shared = WnacgClient()

    public static let defaultBaseUrls: [String] = [
        "https://www.cloudwn.shop",
        "https://www.wnmanga.shop",
        "https://www.wnacg.com",
        "https://www.wnacg.ru",
        "https://www.wnacg.buzz",
        "https://www.wnacg.site",
    ]

    public static let defaultApiBaseUrls: [String] = [
        "https://api.wnfun1.buzz",
        "https://api.wnfun1.site",
        "https://api.wnapi3.cfd",
        "https://api.wnapi4.cfd",
        "https://api.wnapi5.cfd",
    ]

    private static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private var currentBaseUrl: String = defaultBaseUrls.first!
    private var currentApiBaseUrl: String = defaultApiBaseUrls.first!
    private var hasVerifiedBaseUrl = false
    private var hasAppliedPersistedEndpoints = false

    private init() {}

    private func ensurePersistedEndpoints() async {
        guard !hasAppliedPersistedEndpoints else { return }
        hasAppliedPersistedEndpoints = true
        if let saved = await OnlineEndpointStore.shared.currentWnacgBaseUrl() {
            currentBaseUrl = saved
            hasVerifiedBaseUrl = true
        }
        if let savedApi = await OnlineEndpointStore.shared.currentWnacgApiBaseUrl() {
            currentApiBaseUrl = savedApi
        }
    }

    private func candidateWebDomains() -> [String] {
        var list = [currentBaseUrl]
        for d in Self.defaultBaseUrls where d != currentBaseUrl {
            list.append(d)
        }
        return list
    }

    private func lockWinningBaseUrl(_ domain: String) {
        currentBaseUrl = domain
        hasVerifiedBaseUrl = true
        Task { await OnlineEndpointStore.shared.updateWnacgBaseUrl(domain) }
    }

    private func executeWebWithFailover<T: Sendable>(
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        await ensurePersistedEndpoints()
        var domains = candidateWebDomains()
        var lastError: Error?

        if hasVerifiedBaseUrl, let primary = domains.first {
            do {
                return try await operation(primary)
            } catch {
                lastError = error
                hasVerifiedBaseUrl = false
                Task { await OnlineEndpointStore.shared.updateWnacgBaseUrl(nil) }
                domains = Array(domains.dropFirst())
            }
        }

        let batchSize = 3
        var index = 0
        while index < domains.count {
            let end = min(index + batchSize, domains.count)
            let batch = Array(domains[index..<end])

            let outcome: (winnerDomain: String?, value: T?, error: Error?) = await withTaskGroup(
                of: (domain: String, value: T?, error: Error?).self
            ) { group in
                for domain in batch {
                    group.addTask {
                        do {
                            let val = try await operation(domain)
                            return (domain, val, nil)
                        } catch {
                            return (domain, nil, error)
                        }
                    }
                }

                var batchErr: Error?
                for await res in group {
                    if let err = res.error {
                        if !(err is CancellationError) {
                            batchErr = err
                        }
                    } else if let val = res.value {
                        group.cancelAll()
                        return (res.domain, val, nil)
                    }
                }
                return (nil, nil, batchErr)
            }

            if let winnerDomain = outcome.winnerDomain, let value = outcome.value {
                lockWinningBaseUrl(winnerDomain)
                return value
            }
            if let err = outcome.error {
                lastError = err
            }
            index = end
        }

        throw lastError ?? MangaSourceError.decodingFailed("绅士漫画所有官方线路均不可用")
    }

    private func executeApiWithFailover<T: Sendable>(
        _ operation: @escaping @Sendable (String) async throws -> T
    ) async throws -> T {
        await ensurePersistedEndpoints()
        var candidates = [currentApiBaseUrl]
        for d in Self.defaultApiBaseUrls where d != currentApiBaseUrl {
            candidates.append(d)
        }
        var lastError: Error?

        var index = 0
        while index < candidates.count {
            let end = min(index + 2, candidates.count)
            let batch = Array(candidates[index..<end])

            let outcome: (winnerDomain: String?, value: T?, error: Error?) = await withTaskGroup(
                of: (domain: String, value: T?, error: Error?).self
            ) { group in
                for domain in batch {
                    group.addTask {
                        do {
                            let val = try await operation(domain)
                            return (domain, val, nil)
                        } catch {
                            return (domain, nil, error)
                        }
                    }
                }

                var batchErr: Error?
                for await res in group {
                    if let err = res.error {
                        if !(err is CancellationError) {
                            batchErr = err
                        }
                    } else if let val = res.value {
                        group.cancelAll()
                        return (res.domain, val, nil)
                    }
                }
                return (nil, nil, batchErr)
            }

            if let winnerDomain = outcome.winnerDomain, let value = outcome.value {
                currentApiBaseUrl = winnerDomain
                Task { await OnlineEndpointStore.shared.updateWnacgApiBaseUrl(winnerDomain) }
                return value
            }
            if let err = outcome.error {
                lastError = err
            }
            index = end
        }

        throw lastError ?? MangaSourceError.decodingFailed("绅士漫画官方 API 线路均不可用")
    }

    private nonisolated func getSafeHtml(
        path: String,
        queryParameters: [String: String] = [:],
        domain: String
    ) async throws -> String {
        guard var comps = URLComponents(string: "\(domain)\(path)") else {
            throw MangaSourceError.invalidURL("\(domain)\(path)")
        }
        if !queryParameters.isEmpty {
            comps.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else {
            throw MangaSourceError.invalidURL("\(domain)\(path)")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("zh-TW,zh;q=0.9,zh-CN;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        req.setValue("\(domain)/", forHTTPHeaderField: "Referer")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw MangaSourceError.httpError(-1)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 403 || http.statusCode >= 500 || body.isEmpty {
            throw MangaSourceError.httpError(http.statusCode)
        }
        return body
    }

    private nonisolated func getApiJsonData(
        action: String,
        queryParameters: [String: String] = [:],
        domain: String
    ) async throws -> Data {
        guard var comps = URLComponents(string: "\(domain)/") else {
            throw MangaSourceError.invalidURL(domain)
        }
        var items = [
            URLQueryItem(name: "ctl", value: "api"),
            URLQueryItem(name: "act", value: action),
        ]
        for (k, v) in queryParameters {
            items.append(URLQueryItem(name: k, value: v))
        }
        comps.queryItems = items
        guard let url = comps.url else {
            throw MangaSourceError.invalidURL(domain)
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.wnacg.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw MangaSourceError.httpError(-1)
        }
        guard (200..<400).contains(http.statusCode) else {
            throw MangaSourceError.httpError(http.statusCode)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MangaSourceError.decodingFailed("WNACG API 返回格式异常")
        }
        let codeStr = obj["code"].map { String(describing: $0) } ?? ""
        if codeStr != "0" {
            let msg = obj["msg"].map { String(describing: $0) } ?? "WNACG API 返回错误码 \(codeStr)"
            throw MangaSourceError.decodingFailed(msg)
        }
        return data
    }

    private func decodeJsonObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MangaSourceError.decodingFailed("WNACG API 返回格式异常")
        }
        return obj
    }

    // MARK: - Public Manga Source Methods

    public func getExplore(
        sourceID: String,
        cateId: String = "all",
        page: Int = 1
    ) async throws -> [Manga] {
        do {
            let apiItems = try await exploreViaApi(sourceID: sourceID, cateId: cateId, page: page)
            if !apiItems.isEmpty || page > 1 {
                return apiItems
            }
        } catch {}

        if cateId == "19" || cateId == "20" || cateId == "21" {
            return try await executeWebWithFailover { domain in
                try await self.fetchHanmanExplore(domain: domain, sourceID: sourceID, cateId: cateId, page: page)
            }
        }

        let path = (cateId == "all" || cateId.isEmpty)
            ? "/albums-index-page-\(page).html"
            : "/albums-index-page-\(page)-cate-\(cateId).html"

        return try await executeWebWithFailover { domain in
            let html = try await self.getSafeHtml(path: path, domain: domain)
            return WnacgParser.parseListHtml(html, baseUrl: domain, sourceID: sourceID)
        }
    }

    public func search(sourceID: String, query: String, page: Int = 1) async throws -> [Manga] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        do {
            let apiItems = try await searchViaApi(sourceID: sourceID, query: trimmed, page: page)
            if !apiItems.isEmpty || page > 1 {
                return apiItems
            }
        } catch {}

        let primary = try await executeWebWithFailover { domain in
            try await self.fetchWebSearchPage(domain: domain, sourceID: sourceID, query: trimmed, page: page)
        }
        if !primary.isEmpty || page > 1 {
            return primary
        }

        for fallback in buildSearchFallbackQueries(trimmed) {
            let items = try await executeWebWithFailover { domain in
                try await self.fetchWebSearchPage(domain: domain, sourceID: sourceID, query: fallback, page: 1)
            }
            if !items.isEmpty {
                return items
            }
        }
        return []
    }

    public func getDetail(sourceID: String, manga: Manga) async throws -> (manga: Manga, chapters: [MangaChapter]) {
        do {
            if let apiDetail = try await fetchApiDetail(sourceID: sourceID, manga: manga),
               !apiDetail.chapters.isEmpty {
                return apiDetail
            }
        } catch {}

        return try await executeWebWithFailover { domain in
            let html = try await self.getSafeHtml(path: "/photos-index-aid-\(manga.id).html", domain: domain)
            guard let parsed = WnacgParser.parseDetailHtml(
                aid: manga.id,
                html: html,
                baseUrl: domain,
                sourceID: sourceID,
                fallbackManga: manga
            ) else {
                throw MangaSourceError.decodingFailed("WNACG 详情页面解析失败")
            }
            return parsed
        }
    }

    public func getChapterPages(chapterId: String) async throws -> [MangaPage] {
        do {
            let apiPages = try await getApiChapterPages(aid: chapterId)
            if !apiPages.isEmpty {
                return apiPages
            }
        } catch {}

        return try await executeWebWithFailover { domain in
            let html = try await self.getSafeHtml(path: "/photos-item-aid-\(chapterId).html", domain: domain)
            let urls = WnacgParser.extractPageImageUrls(html: html, baseUrl: domain)
            return urls.enumerated().map { idx, url in
                MangaPage(index: idx, imageURL: url, headers: ["Referer": "\(domain)/"])
            }
        }
    }

    // MARK: - API Sub-methods

    private func exploreViaApi(sourceID: String, cateId: String, page: Int) async throws -> [Manga] {
        let numericCate: Int
        if cateId == "all" || cateId.isEmpty {
            numericCate = 0
        } else if let parsed = Int(cateId) {
            numericCate = parsed
        } else {
            return []
        }

        let rawData = try await executeApiWithFailover { domain in
            try await self.getApiJsonData(
                action: "albums",
                queryParameters: [
                    "cate_id": String(numericCate),
                    "page": String(page),
                    "limit": "12",
                ],
                domain: domain
            )
        }
        let payload = try decodeJsonObject(rawData)
        guard let data = payload["data"] as? [String: Any] else { return [] }
        return parseApiMangaList(data["list"], sourceID: sourceID)
    }

    private func searchViaApi(sourceID: String, query: String, page: Int) async throws -> [Manga] {
        let rawData = try await executeApiWithFailover { domain in
            try await self.getApiJsonData(
                action: "search",
                queryParameters: ["kw": query, "page": String(page)],
                domain: domain
            )
        }
        let payload = try decodeJsonObject(rawData)
        guard let data = payload["data"] as? [String: Any] else { return [] }
        return parseApiMangaList(data["list"], sourceID: sourceID)
    }

    private func fetchApiDetail(
        sourceID: String,
        manga: Manga
    ) async throws -> (manga: Manga, chapters: [MangaChapter])? {
        let rawDetailData = try await executeApiWithFailover { domain in
            try await self.getApiJsonData(
                action: "detail",
                queryParameters: ["aid": manga.id],
                domain: domain
            )
        }
        let payload = try decodeJsonObject(rawDetailData)
        guard let data = payload["data"] as? [String: Any] else { return nil }

        let isSeries = readInt(data["is_series"]) == 1
        var chapters: [MangaChapter] = []

        if isSeries {
            let rawChaptersData = try await executeApiWithFailover { domain in
                try await self.getApiJsonData(
                    action: "chapters",
                    queryParameters: [
                        "sid": manga.id,
                        "page": "1",
                        "limit": "200",
                        "order": "asc",
                    ],
                    domain: domain
                )
            }
            let chaptersPayload = try decodeJsonObject(rawChaptersData)
            if let chData = chaptersPayload["data"] as? [String: Any],
               let list = chData["list"] as? [[String: Any]] {
                for (idx, item) in list.enumerated() {
                    let chId = cleanString(item["id"])
                    guard !chId.isEmpty else { continue }
                    let chTitle = cleanString(item["title"])
                    let order = readInt(item["idx"])
                    chapters.append(
                        MangaChapter(
                            id: chId,
                            mangaID: manga.id,
                            title: chTitle.isEmpty ? "第 \(idx + 1) 话" : chTitle,
                            number: Double(order > 0 ? order : (idx + 1))
                        )
                    )
                }
            }
        } else {
            chapters.append(MangaChapter(id: manga.id, mangaID: manga.id, title: "全本阅览", number: 1))
        }

        var tags: [String] = []
        if let rawTags = data["tags"] as? [Any] {
            for t in rawTags {
                let s = cleanString(t)
                if !s.isEmpty, !tags.contains(s) { tags.append(s) }
            }
        }
        let category = WnacgParser.normalizeCategory(cleanString(data["category"]))
        if !category.isEmpty, !tags.contains(category) {
            tags.insert(category, at: 0)
        }

        let title = cleanString(data["title"])
        let finalTitle = title.isEmpty ? manga.title : title
        let author = cleanString(data["author"])
        let desc = cleanString(data["desc"])
        let cover = WnacgParser.cleanWnacgUrl(cleanString(data["cover"]), baseUrl: currentBaseUrl)

        let statusText = MangaSerialStatusHelper.inferStatusText(
            title: finalTitle,
            tags: tags,
            rawStatus: data["status"],
            rawIsEnd: data["is_end"],
            isSeries: isSeries,
            chapterCount: chapters.count
        )

        let updated = Manga(
            id: manga.id,
            sourceID: sourceID,
            title: finalTitle,
            author: author.isEmpty ? "佚名" : author,
            coverURL: cover.isEmpty ? manga.coverURL : cover,
            coverHeaders: ["Referer": "https://www.wnacg.com/"],
            summary: desc.isEmpty ? "暂无简介" : desc,
            tags: tags,
            statusText: statusText
        )
        return (updated, chapters)
    }

    private func getApiChapterPages(aid: String) async throws -> [MangaPage] {
        let rawPagesData = try await executeApiWithFailover { domain in
            try await self.getApiJsonData(
                action: "pages",
                queryParameters: ["aid": aid],
                domain: domain
            )
        }
        let payload = try decodeJsonObject(rawPagesData)
        guard let data = payload["data"] as? [String: Any],
              let rawPages = data["pages"] as? [[String: Any]] else {
            return []
        }

        var urls: [String] = []
        for entry in rawPages {
            let raw = cleanString(entry["url"])
            let cleaned = raw.isEmpty ? "" : WnacgParser.cleanWnacgUrl(raw, baseUrl: currentBaseUrl)
            if !cleaned.isEmpty, !urls.contains(cleaned) {
                urls.append(cleaned)
            }
        }
        return urls.enumerated().map { idx, url in
            MangaPage(index: idx, imageURL: url, headers: ["Referer": "https://www.wnacg.com/"])
        }
    }

    private func parseApiMangaList(_ rawList: Any?, sourceID: String) -> [Manga] {
        guard let list = rawList as? [[String: Any]] else { return [] }
        var items: [Manga] = []
        for entry in list {
            let id = cleanString(entry["id"])
            let title = cleanString(entry["title"])
            guard !id.isEmpty, !title.isEmpty else { continue }

            let pages = readInt(entry["pages"])
            let date = cleanString(entry["time"])
            let chapterText = pages > 0 ? "\(pages) P\(date.isEmpty ? "" : " · \(date)")" : date
            let category = WnacgParser.normalizeCategory(cleanString(entry["category"]))
            let statusText = MangaSerialStatusHelper.inferStatusText(
                title: title,
                latestChapter: chapterText,
                rawStatus: entry["status"],
                rawIsEnd: entry["is_end"],
                isSeries: readInt(entry["is_series"]) == 1
            )

            items.append(
                Manga(
                    id: id,
                    sourceID: sourceID,
                    title: title,
                    author: "绅士本",
                    coverURL: WnacgParser.cleanWnacgUrl(cleanString(entry["cover"]), baseUrl: currentBaseUrl),
                    coverHeaders: ["Referer": "https://www.wnacg.com/"],
                    summary: chapterText,
                    tags: [category.isEmpty ? "绅士漫画" : category],
                    statusText: statusText.isEmpty ? chapterText : statusText
                )
            )
        }
        return items
    }

    // MARK: - Web HTML Helpers

    private nonisolated func fetchWebSearchPage(
        domain: String,
        sourceID: String,
        query: String,
        page: Int
    ) async throws -> [Manga] {
        let html = try await getSafeHtml(
            path: "/search/",
            queryParameters: [
                "q": query,
                "f": "_all",
                "s": "create_time_DESC",
                "syn": "yes",
                "p": String(page),
            ],
            domain: domain
        )
        return WnacgParser.parseListHtml(html, baseUrl: domain, sourceID: sourceID)
    }

    private nonisolated func fetchHanmanTagBatch(domain: String, sourceID: String) async -> [Manga] {
        guard let html = try? await getSafeHtml(
            path: "/albums-index-tag-%E9%9F%93%E6%BC%AB.html",
            domain: domain
        ) else { return [] }
        return WnacgParser.parseListHtml(html, baseUrl: domain, sourceID: sourceID)
    }

    private nonisolated func fetchHanmanExplore(
        domain: String,
        sourceID: String,
        cateId: String,
        page: Int
    ) async throws -> [Manga] {
        let label = cateId == "20" ? "韩漫 / 汉化" : "韩漫"
        if page <= 1 {
            async let tagBatch = fetchHanmanTagBatch(domain: domain, sourceID: sourceID)
            async let search1: [Manga] = (try? await fetchWebSearchPage(
                domain: domain, sourceID: sourceID, query: "韓漫", page: 1
            )) ?? []
            async let search2: [Manga] = (try? await fetchWebSearchPage(
                domain: domain, sourceID: sourceID, query: "韓國", page: 1
            )) ?? []

            let batches = await [tagBatch, search1, search2]
            var seen = Set<String>()
            var merged: [Manga] = []
            for batch in batches {
                for var item in batch where seen.insert(item.id).inserted {
                    if !item.tags.contains(where: { $0.contains("韩漫") }) {
                        item.tags.insert(label, at: 0)
                    }
                    merged.append(item)
                }
            }
            guard !merged.isEmpty else {
                throw MangaSourceError.decodingFailed("韩漫分类聚合暂无可用数据")
            }
            return merged
        }

        let pageItems = try await fetchWebSearchPage(domain: domain, sourceID: sourceID, query: "韓國", page: page)
        return pageItems.map { item in
            var copy = item
            if !copy.tags.contains(where: { $0.contains("韩漫") }) {
                copy.tags.insert(label, at: 0)
            }
            return copy
        }
    }

    private func buildSearchFallbackQueries(_ rawQuery: String) -> [String] {
        var candidates: [String] = []
        let normalized = rawQuery
            .replacingOccurrences(of: #"[!！?？:：;；"'“”‘’~—\-_/\\|()（）\[\]【】《》<>]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !normalized.isEmpty, normalized != rawQuery {
            candidates.append(normalized)
        }

        if let regex = try? NSRegularExpression(pattern: #"[\u4e00-\u9fff]{2,}"#) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            let runs = regex.matches(in: normalized, range: range).compactMap { m -> String? in
                guard let r = Range(m.range, in: normalized) else { return nil }
                return String(normalized[r])
            }
            .filter { $0 != rawQuery && $0 != normalized }
            .sorted { $0.count > $1.count }

            for run in runs where !candidates.contains(run) {
                candidates.append(run)
            }
        }
        return candidates
    }

    private func cleanString(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readInt(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return Int(cleanString(value)) ?? 0
    }
}
