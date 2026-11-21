import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

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
    @Published public var autoDetectMangaLayout: Bool = true {
        didSet { save(autoDetectMangaLayout, key: Keys.autoDetectMangaLayout) }
    }
    @Published public var mangaLayoutOverrides: [String: ReaderLayoutMode] = [:] {
        didSet { save(mangaLayoutOverrides, key: Keys.mangaLayoutOverrides) }
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
    @Published public var readerTextureTintOpacity: Double = 1.0 {
        didSet { save(readerTextureTintOpacity, key: Keys.readerTextureTintOpacity) }
    }
    @Published public var readerClassicGrainDensity: Double = 1.0 {
        didSet { save(readerClassicGrainDensity, key: Keys.readerClassicGrainDensity) }
    }
    @Published public var readerTextureTarget: ReaderTextureTarget = .both {
        didSet { save(readerTextureTarget, key: Keys.readerTextureTarget) }
    }
    @Published public var readerImageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint {
        didSet { save(readerImageOnlyBackdrop, key: Keys.readerImageOnlyBackdrop) }
    }
    @Published public var showSpineDividingLine: Bool = true {
        didSet { save(showSpineDividingLine, key: Keys.spineDividingLine) }
    }
    @Published public var discoverPaginationMode: DiscoverPaginationMode = .pageByPage {
        didSet { save(discoverPaginationMode, key: Keys.discoverPaginationMode) }
    }
    @Published public var discoverLayoutStyle: DiscoverLayoutStyle = .classicGrid {
        didSet { save(discoverLayoutStyle, key: Keys.discoverLayoutStyle) }
    }
    @Published public var searchHistory: [String] = [] {
        didSet { save(searchHistory, key: Keys.searchHistory) }
    }
    @Published public var imageFilterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig() {
        didSet { save(imageFilterConfig, key: Keys.imageFilterConfig) }
    }
    @Published public var readerPreloadMode: ReaderPreloadMode = .standard {
        didSet { save(readerPreloadMode, key: Keys.readerPreloadMode) }
    }
    @Published public var enableUpscalerPreload: Bool = true {
        didSet { save(enableUpscalerPreload, key: Keys.enableUpscalerPreload) }
    }
    @Published public var preloadNextChapter: Bool = true {
        didSet { save(preloadNextChapter, key: Keys.preloadNextChapter) }
    }
    @Published public var appColorScheme: AppColorSchemePreference = .followSystem {
        didSet {
            save(appColorScheme, key: Keys.appColorScheme)
            applyWindowInterfaceStyle()
        }
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
        static let autoDetectMangaLayout = "keda_online_auto_detect_manga_layout_v1"
        static let mangaLayoutOverrides = "keda_online_manga_layout_overrides_v1"
        static let turningEffect = "keda_online_turning_effect_v1"
        static let soundEnabled = "keda_online_sound_enabled_v1"
        static let spineShadow = "keda_online_spine_shadow_v1"
        static let readerBackground = "keda_online_reader_background_v1"
        static let readerTextureType = "keda_online_reader_texture_type_v1"
        static let readerTextureOpacity = "keda_online_reader_texture_opacity_v1"
        static let readerTextureTintOpacity = "keda_online_reader_texture_tint_opacity_v1"
        static let readerClassicGrainDensity = "keda_online_reader_classic_grain_density_v1"
        static let readerTextureTarget = "keda_online_reader_texture_target_v1"
        static let readerImageOnlyBackdrop = "keda_online_reader_image_only_backdrop_v1"
        static let spineDividingLine = "keda_online_spine_dividing_line_v1"
        static let discoverPaginationMode = "keda_online_discover_pagination_mode_v1"
        static let discoverLayoutStyle = "keda_online_discover_layout_style_v1"
        static let searchHistory = "keda_online_search_history_v1"
        static let imageFilterConfig = "keda_online_image_filter_config_v1"
        static let readerPreloadMode = "keda_online_reader_preload_mode_v1"
        static let enableUpscalerPreload = "keda_online_enable_upscaler_preload_v1"
        static let preloadNextChapter = "keda_online_preload_next_chapter_v1"
        static let appColorScheme = "keda_online_app_color_scheme_v1"
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
        self.autoDetectMangaLayout = load(key: Keys.autoDetectMangaLayout) ?? true
        self.mangaLayoutOverrides = load(key: Keys.mangaLayoutOverrides) ?? [:]
        self.pageTurningEffect = load(key: Keys.turningEffect) ?? .curling
        self.pageTurnSoundEnabled = load(key: Keys.soundEnabled) ?? true
        self.showSpineShadowInCurl = load(key: Keys.spineShadow) ?? true
        self.preferredReaderBackground = load(key: Keys.readerBackground) ?? .followSystem
        self.readerTextureType = load(key: Keys.readerTextureType) ?? .classic
        self.readerTextureOpacity = load(key: Keys.readerTextureOpacity) ?? 0.4
        self.readerTextureTintOpacity = load(key: Keys.readerTextureTintOpacity) ?? 1.0
        self.readerClassicGrainDensity = load(key: Keys.readerClassicGrainDensity) ?? 1.0
        self.readerTextureTarget = load(key: Keys.readerTextureTarget) ?? .both
        self.readerImageOnlyBackdrop = load(key: Keys.readerImageOnlyBackdrop) ?? .paperTint
        self.showSpineDividingLine = load(key: Keys.spineDividingLine) ?? true
        self.discoverPaginationMode = load(key: Keys.discoverPaginationMode) ?? .pageByPage
        self.discoverLayoutStyle = load(key: Keys.discoverLayoutStyle) ?? .classicGrid
        self.searchHistory = load(key: Keys.searchHistory) ?? []
        self.imageFilterConfig = load(key: Keys.imageFilterConfig) ?? ImageFilterConfig.defaultConfig()
        self.readerPreloadMode = load(key: Keys.readerPreloadMode) ?? .standard
        self.enableUpscalerPreload = load(key: Keys.enableUpscalerPreload) ?? true
        self.preloadNextChapter = load(key: Keys.preloadNextChapter) ?? true
        self.appColorScheme = load(key: Keys.appColorScheme) ?? .followSystem
        applyWindowInterfaceStyle()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyWindowInterfaceStyle()
            }
        }
        #endif
    }

    /// 同步全局所有窗口的浅色 / 深色 / 跟随系统外观风格（覆盖弹窗、全屏阅读器与 UIKit 容器）
    public func applyWindowInterfaceStyle() {
        #if canImport(UIKit)
        let style = appColorScheme.userInterfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != style {
                window.overrideUserInterfaceStyle = style
            }
        }
        #endif
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

    public func updateProgress(
        manga: Manga,
        chapter: MangaChapter,
        pageIndex: Int,
        totalPages: Int? = nil,
        chapterIndex: Int? = nil,
        totalChapters: Int? = nil
    ) {
        let existing = progressMap[manga.compositeKey]
        let resolvedTotalPages: Int?
        if let totalPages, totalPages > 0 {
            resolvedTotalPages = totalPages
        } else if existing?.chapterID == chapter.id {
            resolvedTotalPages = existing?.totalPages
        } else {
            resolvedTotalPages = nil
        }

        progressMap[manga.compositeKey] = ReadingProgress(
            mangaKey: manga.compositeKey,
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            pageIndex: pageIndex,
            totalPages: resolvedTotalPages,
            chapterIndex: chapterIndex ?? existing?.chapterIndex,
            totalChapters: totalChapters ?? existing?.totalChapters,
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

    public func recordSearchHistory(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = searchHistory.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        updated.insert(trimmed, at: 0)
        if updated.count > 20 {
            updated = Array(updated.prefix(20))
        }
        searchHistory = updated
    }

    public func removeSearchHistory(_ query: String) {
        searchHistory.removeAll { $0 == query }
    }

    public func clearSearchHistory() {
        searchHistory = []
    }

    // MARK: - 漫画排版模式与智能匹配 (韩漫自动条漫 / 日漫自动日漫翻页)

    /// 获取特定漫画的排版模式（优先遵循单本漫画自定义，否则按智能规则推导韩漫条漫/日漫翻页，未识别回退全局默认）
    public func layoutMode(for manga: Manga) -> ReaderLayoutMode {
        if let custom = mangaLayoutOverrides[manga.compositeKey] {
            return custom
        }
        guard autoDetectMangaLayout else {
            return readerLayoutMode
        }
        let category = MangaLayoutDetector.detectCategory(for: manga)
        switch category {
        case .koreanWebtoon:
            return .verticalWebtoon
        case .japaneseManga:
            return .pagedRTL
        case .normal:
            return readerLayoutMode
        }
    }

    /// 设置特定漫画的排版模式覆盖（传 nil 则恢复跟随智能检测或全局默认）
    public func setLayoutMode(_ mode: ReaderLayoutMode?, for manga: Manga) {
        if let mode {
            mangaLayoutOverrides[manga.compositeKey] = mode
        } else {
            mangaLayoutOverrides.removeValue(forKey: manga.compositeKey)
        }
    }

    /// 获取特定漫画的用户单独自定义覆盖排版模式（若未单独自定义则返回 nil）
    public func customLayoutMode(for manga: Manga) -> ReaderLayoutMode? {
        mangaLayoutOverrides[manga.compositeKey]
    }

    /// 获取特定漫画的智能分类（韩漫 / 日漫 / 常规）
    public func detectedCategory(for manga: Manga) -> MangaLayoutCategory {
        MangaLayoutDetector.detectCategory(for: manga)
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
