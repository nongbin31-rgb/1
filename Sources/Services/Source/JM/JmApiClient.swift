import Foundation

/// 禁漫天堂 (JMComic) 协议客户端
/// 集成动态域名解密刷新、3 路并发镜像竞速自愈与 scramble_id 并行解析
public actor JmApiClient {
    public static let shared = JmApiClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    private var resolvedImageDomain: String?
    private var lastWorkingApiBase: String?
    private var resolvedApiDomains: [String] = []
    private var hasAttemptedDynamicDomainRefresh = false
    private var hasLoadedPersistedEndpoints = false
    private var scrambleIdCache: [String: Int] = [:]
    private var inFlightScrambleTasks: [String: Task<Int, Never>] = [:]
    private var isFetchingSetting = false

    private init() {}

    public func currentImageDomain() async -> String {
        await ensurePersistedEndpoints()
        if let resolvedImageDomain, !resolvedImageDomain.isEmpty {
            return resolvedImageDomain
        }
        return JmCrypto.defaultImageDomains.first ?? "cdn-msp2.jmapiproxy3.cc"
    }

    private func ensurePersistedEndpoints() async {
        guard !hasLoadedPersistedEndpoints else { return }
        hasLoadedPersistedEndpoints = true
        if let savedBase = await OnlineEndpointStore.shared.currentJmApiBase() {
            lastWorkingApiBase = savedBase
        }
        if let savedImg = await OnlineEndpointStore.shared.currentJmImageDomain() {
            resolvedImageDomain = savedImg
        }
    }

    private func normalizeDomainBase(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func candidateApiBases() -> [String] {
        var list: [String] = []
        func addBase(_ raw: String) {
            let normalized = normalizeDomainBase(raw)
            if !normalized.isEmpty, !list.contains(normalized) {
                list.append(normalized)
            }
        }
        if let lastWorkingApiBase, !lastWorkingApiBase.isEmpty {
            addBase(lastWorkingApiBase)
        }
        for domain in resolvedApiDomains { addBase(domain) }
        for domain in JmCrypto.defaultApiDomains { addBase(domain) }
        return list
    }

    private func applyResolvedImageDomain(_ rawHost: String?) {
        guard let sanitized = OnlineEndpointStore.sanitizeHost(rawHost) else { return }
        resolvedImageDomain = sanitized
        Task { await OnlineEndpointStore.shared.updateJmImageDomain(sanitized) }
    }

    private func recordWorkingApiBase(_ base: String) {
        lastWorkingApiBase = base
        Task { await OnlineEndpointStore.shared.updateJmApiBase(base) }
    }

    private func clearWorkingApiBase(_ failedBase: String) {
        if lastWorkingApiBase == failedBase {
            lastWorkingApiBase = nil
            Task { await OnlineEndpointStore.shared.updateJmApiBase(nil) }
        }
    }

    private func refreshDynamicDomains() async -> [String] {
        hasAttemptedDynamicDomainRefresh = true
        for endpoint in JmCrypto.apiDomainServerUrls {
            guard let url = URL(string: endpoint) else { continue }
            var req = URLRequest(url: url)
            req.setValue(JmCrypto.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 6
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let body = String(data: data, encoding: .utf8) else {
                    continue
                }
                let domains = JmCrypto.decryptDomainServerPayload(body)
                if !domains.isEmpty {
                    resolvedApiDomains = domains
                    return domains
                }
            } catch {
                continue
            }
        }
        return []
    }

    private func maybeRefreshSettingInBackground(base: String) {
        guard resolvedImageDomain == nil, !isFetchingSetting else { return }
        isFetchingSetting = true
        Task {
            await self.refreshSetting(base: base)
        }
    }

    private func refreshSetting(base: String) async {
        defer { isFetchingSetting = false }
        guard let data = try? await performSingleDecryptedRequest(
            base: base,
            path: "/setting",
            queryParameters: [:],
            tokenSecret: JmCrypto.defaultAppTokenSecret
        ) as? [String: Any],
        let imgHost = data["img_host"] else {
            return
        }
        applyResolvedImageDomain(String(describing: imgHost))
    }

    private nonisolated func decodeJmResponseBody(_ rawBody: String, timestamp ts: Int) throws -> Any? {
        let stripped = rawBody.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard stripped.hasPrefix("{") || stripped.hasPrefix("[") else {
            throw MangaSourceError.decodingFailed("JM 接口返回非 JSON 内容")
        }
        guard let jsonData = stripped.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MangaSourceError.decodingFailed("JM API 返回格式无效")
        }
        let codeStr = envelope["code"].map { String(describing: $0) } ?? ""
        if codeStr != "200" {
            let msg = envelope["errorMsg"] ?? envelope["message"] ?? "未知错误"
            throw MangaSourceError.decodingFailed("JM API 错误 \(codeStr): \(msg)")
        }

        let dataField = envelope["data"]
        if let encrypted = dataField as? String {
            let plain = try JmCrypto.decryptData(encrypted, timestamp: ts)
            if plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            guard let plainData = plain.data(using: .utf8) else {
                throw MangaSourceError.decodingFailed("JM 解密后 JSON 编码无效")
            }
            return try JSONSerialization.jsonObject(with: plainData)
        }
        return dataField
    }

    private func performSingleDecryptedRequest(
        base: String,
        path: String,
        queryParameters: [String: String],
        tokenSecret: String
    ) async throws -> Any? {
        guard var components = URLComponents(string: "\(base)\(path)") else {
            throw MangaSourceError.invalidURL("\(base)\(path)")
        }
        if !queryParameters.isEmpty {
            components.queryItems = queryParameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw MangaSourceError.invalidURL("\(base)\(path)")
        }

        let ts = JmCrypto.currentTimestampSeconds()
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        for (k, v) in JmCrypto.buildHeaders(timestamp: ts, tokenSecret: tokenSecret) {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw MangaSourceError.httpError(-1)
        }
        guard (200...299).contains(http.statusCode) else {
            throw MangaSourceError.httpError(http.statusCode)
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw MangaSourceError.decodingFailed("JM 响应非 UTF-8 文本")
        }
        return try decodeJmResponseBody(body, timestamp: ts)
    }

    public func requestDecryptedJson(
        path: String,
        queryParameters: [String: String] = [:],
        useContentSecret: Bool = false
    ) async throws -> Any? {
        await ensurePersistedEndpoints()
        let secret = useContentSecret ? JmCrypto.defaultAppTokenSecret2 : JmCrypto.defaultAppTokenSecret
        var triedBases = Set<String>()
        var lastError: Error?

        let firstTry = await tryRequestBases(
            candidateApiBases(),
            path: path,
            queryParameters: queryParameters,
            tokenSecret: secret,
            triedBases: triedBases
        )
        if firstTry.hit {
            return firstTry.payload
        }
        triedBases = firstTry.triedBases
        if let err = firstTry.lastError {
            lastError = err
        }

        if !hasAttemptedDynamicDomainRefresh {
            let freshDomains = await refreshDynamicDomains()
            if !freshDomains.isEmpty {
                let freshBases = freshDomains.map(normalizeDomainBase)
                let secondTry = await tryRequestBases(
                    freshBases,
                    path: path,
                    queryParameters: queryParameters,
                    tokenSecret: secret,
                    triedBases: triedBases
                )
                if secondTry.hit {
                    return secondTry.payload
                }
                if let err = secondTry.lastError {
                    lastError = err
                }
            }
        }

        throw lastError ?? MangaSourceError.decodingFailed("所有禁漫天堂 API 域名均不可用")
    }

    private func tryRequestBases(
        _ bases: [String],
        path: String,
        queryParameters: [String: String],
        tokenSecret: String,
        triedBases initialTried: Set<String>
    ) async -> (hit: Bool, payload: Any?, triedBases: Set<String>, lastError: Error?) {
        var triedBases = initialTried
        let pending = bases.filter { triedBases.insert($0).inserted }
        guard !pending.isEmpty else { return (false, nil, triedBases, nil) }

        var lastError: Error?
        var startIndex = 0
        if let working = lastWorkingApiBase, pending.first == working {
            do {
                let result = try await performSingleDecryptedRequest(
                    base: working,
                    path: path,
                    queryParameters: queryParameters,
                    tokenSecret: tokenSecret
                )
                recordWorkingApiBase(working)
                if path != "/setting" { maybeRefreshSettingInBackground(base: working) }
                return (true, result, triedBases, nil)
            } catch {
                lastError = error
                clearWorkingApiBase(working)
                startIndex = 1
            }
        }

        let batchSize = 3
        var idx = startIndex
        while idx < pending.count {
            let end = min(idx + batchSize, pending.count)
            let batch = Array(pending[idx..<end])

            let outcome: (winnerBase: String?, payload: Any?, error: Error?) = await withTaskGroup(
                of: (base: String, payload: Any?, error: Error?).self
            ) { group in
                for candidate in batch {
                    group.addTask {
                        do {
                            let res = try await self.performSingleDecryptedRequest(
                                base: candidate,
                                path: path,
                                queryParameters: queryParameters,
                                tokenSecret: tokenSecret
                            )
                            return (candidate, res, nil)
                        } catch {
                            return (candidate, nil, error)
                        }
                    }
                }

                var batchError: Error?
                for await result in group {
                    if let err = result.error {
                        if !(err is CancellationError) {
                            batchError = err
                        }
                    } else {
                        group.cancelAll()
                        return (result.base, result.payload, nil)
                    }
                }
                return (nil, nil, batchError)
            }

            if let winnerBase = outcome.winnerBase {
                recordWorkingApiBase(winnerBase)
                if path != "/setting" { maybeRefreshSettingInBackground(base: winnerBase) }
                return (true, outcome.payload, triedBases, nil)
            }
            if let err = outcome.error {
                lastError = err
            }
            idx = end
        }
        return (false, nil, triedBases, lastError)
    }

    public func buildCoverURL(albumId: String) -> String {
        let domain = resolvedImageDomain ?? JmCrypto.defaultImageDomains.first ?? "cdn-msp2.jmapiproxy3.cc"
        return "https://\(domain)/media/albums/\(albumId)_3x4.jpg"
    }

    public func buildChapterImageURL(
        photoId: String,
        fileName: String,
        scrambleId: Int = JmCrypto.defaultScrambleId
    ) -> String {
        let domain = resolvedImageDomain ?? JmCrypto.defaultImageDomains.first ?? "cdn-msp2.jmapiproxy3.cc"
        return "https://\(domain)/media/photos/\(photoId)/\(fileName)#jm=\(photoId),\(scrambleId)"
    }

    // MARK: - Public Manga Source API

    public func getExplore(
        sourceID: String,
        category: String = "0",
        order: String = "mr",
        page: Int = 1
    ) async throws -> [Manga] {
        let data = try await requestDecryptedJson(
            path: "/categories/filter",
            queryParameters: [
                "o": order,
                "c": category.isEmpty ? "0" : category,
                "page": String(page),
            ]
        )
        if let map = data as? [String: Any] {
            return parseMangaList(map["content"], sourceID: sourceID)
        }
        return parseMangaList(data, sourceID: sourceID)
    }

    public func search(sourceID: String, query: String, page: Int = 1) async throws -> [Manga] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let data = try await requestDecryptedJson(
            path: "/search",
            queryParameters: [
                "search_query": trimmed,
                "page": String(page),
                "o": "mr",
            ]
        )

        if let map = data as? [String: Any] {
            if let redirectAidRaw = map["redirect_aid"] {
                let redirectAid = String(describing: redirectAidRaw).trimmingCharacters(in: .whitespacesAndNewlines)
                if !redirectAid.isEmpty, redirectAid != "0", redirectAid != "<null>" {
                    if let albumData = try await requestDecryptedJson(
                        path: "/album",
                        queryParameters: ["id": redirectAid]
                    ) as? [String: Any] {
                        return [parseMangaItem(albumData, sourceID: sourceID, fallbackId: redirectAid)]
                    }
                }
            }
            return parseMangaList(map["content"], sourceID: sourceID)
        }
        return parseMangaList(data, sourceID: sourceID)
    }

    public func getDetail(sourceID: String, manga: Manga) async throws -> (manga: Manga, chapters: [MangaChapter]) {
        guard let data = try await requestDecryptedJson(
            path: "/album",
            queryParameters: ["id": manga.id]
        ) as? [String: Any] else {
            throw MangaSourceError.decodingFailed("JM 详情数据格式无效")
        }

        let title = cleanField(data["name"]) ?? manga.title
        let author = cleanField(data["author"]) ?? (manga.author.isEmpty ? "佚名" : manga.author)
        let summary = cleanField(data["description"]) ?? "暂无简介"
        let coverURL = buildCoverURL(albumId: manga.id)

        var tags: [String] = []
        if let rawTags = data["tags"] as? [Any] {
            for item in rawTags {
                if let tag = cleanField(item), !tags.contains(tag) {
                    tags.append(tag)
                }
            }
        }
        if let categoryTitle = extractCategoryTitle(data["category"], data["category_sub"]),
           !tags.contains(categoryTitle) {
            tags.insert(categoryTitle, at: 0)
        }

        var chapters: [MangaChapter] = []
        if let rawSeries = data["series"] as? [[String: Any]], !rawSeries.isEmpty {
            let sorted = rawSeries.sorted { a, b in
                let sa = Int(cleanField(a["sort"]) ?? "") ?? 0
                let sb = Int(cleanField(b["sort"]) ?? "") ?? 0
                return sa < sb
            }
            for (idx, item) in sorted.enumerated() {
                guard let chId = cleanField(item["id"]) else { continue }
                let rawName = cleanField(item["name"]) ?? ""
                let sortLabel = cleanField(item["sort"]) ?? "\(idx + 1)"
                let chTitle = rawName.isEmpty ? "第 \(sortLabel) 话" : rawName
                chapters.append(
                    MangaChapter(
                        id: chId,
                        mangaID: manga.id,
                        title: chTitle,
                        number: Double(idx + 1)
                    )
                )
            }
        } else {
            chapters.append(
                MangaChapter(
                    id: manga.id,
                    mangaID: manga.id,
                    title: "全一话",
                    number: 1
                )
            )
        }

        let statusText = MangaSerialStatusHelper.inferStatusText(
            title: title,
            tags: tags,
            rawStatus: data["status"],
            rawIsEnd: data["is_end"],
            isSeries: chapters.count > 1,
            chapterCount: chapters.count
        )

        let updatedManga = Manga(
            id: manga.id,
            sourceID: sourceID,
            title: title,
            author: author,
            coverURL: coverURL,
            coverHeaders: ["User-Agent": JmCrypto.defaultUserAgent],
            summary: summary,
            tags: tags,
            statusText: statusText
        )
        return (updatedManga, chapters)
    }

    public func getChapterPages(photoId: String) async throws -> [MangaPage] {
        let idNum = Int(photoId) ?? 0
        let needsRemoteScramble = (idNum <= 0 || idNum >= JmCrypto.defaultScrambleId)

        async let chapterReq = requestDecryptedJson(path: "/chapter", queryParameters: ["id": photoId])
        async let scrambleReq: Int = needsRemoteScramble ? fetchScrambleId(photoId: photoId) : JmCrypto.defaultScrambleId

        guard let data = try await chapterReq as? [String: Any],
              let rawImages = data["images"] as? [Any],
              !rawImages.isEmpty else {
            return []
        }

        let scrambleId = await scrambleReq
        var pages: [MangaPage] = []
        for (idx, rawName) in rawImages.enumerated() {
            guard let fileName = cleanField(rawName) else { continue }
            let imageURL = buildChapterImageURL(photoId: photoId, fileName: fileName, scrambleId: scrambleId)
            pages.append(
                MangaPage(
                    index: idx,
                    imageURL: imageURL,
                    headers: ["User-Agent": JmCrypto.defaultUserAgent]
                )
            )
        }
        return pages
    }

    // MARK: - Scramble ID

    private func fetchScrambleId(photoId: String) async -> Int {
        if let cached = scrambleIdCache[photoId] {
            return cached
        }
        if let inFlight = inFlightScrambleTasks[photoId] {
            return await inFlight.value
        }

        let task = Task<Int, Never> {
            await self.doFetchScrambleId(photoId: photoId)
        }
        inFlightScrambleTasks[photoId] = task
        let resolved = await task.value
        inFlightScrambleTasks.removeValue(forKey: photoId)
        if scrambleIdCache.count >= 200, let firstKey = scrambleIdCache.keys.first {
            scrambleIdCache.removeValue(forKey: firstKey)
        }
        scrambleIdCache[photoId] = resolved
        return resolved
    }

    private func doFetchScrambleId(photoId: String) async -> Int {
        await ensurePersistedEndpoints()
        let bases = candidateApiBases()
        guard !bases.isEmpty else { return JmCrypto.defaultScrambleId }

        func tryOne(_ base: String) async -> Int? {
            guard var comps = URLComponents(string: "\(base)/chapter_view_template") else { return nil }
            comps.queryItems = [
                URLQueryItem(name: "id", value: photoId),
                URLQueryItem(name: "mode", value: "vertical"),
            ]
            guard let url = comps.url else { return nil }
            let ts = JmCrypto.currentTimestampSeconds()
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            for (k, v) in JmCrypto.buildHeaders(timestamp: ts, tokenSecret: JmCrypto.defaultAppTokenSecret2) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let (data, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let body = String(data: data, encoding: .utf8) else {
                return nil
            }
            if let range = body.range(of: #"var\s+scramble_id\s*=\s*(\d+)\s*;"#, options: .regularExpression) {
                let matched = String(body[range])
                let digits = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                return Int(digits) ?? JmCrypto.defaultScrambleId
            }
            return nil
        }

        if let working = lastWorkingApiBase, bases.first == working, let hit = await tryOne(working) {
            return hit
        }

        let candidates = Array(bases.prefix(2))
        return await withTaskGroup(of: Int?.self) { group in
            for candidate in candidates {
                group.addTask { await tryOne(candidate) }
            }
            for await val in group {
                if let val {
                    group.cancelAll()
                    return val
                }
            }
            return JmCrypto.defaultScrambleId
        }
    }

    // MARK: - Parsing Helpers

    private func parseMangaList(_ rawList: Any?, sourceID: String) -> [Manga] {
        guard let list = rawList as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            let parsed = parseMangaItem(item, sourceID: sourceID)
            return parsed.id.isEmpty ? nil : parsed
        }
    }

    private func parseMangaItem(
        _ raw: [String: Any],
        sourceID: String,
        fallbackId: String? = nil,
        fallbackTitle: String? = nil
    ) -> Manga {
        let id = cleanField(raw["id"]) ?? fallbackId ?? ""
        let title = cleanField(raw["name"]) ?? fallbackTitle ?? "JM \(id)"
        let author = cleanField(raw["author"]) ?? "佚名"
        let category = extractCategoryTitle(raw["category"], raw["category_sub"]) ?? "禁漫单行本"
        let latestChapter = cleanField(raw["latest_ep_name"])

        var tags: [String] = [category]
        if let rawTags = raw["tags"] as? [Any] {
            for t in rawTags {
                if let s = cleanField(t), !tags.contains(s) {
                    tags.append(s)
                }
            }
        }

        let statusText = MangaSerialStatusHelper.inferStatusText(
            title: title,
            latestChapter: latestChapter,
            tags: tags,
            rawStatus: raw["status"],
            rawIsEnd: raw["is_end"]
        )

        return Manga(
            id: id,
            sourceID: sourceID,
            title: title,
            author: author,
            coverURL: buildCoverURL(albumId: id),
            coverHeaders: ["User-Agent": JmCrypto.defaultUserAgent],
            summary: "",
            tags: tags,
            statusText: statusText.isEmpty ? (latestChapter ?? "") : statusText
        )
    }

    private func extractCategoryTitle(_ rawCat: Any?, _ rawSubCat: Any?) -> String? {
        for candidate in [rawCat, rawSubCat] {
            if let dict = candidate as? [String: Any], let title = cleanField(dict["title"]) {
                return title
            }
            if let str = candidate as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return str.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func cleanField(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        let s = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
