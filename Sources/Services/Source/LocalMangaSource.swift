import Foundation

/// 本地漫画库标准图源适配器（接入 MangaSourceProtocol，无缝复用阅读器/超分/滤镜/书架）
public struct LocalMangaSource: MangaSourceProtocol {
    public static let sourceID = "builtin-local-source"

    public let config: MangaSourceConfig

    public init(config: MangaSourceConfig = MangaSourceConfig(
        id: LocalMangaSource.sourceID,
        name: "本地漫画",
        kind: .local,
        baseURL: "localmanga://library",
        isEnabled: false
    )) {
        self.config = config
    }

    public func fetchPopular(page: Int) async throws -> [Manga] {
        guard page == 1 else { return [] }
        return LocalMangaLibraryManager.shared.allRecordSnapshots().map { $0.toManga() }
    }

    public func search(query: String, page: Int) async throws -> [Manga] {
        guard page == 1 else { return [] }
        let kw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = LocalMangaLibraryManager.shared.allRecordSnapshots().map { $0.toManga() }
        guard !kw.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(kw) }
    }

    public func fetchDetail(for manga: Manga) async throws -> (manga: Manga, chapters: [MangaChapter]) {
        guard let record = LocalMangaLibraryManager.shared.recordSnapshot(for: manga.id) else {
            throw MangaSourceError.decodingFailed("本地漫画文件不存在或已被删除")
        }
        let chapters = record.chapters.map { ch in
            MangaChapter(
                id: ch.id,
                mangaID: record.id,
                title: ch.title,
                number: ch.number
            )
        }
        return (record.toManga(), chapters)
    }

    public func fetchChapters(for manga: Manga) async throws -> [MangaChapter] {
        let (_, chapters) = try await fetchDetail(for: manga)
        return chapters
    }

    public func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage] {
        guard let record = LocalMangaLibraryManager.shared.recordSnapshot(for: chapter.mangaID) else {
            throw MangaSourceError.decodingFailed("本地漫画文件不存在或已被删除")
        }

        switch record.format {
        case .cbz, .zip, .epub:
            guard let chIdx = record.chapters.firstIndex(where: { $0.id == chapter.id }) else {
                return []
            }
            let entries = record.chapters[chIdx].zipEntries
            return entries.indices.map { pageIdx in
                MangaPage(
                    index: pageIdx,
                    imageURL: LocalMangaLibraryManager.zipPageURLString(
                        mangaID: record.id,
                        chapterIndex: chIdx,
                        pageIndex: pageIdx
                    )
                )
            }

        case .pdf:
            let count = record.chapters.first?.pdfPageCount ?? record.pageCount
            guard count > 0 else { return [] }
            return (0..<count).map { pageIdx in
                MangaPage(
                    index: pageIdx,
                    imageURL: LocalMangaLibraryManager.pdfPageURLString(
                        mangaID: record.id,
                        pageIndex: pageIdx
                    )
                )
            }
        }
    }
}
