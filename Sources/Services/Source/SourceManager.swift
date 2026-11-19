import Foundation
import SwiftUI

/// 应用核心状态管理器：在线图源、书架收藏、阅读进度、超分与阅读器全局配置
@MainActor
public final class AppStore: ObservableObject {
    @Published public var sources: [MangaSourceConfig] = [] {
        didSet { save(sources, key: Keys.sources) }
    }
    @Published public var bookshelf: [Manga] = [] {
        didSet { save(bookshelf, key: Keys.bookshelf) }
    }
    @Published public var progressMap: [String: ReadingProgress] = [:] {
        didSet { save(progressMap, key: Keys.progress) }
    }
    @Published public var upscalerConfig: ImageUpscalerConfig = ImageUpscalerConfig() {
        didSet { save(upscalerConfig, key: Keys.upscaler) }
    }
    @Published public var readerLayoutMode: ReaderLayoutMode = .verticalWebtoon {
        didSet { save(readerLayoutMode, key: Keys.layoutMode) }
    }
    @Published public var selectedSourceID: String = ""

    private enum Keys {
        static let sources = "keda_online_sources_v1"
        static let bookshelf = "keda_online_bookshelf_v1"
        static let progress = "keda_online_progress_v1"
        static let upscaler = "keda_online_upscaler_v1"
        static let layoutMode = "keda_online_layout_v1"
    }

    public init() {
        let builtinSources: [MangaSourceConfig] = [
            MangaSourceConfig(
                id: "builtin-jm-source",
                name: "禁漫天堂",
                kind: .jm,
                baseURL: "https://www.cdnbtd.cc",
                isEnabled: true
            ),
            MangaSourceConfig(
                id: "builtin-wnacg-source",
                name: "绅士漫画",
                kind: .wnacg,
                baseURL: "https://www.cloudwn.shop",
                isEnabled: true
            ),
            MangaSourceConfig(
                id: "builtin-demo-source",
                name: "超分演示源",
                kind: .demo,
                baseURL: "https://demo.local",
                isEnabled: true
            ),
        ]

        let savedSources: [MangaSourceConfig]? = load(key: Keys.sources)
        if var existing = savedSources, !existing.isEmpty {
            for builtin in builtinSources.reversed() where !existing.contains(where: { $0.id == builtin.id }) {
                existing.insert(builtin, at: 0)
            }
            self.sources = existing
        } else {
            self.sources = builtinSources
        }
        self.selectedSourceID = self.sources.first(where: { $0.isEnabled })?.id ?? self.sources.first?.id ?? ""
        self.bookshelf = load(key: Keys.bookshelf) ?? []
        self.progressMap = load(key: Keys.progress) ?? [:]
        self.upscalerConfig = load(key: Keys.upscaler) ?? ImageUpscalerConfig(
            engine: .anime4k,
            waifu2x: .anime_noise1_scale2x,
            anime4k: Anime4kConfig(preset: .AAFast, thinLines: false, darkenLines: false)
        )
        self.readerLayoutMode = load(key: Keys.layoutMode) ?? .verticalWebtoon
    }

    public var enabledSources: [MangaSourceConfig] {
        sources.filter { $0.isEnabled }
    }

    public func adapter(for sourceID: String) -> (any MangaSourceProtocol)? {
        guard let config = sources.first(where: { $0.id == sourceID }) else { return nil }
        switch config.kind {
        case .demo:
            return BuiltinDemoSource(config: config)
        case .genericJSON:
            return GenericJSONSource(config: config)
        case .jm:
            return JmMangaSource(config: config)
        case .wnacg:
            return WnacgMangaSource(config: config)
        }
    }

    public func isInBookshelf(_ manga: Manga) -> Bool {
        bookshelf.contains(where: { $0.compositeKey == manga.compositeKey })
    }

    public func toggleBookshelf(_ manga: Manga) {
        if let idx = bookshelf.firstIndex(where: { $0.compositeKey == manga.compositeKey }) {
            bookshelf.remove(at: idx)
        } else {
            bookshelf.insert(manga, at: 0)
        }
    }

    public func updateProgress(manga: Manga, chapter: MangaChapter, pageIndex: Int) {
        progressMap[manga.compositeKey] = ReadingProgress(
            mangaKey: manga.compositeKey,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            pageIndex: pageIndex,
            updatedAt: Date()
        )
    }

    public func progress(for manga: Manga) -> ReadingProgress? {
        progressMap[manga.compositeKey]
    }

    public func addSource(_ source: MangaSourceConfig) {
        sources.append(source)
        if selectedSourceID.isEmpty {
            selectedSourceID = source.id
        }
    }

    public func removeSource(id: String) {
        sources.removeAll { $0.id == id }
        if selectedSourceID == id {
            selectedSourceID = sources.first?.id ?? ""
        }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load<T: Decodable>(key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
