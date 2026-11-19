import Foundation

/// 通用自定义 JSON 在线图源适配器
/// 约定接口路径（相对于 baseURL）：
/// - GET /popular?page={page}         -> [RemoteMangaDTO]
/// - GET /search?q={query}&page={page} -> [RemoteMangaDTO]
/// - GET /manga/{id}/chapters         -> [RemoteChapterDTO]
/// - GET /chapter/{id}/pages          -> [RemotePageDTO]
public struct GenericJSONSource: MangaSourceProtocol {
    public let config: MangaSourceConfig

    public init(config: MangaSourceConfig) {
        self.config = config
    }

    public func fetchPopular(page: Int) async throws -> [Manga] {
        let url = try buildURL(path: "/popular", queryItems: [
            URLQueryItem(name: "page", value: "\(page)")
        ])
        let dtos: [RemoteMangaDTO] = try await requestJSON(url: url)
        return dtos.map { $0.toModel(sourceID: config.id) }
    }

    public func search(query: String, page: Int) async throws -> [Manga] {
        let url = try buildURL(path: "/search", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page", value: "\(page)")
        ])
        let dtos: [RemoteMangaDTO] = try await requestJSON(url: url)
        return dtos.map { $0.toModel(sourceID: config.id) }
    }

    public func fetchChapters(for manga: Manga) async throws -> [MangaChapter] {
        let encodedID = manga.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? manga.id
        let url = try buildURL(path: "/manga/\(encodedID)/chapters")
        let dtos: [RemoteChapterDTO] = try await requestJSON(url: url)
        return dtos.enumerated().map { idx, dto in
            MangaChapter(
                id: dto.id,
                mangaID: manga.id,
                title: dto.title,
                number: dto.number ?? Double(idx + 1),
                updatedAt: dto.updatedAt ?? ""
            )
        }
    }

    public func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage] {
        let encodedID = chapter.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chapter.id
        let url = try buildURL(path: "/chapter/\(encodedID)/pages")
        let dtos: [RemotePageDTO] = try await requestJSON(url: url)
        return dtos.enumerated().map { idx, dto in
            var mergedHeaders = config.headers
            dto.headers?.forEach { mergedHeaders[$0.key] = $0.value }
            return MangaPage(
                index: dto.index ?? idx,
                imageURL: dto.imageURL,
                headers: mergedHeaders
            )
        }
    }

    private func buildURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmedBase = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard var components = URLComponents(string: trimmedBase + path) else {
            throw MangaSourceError.invalidURL(trimmedBase + path)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MangaSourceError.invalidURL(trimmedBase + path)
        }
        return url
    }

    private func requestJSON<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        for (k, v) in config.headers {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MangaSourceError.httpError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MangaSourceError.decodingFailed(error.localizedDescription)
        }
    }
}

private struct RemoteMangaDTO: Decodable {
    let id: String
    let title: String
    let author: String?
    let coverURL: String?
    let summary: String?
    let tags: [String]?
    let statusText: String?

    func toModel(sourceID: String) -> Manga {
        Manga(
            id: id,
            sourceID: sourceID,
            title: title,
            author: author ?? "",
            coverURL: coverURL ?? "",
            summary: summary ?? "",
            tags: tags ?? [],
            statusText: statusText ?? "在线"
        )
    }
}

private struct RemoteChapterDTO: Decodable {
    let id: String
    let title: String
    let number: Double?
    let updatedAt: String?
}

private struct RemotePageDTO: Decodable {
    let index: Int?
    let imageURL: String
    let headers: [String: String]?
}
