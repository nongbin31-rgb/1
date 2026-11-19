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
    @Published public var enableImageUpscaler: Bool = false {
        didSet { save(enableImageUpscaler, key: Keys.enableUpscaler) }
    }
    @Published public var transitionAfterImageUpscaled: Bool = true {
        didSet { save(transitionAfterImageUpscaled, key: Keys.transitionAfterUpscaled) }
    }
    @Published public var readerLayoutMode: ReaderLayoutMode = .verticalWebtoon {
        didSet { save(readerLayoutMode, key: Keys.layoutMode) }
    }
    @Published public var pageTurningEffect: PageTurningEffect = .curling {
        didSet { save(pageTurningEffect, key: Keys.turningEffect) }
    }
    @Published public var pageTurnSoundEnabled: Bool = true {
        didSet { save(pageTurnSoundEnabled, key: Keys.soundEnabled) }
    }
    @Published public var showSpineShadowInCurl: Bool = true {
        didSet { save(showSpineShadowInCurl, key: Keys.spineShadow) }
    }
    @Published public var preferredReaderBackground: ReaderBackground = .followSystem {
        didSet { save(preferredReaderBackground, key: Keys.readerBackground) }
    }
    @Published public var readerTextureType: ReaderTextureType = .classic {
        didSet { save(readerTextureType, key: Keys.readerTextureType) }
    }
    @Published public var readerTextureOpacity: Double = 0.4 {
        didSet { save(readerTextureOpacity, key: Keys.readerTextureOpacity) }
    }
    @Published public var readerTextureTarget: ReaderTextureTarget = .both {
        didSet { save(readerTextureTarget, key: Keys.readerTextureTarget) }
    }
    @Published public var showSpineDividingLine: Bool = true {
        didSet { save(showSpineDividingLine, key: Keys.spineDividingLine) }
    }
    @Published public var selectedSourceID: String = ""

    private enum Keys {
        static let sources = "keda_online_sources_v1"
        static let bookshelf = "keda_online_bookshelf_v1"
        static let progress = "keda_online_progress_v1"
        static let upscaler = "keda_online_upscaler_v1"
        static let enableUpscaler = "keda_online_enable_upscaler_v1"
        static let transitionAfterUpscaled = "keda_online_transition_after_upscaled_v1"
        static let layoutMode = "keda_online_layout_v1"
        static let turningEffect = "keda_online_turning_effect_v1"
        static let soundEnabled = "keda_online_sound_enabled_v1"
        static let spineShadow = "keda_online_spine_shadow_v1"
        static let readerBackground = "keda_online_reader_background_v1"
        static let readerTextureType = "keda_online_reader_texture_type_v1"
        static let readerTextureOpacity = "keda_online_reader_texture_opacity_v1"
        static let readerTextureTarget = "keda_online_reader_texture_target_v1"
        static let spineDividingLine = "keda_online_spine_dividing_line_v1"
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
            model: .anime4k,
            anime4k: Anime4kConfig(preset: .AAFast, thinLines: false, darkenLines: false),
            waifu2x: .anime_noise1_scale2x
        )
        self.enableImageUpscaler = load(key: Keys.enableUpscaler) ?? false
        self.transitionAfterImageUpscaled = load(key: Keys.transitionAfterUpscaled) ?? true
        self.readerLayoutMode = load(key: Keys.layoutMode) ?? .verticalWebtoon
        self.pageTurningEffect = load(key: Keys.turningEffect) ?? .curling
        self.pageTurnSoundEnabled = load(key: Keys.soundEnabled) ?? true
        self.showSpineShadowInCurl = load(key: Keys.spineShadow) ?? true
        self.preferredReaderBackground = load(key: Keys.readerBackground) ?? .followSystem
        self.readerTextureType = load(key: Keys.readerTextureType) ?? .classic
        self.readerTextureOpacity = load(key: Keys.readerTextureOpacity) ?? 0.4
        self.readerTextureTarget = load(key: Keys.readerTextureTarget) ?? .both
        self.showSpineDividingLine = load(key: Keys.spineDividingLine) ?? true
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
