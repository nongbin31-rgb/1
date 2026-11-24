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
    /// 阅读器通过实际正文图片高宽比实测识别的分类缓存（如确认长图为韩漫条漫，使详情页与下次打开保持一致）
    @Published public var autoDetectedCategories: [String: MangaLayoutCategory] = [:] {
        didSet { save(autoDetectedCategories, key: Keys.autoDetectedCategories) }
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
    @Published public var enableTapPageTurn: Bool = true {
        didSet { save(enableTapPageTurn, key: Keys.enableTapPageTurn) }
    }
    @Published public var invertTapPageTurn: Bool = false {
        didSet { save(invertTapPageTurn, key: Keys.invertTapPageTurn) }
    }
    @Published public var enableEdgeSwipeDismiss: Bool = true {
        didSet { save(enableEdgeSwipeDismiss, key: Keys.enableEdgeSwipeDismiss) }
    }
    @Published public var enableLandscapeDoublePage: Bool = true {
        didSet { save(enableLandscapeDoublePage, key: Keys.enableLandscapeDoublePage) }
    }
    @Published public var isolateCoverInDoublePage: Bool = true {
        didSet { save(isolateCoverInDoublePage, key: Keys.isolateCoverInDoublePage) }
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
    @Published public var readerProgressStyle: ReaderProgressStyle = .edgeDock {
        didSet { save(readerProgressStyle, key: Keys.readerProgressStyle) }
    }
    @Published public var showAmbientProgressInReader: Bool = true {
        didSet { save(showAmbientProgressInReader, key: Keys.showAmbientProgressInReader) }
    }
    /// 按日聚合的阅读统计（key: yyyy-MM-dd 本地日历日）
    @Published public var dailyReadingStats: [String: DailyReadingStat] = [:] {
        didSet { save(dailyReadingStats, key: Keys.dailyReadingStats) }
    }
    /// 阅读计时会话：上次有效阅读活动时间与上次计入的页标识（不持久化）
    private var lastReadingActivityAt: Date?
    private var lastRecordedPageToken: String?
    /// 两次活动间隔超过该阈值视为挂机离开，不计入阅读时长
    private let readingIdleThreshold: TimeInterval = 180
    @Published public var discoverPaginationMode: DiscoverPaginationMode = .pageByPage {
        didSet { save(discoverPaginationMode, key: Keys.discoverPaginationMode) }
    }
    @Published public var discoverLayoutStyle: DiscoverLayoutStyle = .classicGrid {
        didSet { save(discoverLayoutStyle, key: Keys.discoverLayoutStyle) }
    }
    @Published public var bookshelfLayoutStyle: BookshelfLayoutStyle = .focusShelf {
        didSet { save(bookshelfLayoutStyle, key: Keys.bookshelfLayoutStyle) }
    }
    @Published public var bookshelfSortOrder: BookshelfSortOrder = .recentRead {
        didSet { save(bookshelfSortOrder, key: Keys.bookshelfSortOrder) }
    }
    @Published public var bookshelfGeekMatrixShowTitles: Bool = true {
        didSet { save(bookshelfGeekMatrixShowTitles, key: Keys.bookshelfGeekMatrixShowTitles) }
    }
    @Published public var bookshelfAddedAt: [String: Date] = [:] {
        didSet { save(bookshelfAddedAt, key: Keys.bookshelfAddedAt) }
    }
    @Published public var bookshelfChapterMeta: [String: BookshelfChapterMeta] = [:] {
        didSet { save(bookshelfChapterMeta, key: Keys.bookshelfChapterMeta) }
    }
    @Published public var readingHistory: [ReadingHistoryItem] = [] {
        didSet { save(readingHistory, key: Keys.readingHistory) }
    }
    @Published public var pauseReadingHistory: Bool = false {
        didSet { save(pauseReadingHistory, key: Keys.pauseReadingHistory) }
    }
    @Published public var bookshelfGroups: [BookshelfGroup] = [] {
        didSet { save(bookshelfGroups, key: Keys.bookshelfGroups) }
    }
    @Published public var bookshelfGroupAssignments: [String: Set<String>] = [:] {
        didSet { save(bookshelfGroupAssignments, key: Keys.bookshelfGroupAssignments) }
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
        static let autoDetectedCategories = "keda_online_auto_detected_categories_v1"
        static let turningEffect = "keda_online_turning_effect_v1"
        static let soundEnabled = "keda_online_sound_enabled_v1"
        static let spineShadow = "keda_online_spine_shadow_v1"
        static let enableTapPageTurn = "keda_online_enable_tap_page_turn_v1"
        static let invertTapPageTurn = "keda_online_invert_tap_page_turn_v1"
        static let enableEdgeSwipeDismiss = "keda_online_enable_edge_swipe_dismiss_v1"
        static let enableLandscapeDoublePage = "keda_online_enable_landscape_double_page_v1"
        static let isolateCoverInDoublePage = "keda_online_isolate_cover_in_double_page_v1"
        static let readerBackground = "keda_online_reader_background_v1"
        static let readerTextureType = "keda_online_reader_texture_type_v1"
        static let readerTextureOpacity = "keda_online_reader_texture_opacity_v1"
        static let readerTextureTintOpacity = "keda_online_reader_texture_tint_opacity_v1"
        static let readerClassicGrainDensity = "keda_online_reader_classic_grain_density_v1"
        static let readerTextureTarget = "keda_online_reader_texture_target_v1"
        static let readerImageOnlyBackdrop = "keda_online_reader_image_only_backdrop_v1"
        static let spineDividingLine = "keda_online_spine_dividing_line_v1"
        static let readerProgressStyle = "keda_online_reader_progress_style_v1"
        static let showAmbientProgressInReader = "keda_online_show_ambient_progress_v1"
        static let dailyReadingStats = "keda_online_daily_reading_stats_v1"
        static let discoverPaginationMode = "keda_online_discover_pagination_mode_v1"
        static let discoverLayoutStyle = "keda_online_discover_layout_style_v1"
        static let bookshelfLayoutStyle = "keda_online_bookshelf_layout_style_v1"
        static let bookshelfSortOrder = "keda_online_bookshelf_sort_order_v1"
        static let bookshelfGeekMatrixShowTitles = "keda_online_bookshelf_matrix_titles_v1"
        static let bookshelfAddedAt = "keda_online_bookshelf_added_at_v1"
        static let bookshelfChapterMeta = "keda_online_bookshelf_chapter_meta_v1"
        static let lastAutoBookshelfUpdateCheckAt = "keda_online_last_auto_bookshelf_update_at_v1"
        static let readingHistory = "keda_online_reading_history_v1"
        static let pauseReadingHistory = "keda_online_pause_reading_history_v1"
        static let bookshelfGroups = "keda_online_bookshelf_groups_v1"
        static let bookshelfGroupAssignments = "keda_online_bookshelf_group_assignments_v1"
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
            for i in existing.indices {
                if existing[i].id == "builtin-jm-source" && (existing[i].name == "漫画源 J" || existing[i].name.isEmpty) {
                    existing[i].name = "禁漫天堂"
                } else if existing[i].id == "builtin-wnacg-source" && (existing[i].name == "漫画源 W" || existing[i].name.isEmpty) {
                    existing[i].name = "绅士漫画"
                }
            }
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
        self.autoDetectedCategories = load(key: Keys.autoDetectedCategories) ?? [:]
        self.pageTurningEffect = load(key: Keys.turningEffect) ?? .curling
        self.pageTurnSoundEnabled = load(key: Keys.soundEnabled) ?? true
        self.showSpineShadowInCurl = load(key: Keys.spineShadow) ?? true
        self.enableTapPageTurn = load(key: Keys.enableTapPageTurn) ?? true
        self.invertTapPageTurn = load(key: Keys.invertTapPageTurn) ?? false
        self.enableEdgeSwipeDismiss = load(key: Keys.enableEdgeSwipeDismiss) ?? true
        self.enableLandscapeDoublePage = load(key: Keys.enableLandscapeDoublePage) ?? true
        self.isolateCoverInDoublePage = load(key: Keys.isolateCoverInDoublePage) ?? true
        self.preferredReaderBackground = load(key: Keys.readerBackground) ?? .followSystem
        self.readerTextureType = load(key: Keys.readerTextureType) ?? .classic
        self.readerTextureOpacity = load(key: Keys.readerTextureOpacity) ?? 0.4
        self.readerTextureTintOpacity = load(key: Keys.readerTextureTintOpacity) ?? 1.0
        self.readerClassicGrainDensity = load(key: Keys.readerClassicGrainDensity) ?? 1.0
        self.readerTextureTarget = load(key: Keys.readerTextureTarget) ?? .both
        self.readerImageOnlyBackdrop = load(key: Keys.readerImageOnlyBackdrop) ?? .paperTint
        self.showSpineDividingLine = load(key: Keys.spineDividingLine) ?? true
        self.readerProgressStyle = load(key: Keys.readerProgressStyle) ?? .edgeDock
        self.showAmbientProgressInReader = load(key: Keys.showAmbientProgressInReader) ?? true
        self.dailyReadingStats = load(key: Keys.dailyReadingStats) ?? [:]
        self.discoverPaginationMode = load(key: Keys.discoverPaginationMode) ?? .pageByPage
        self.discoverLayoutStyle = load(key: Keys.discoverLayoutStyle) ?? .classicGrid
        self.bookshelfLayoutStyle = load(key: Keys.bookshelfLayoutStyle) ?? .focusShelf
        self.bookshelfSortOrder = load(key: Keys.bookshelfSortOrder) ?? .recentRead
        self.bookshelfGeekMatrixShowTitles = load(key: Keys.bookshelfGeekMatrixShowTitles) ?? true
        self.bookshelfAddedAt = load(key: Keys.bookshelfAddedAt) ?? [:]
        self.bookshelfChapterMeta = load(key: Keys.bookshelfChapterMeta) ?? [:]
        self.readingHistory = load(key: Keys.readingHistory) ?? []
        self.pauseReadingHistory = load(key: Keys.pauseReadingHistory) ?? false
        self.bookshelfGroups = load(key: Keys.bookshelfGroups) ?? []
        self.bookshelfGroupAssignments = load(key: Keys.bookshelfGroupAssignments) ?? [:]
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
        if sourceID == LocalMangaSource.sourceID {
            return LocalMangaSource()
        }
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
        case .local:
            return LocalMangaSource(config: config)
        }
    }

    public struct BookshelfRemovedItem: Sendable {
        public let manga: Manga
        public let originalIndex: Int
        public let addedAt: Date?
        public let groupIDs: Set<String>

        public init(
            manga: Manga,
            originalIndex: Int,
            addedAt: Date?,
            groupIDs: Set<String> = []
        ) {
            self.manga = manga
            self.originalIndex = originalIndex
            self.addedAt = addedAt
            self.groupIDs = groupIDs
        }
    }

    public func isInBookshelf(_ manga: Manga) -> Bool {
        bookshelf.contains(where: { $0.compositeKey == manga.compositeKey })
    }

    public func bookshelfAddedDate(for manga: Manga) -> Date? {
        bookshelfAddedAt[manga.compositeKey]
    }

    public func toggleBookshelf(_ manga: Manga) {
        if let idx = bookshelf.firstIndex(where: { $0.compositeKey == manga.compositeKey }) {
            bookshelf.remove(at: idx)
            bookshelfAddedAt.removeValue(forKey: manga.compositeKey)
        } else {
            bookshelf.insert(manga, at: 0)
            bookshelfAddedAt[manga.compositeKey] = Date()
        }
    }

    /// 批量移出书架并返回用于撤销恢复的快照
    @discardableResult
    public func removeFromBookshelf(keys: Set<String>) -> [BookshelfRemovedItem] {
        guard !keys.isEmpty else { return [] }
        var removed: [BookshelfRemovedItem] = []
        var remaining: [Manga] = []
        var updatedAddedAt = bookshelfAddedAt
        var updatedAssignments = bookshelfGroupAssignments

        for (index, manga) in bookshelf.enumerated() {
            if keys.contains(manga.compositeKey) {
                let removedGroups = updatedAssignments.removeValue(forKey: manga.compositeKey) ?? []
                removed.append(
                    BookshelfRemovedItem(
                        manga: manga,
                        originalIndex: index,
                        addedAt: updatedAddedAt.removeValue(forKey: manga.compositeKey),
                        groupIDs: removedGroups
                    )
                )
            } else {
                remaining.append(manga)
            }
        }

        guard !removed.isEmpty else { return [] }
        bookshelf = remaining
        bookshelfAddedAt = updatedAddedAt
        bookshelfGroupAssignments = updatedAssignments
        return removed
    }

    /// 按原始顺序撤销恢复已移出的书架条目
    public func restoreToBookshelf(_ items: [BookshelfRemovedItem]) {
        guard !items.isEmpty else { return }
        var updatedShelf = bookshelf
        var updatedAddedAt = bookshelfAddedAt
        var updatedAssignments = bookshelfGroupAssignments
        let validGroupIDs = Set(bookshelfGroups.map(\.id))

        for item in items.sorted(by: { $0.originalIndex < $1.originalIndex }) {
            guard !updatedShelf.contains(where: { $0.compositeKey == item.manga.compositeKey }) else {
                continue
            }
            let targetIndex = min(max(0, item.originalIndex), updatedShelf.count)
            updatedShelf.insert(item.manga, at: targetIndex)
            if let addedAt = item.addedAt {
                updatedAddedAt[item.manga.compositeKey] = addedAt
            }
            let restoredGroups = item.groupIDs.intersection(validGroupIDs)
            if !restoredGroups.isEmpty {
                updatedAssignments[item.manga.compositeKey] = restoredGroups
            }
        }

        bookshelf = updatedShelf
        bookshelfAddedAt = updatedAddedAt
        bookshelfGroupAssignments = updatedAssignments
    }

    // MARK: - 自定义书架分组管理（支持一本漫画多分组）

    @discardableResult
    public func createBookshelfGroup(name: String, iconName: String = "folder.fill") -> BookshelfGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = BookshelfGroup(name: trimmed, iconName: iconName)
        bookshelfGroups.append(group)
        return group
    }

    public func renameBookshelfGroup(id: String, name: String, iconName: String? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = bookshelfGroups.firstIndex(where: { $0.id == id }) else {
            return
        }
        bookshelfGroups[idx].name = trimmed
        if let iconName, !iconName.isEmpty {
            bookshelfGroups[idx].iconName = iconName
        }
    }

    /// 删除分组（仅解除分组关联，绝不删除书架中的漫画）
    public func deleteBookshelfGroup(id: String) {
        bookshelfGroups.removeAll { $0.id == id }
        var updated = bookshelfGroupAssignments
        for (key, var set) in updated {
            if set.remove(id) != nil {
                if set.isEmpty {
                    updated.removeValue(forKey: key)
                } else {
                    updated[key] = set
                }
            }
        }
        bookshelfGroupAssignments = updated
    }

    public func moveBookshelfGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        bookshelfGroups.move(fromOffsets: source, toOffset: destination)
    }

    public func groupIDs(for manga: Manga) -> Set<String> {
        let valid = Set(bookshelfGroups.map(\.id))
        return (bookshelfGroupAssignments[manga.compositeKey] ?? []).intersection(valid)
    }

    public func setGroups(_ groupIDs: Set<String>, for manga: Manga) {
        let valid = groupIDs.intersection(Set(bookshelfGroups.map(\.id)))
        var updated = bookshelfGroupAssignments
        if valid.isEmpty {
            updated.removeValue(forKey: manga.compositeKey)
        } else {
            updated[manga.compositeKey] = valid
        }
        bookshelfGroupAssignments = updated
    }

    public func addMangas(_ mangas: [Manga], toGroups groupIDs: Set<String>) {
        let valid = groupIDs.intersection(Set(bookshelfGroups.map(\.id)))
        guard !mangas.isEmpty, !valid.isEmpty else { return }
        var updated = bookshelfGroupAssignments
        for manga in mangas {
            var current = updated[manga.compositeKey] ?? []
            current.formUnion(valid)
            updated[manga.compositeKey] = current
        }
        bookshelfGroupAssignments = updated
    }

    public func removeMangas(_ mangas: [Manga], fromGroup groupID: String) {
        guard !mangas.isEmpty else { return }
        var updated = bookshelfGroupAssignments
        for manga in mangas {
            guard var current = updated[manga.compositeKey] else { continue }
            current.remove(groupID)
            if current.isEmpty {
                updated.removeValue(forKey: manga.compositeKey)
            } else {
                updated[manga.compositeKey] = current
            }
        }
        bookshelfGroupAssignments = updated
    }

    /// 批量将漫画标记为已读完（已有章节进度时保留真实页数并置为 100%，未读过时写入显式手动已读标记）
    public func markAsCompleted(_ mangas: [Manga]) {
        guard !mangas.isEmpty else { return }
        var updated = progressMap
        let now = Date()

        for manga in mangas {
            let key = manga.compositeKey
            let existing = updated[key]
            if let existing, let totalPages = existing.totalPages, totalPages > 0 {
                let finalChapterIndex = existing.totalChapters.map { max(0, $0 - 1) } ?? existing.chapterIndex
                updated[key] = ReadingProgress(
                    mangaKey: key,
                    chapterID: existing.chapterID,
                    chapterTitle: existing.chapterTitle,
                    pageIndex: max(0, totalPages - 1),
                    totalPages: totalPages,
                    chapterIndex: finalChapterIndex,
                    totalChapters: existing.totalChapters,
                    updatedAt: now
                )
            } else {
                updated[key] = ReadingProgress(
                    mangaKey: key,
                    chapterID: "",
                    chapterTitle: "已读完",
                    pageIndex: 0,
                    totalPages: 1,
                    chapterIndex: nil,
                    totalChapters: existing?.totalChapters,
                    updatedAt: now
                )
            }
        }

        progressMap = updated
    }

    /// 批量重置指定漫画的阅读进度
    public func resetProgress(for mangas: [Manga]) {
        guard !mangas.isEmpty else { return }
        var updated = progressMap
        var changed = false
        for manga in mangas {
            if updated.removeValue(forKey: manga.compositeKey) != nil {
                changed = true
            }
        }
        if changed {
            progressMap = updated
        }
    }

    /// 当详情页或一键续读拉取到更完整的漫画元数据时，静默刷新书架中对应条目
    public func updateBookshelfManga(_ manga: Manga) {
        guard let idx = bookshelf.firstIndex(where: { $0.compositeKey == manga.compositeKey }) else {
            return
        }
        if bookshelf[idx] != manga {
            bookshelf[idx] = manga
        }
    }

    public func chapterMeta(for manga: Manga) -> BookshelfChapterMeta? {
        bookshelfChapterMeta[manga.compositeKey]
    }

    /// 同步书架漫画最新章节快照；仅对已在书架中的漫画生效，返回是否检测到新增章节
    @discardableResult
    public func syncBookshelfChapterMeta(
        manga: Manga,
        chapters: [MangaChapter],
        markUnreadIfIncreased: Bool = false
    ) -> Bool {
        guard isInBookshelf(manga), !chapters.isEmpty else {
            return false
        }
        updateBookshelfManga(manga)

        let key = manga.compositeKey
        let previous = bookshelfChapterMeta[key]
        let updated = MangaSerialStatusHelper.buildBookshelfChapterMeta(
            manga: manga,
            chapters: chapters,
            previousMeta: previous,
            markUnreadIfIncreased: markUnreadIfIncreased
        )
        let didIncrease = (previous != nil && previous!.chapterCount > 0 && updated.chapterCount > previous!.chapterCount)
        bookshelfChapterMeta[key] = updated
        reconcileReadingProgress(
            for: key,
            chapters: chapters,
            previousChapterCount: previous?.chapterCount,
            didIncrease: didIncrease
        )
        return didIncrease
    }

    /// 章节列表更新时同步校准已有阅读进度的总话数与章节序数，避免连载更新后依然停留在「已读完 100%」
    private func reconcileReadingProgress(
        for key: String,
        chapters: [MangaChapter],
        previousChapterCount: Int?,
        didIncrease: Bool
    ) {
        guard !chapters.isEmpty, let existing = progressMap[key] else { return }

        if existing.isManuallyMarkedCompleted {
            guard didIncrease else { return }
            let completedIndex = max(0, min(chapters.count - 2, (previousChapterCount ?? 1) - 1))
            progressMap[key] = ReadingProgress(
                mangaKey: existing.mangaKey,
                chapterID: existing.chapterID,
                chapterTitle: existing.chapterTitle,
                pageIndex: existing.pageIndex,
                totalPages: existing.totalPages,
                chapterIndex: completedIndex,
                totalChapters: chapters.count,
                updatedAt: existing.updatedAt
            )
            return
        }

        let matchedIndex = chapters.firstIndex(where: { $0.id == existing.chapterID }) ?? existing.chapterIndex
        guard existing.totalChapters != chapters.count || existing.chapterIndex != matchedIndex else {
            return
        }

        progressMap[key] = ReadingProgress(
            mangaKey: existing.mangaKey,
            chapterID: existing.chapterID,
            chapterTitle: existing.chapterTitle,
            pageIndex: existing.pageIndex,
            totalPages: existing.totalPages,
            chapterIndex: matchedIndex,
            totalChapters: chapters.count,
            updatedAt: existing.updatedAt
        )
    }

    /// 根据当前阅读进度解析续读目标：若上次已读到某话最后一页且后面有更新章节，则自动定位到下一话第 1 页
    public func resolveResumeTarget(
        for manga: Manga,
        fallbackManga: Manga? = nil,
        chapters: [MangaChapter],
        allowRestartWhenCompleted: Bool = true
    ) -> (chapter: MangaChapter, pageIndex: Int)? {
        guard let firstChapter = chapters.first else { return nil }
        let currentProgress = progress(for: manga) ?? fallbackManga.flatMap { progress(for: $0) }

        guard let currentProgress else {
            return (firstChapter, 0)
        }
        if allowRestartWhenCompleted && currentProgress.isCompleted {
            return (firstChapter, 0)
        }
        guard let matchIndex = chapters.firstIndex(where: { $0.id == currentProgress.chapterID }) else {
            return (firstChapter, 0)
        }

        let finishedCurrentChapter: Bool
        if let totalPages = currentProgress.totalPages, totalPages > 0 {
            finishedCurrentChapter = currentProgress.pageIndex >= totalPages - 1
        } else {
            finishedCurrentChapter = false
        }

        if finishedCurrentChapter, matchIndex + 1 < chapters.count {
            return (chapters[matchIndex + 1], 0)
        }
        return (chapters[matchIndex], max(0, currentProgress.pageIndex))
    }

    /// 是否到达定时静默追更冷却时间（默认 6 小时）
    public func shouldRunAutoBookshelfUpdateCheck(minInterval: TimeInterval = 6 * 3600) -> Bool {
        guard let lastDate = UserDefaults.standard.object(forKey: Keys.lastAutoBookshelfUpdateCheckAt) as? Date else {
            return true
        }
        return Date().timeIntervalSince(lastDate) >= minInterval
    }

    /// 记录最近一次自动/手动书架追更时间
    public func markAutoBookshelfUpdateChecked() {
        UserDefaults.standard.set(Date(), forKey: Keys.lastAutoBookshelfUpdateCheckAt)
    }

    /// 清除书架漫画的新章节红点提示
    public func clearUnreadUpdateFlag(for manga: Manga) {
        let key = manga.compositeKey
        guard var meta = bookshelfChapterMeta[key], meta.hasUnreadUpdate else { return }
        meta.hasUnreadUpdate = false
        bookshelfChapterMeta[key] = meta
    }

    /// 获取书架卡片应展示的话数角标信息（单话作品返回 nil；未同步过时降级读取进度中的 totalChapters）
    public func resolvedBookshelfChapterBadge(for manga: Manga) -> BookshelfChapterBadgeInfo? {
        if let meta = bookshelfChapterMeta[manga.compositeKey] {
            guard !meta.badgeText.isEmpty else { return nil }
            return BookshelfChapterBadgeInfo(
                text: meta.badgeText,
                compactText: meta.compactBadgeText,
                isOngoing: meta.isOngoing,
                hasUnreadUpdate: meta.hasUnreadUpdate
            )
        }
        return MangaSerialStatusHelper.fallbackBookshelfBadge(
            manga: manga,
            progress: progress(for: manga)
        )
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

        recordReadingActivity(pageToken: "\(manga.compositeKey)#\(chapter.id)#\(pageIndex)")
        recordHistoryRead(
            manga: manga,
            chapter: chapter,
            pageIndex: pageIndex,
            totalPages: resolvedTotalPages
        )
    }

    public func progress(for manga: Manga) -> ReadingProgress? {
        progressMap[manga.compositeKey]
    }

    // MARK: - 浏览足迹（完整阅读历史）

    private static let maxReadingHistoryCount = 200

    public func sourceName(for sourceID: String) -> String {
        if sourceID == LocalMangaSource.sourceID {
            return "本地漫画"
        }
        return sources.first(where: { $0.id == sourceID })?.name ?? "在线源"
    }

    /// 统一导入本地 CBZ / ZIP / PDF 漫画，并自动加入书架与同步章节快照
    @discardableResult
    public func importLocalMangaFiles(urls: [URL]) async -> (imported: [Manga], failedNames: [String]) {
        let result = await LocalMangaLibraryManager.shared.importFiles(from: urls)
        for manga in result.imported {
            if !isInBookshelf(manga) {
                bookshelf.insert(manga, at: 0)
                bookshelfAddedAt[manga.compositeKey] = Date()
            }
            if let record = LocalMangaLibraryManager.shared.recordSnapshot(for: manga.id) {
                let chapters = record.chapters.map {
                    MangaChapter(id: $0.id, mangaID: record.id, title: $0.title, number: $0.number)
                }
                syncBookshelfChapterMeta(manga: manga, chapters: chapters, markUnreadIfIncreased: false)
            }
        }
        return result
    }

    /// 记录浏览漫画详情（同本自动去重置顶并保留已有阅读章节页码）
    public func recordHistoryView(manga: Manga) {
        guard !pauseReadingHistory else { return }
        let key = manga.compositeKey
        let existing = readingHistory.first(where: { $0.id == key })
        let progressFallback = progressMap[key]

        let entry = ReadingHistoryItem(
            manga: manga,
            viewedAt: Date(),
            lastChapterID: existing?.lastChapterID ?? progressFallback?.chapterID,
            lastChapterTitle: existing?.lastChapterTitle ?? progressFallback?.chapterTitle,
            lastPageIndex: existing?.lastPageIndex ?? progressFallback?.pageIndex,
            lastTotalPages: existing?.lastTotalPages ?? progressFallback?.totalPages
        )
        upsertReadingHistory(entry)
    }

    /// 记录实际阅读章节与页码（由阅读器进度更新自动联动触发）
    public func recordHistoryRead(
        manga: Manga,
        chapter: MangaChapter,
        pageIndex: Int,
        totalPages: Int?
    ) {
        guard !pauseReadingHistory else { return }
        let entry = ReadingHistoryItem(
            manga: manga,
            viewedAt: Date(),
            lastChapterID: chapter.id,
            lastChapterTitle: chapter.title,
            lastPageIndex: pageIndex,
            lastTotalPages: totalPages
        )
        upsertReadingHistory(entry)
    }

    public func removeHistory(key: String) {
        readingHistory.removeAll { $0.id == key }
    }

    public func clearAllHistory() {
        readingHistory.removeAll()
    }

    private func upsertReadingHistory(_ entry: ReadingHistoryItem) {
        var updated = readingHistory
        updated.removeAll { $0.id == entry.id }
        updated.insert(entry, at: 0)
        if updated.count > Self.maxReadingHistoryCount {
            updated = Array(updated.prefix(Self.maxReadingHistoryCount))
        }
        readingHistory = updated
    }

    // MARK: - 阅读统计（时长 / 翻页 / 连续打卡）

    private static let readingStatsDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var readingStatsCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        calendar.firstWeekday = 2 // 周一为一周起点
        return calendar
    }

    private func readingStatsDayKey(for date: Date) -> String {
        Self.readingStatsDayFormatter.timeZone = TimeZone.current
        return Self.readingStatsDayFormatter.string(from: date)
    }

    /// 阅读器进入前台 / 打开时开启计时会话
    public func beginReadingSession() {
        lastReadingActivityAt = Date()
    }

    /// 阅读器关闭 / 退到后台时结算最后一段阅读时长
    public func endReadingSession() {
        accumulateReadingTime(until: Date(), addingPages: 0)
        lastReadingActivityAt = nil
        lastRecordedPageToken = nil
    }

    /// 记录一次阅读活动：累计与上次活动的间隔时长（超过挂机阈值不计），页标识变化时计 1 页
    private func recordReadingActivity(pageToken: String) {
        let isNewPage = pageToken != lastRecordedPageToken
        accumulateReadingTime(until: Date(), addingPages: isNewPage ? 1 : 0)
        lastRecordedPageToken = pageToken
    }

    private func accumulateReadingTime(until now: Date, addingPages pages: Int) {
        var delta: TimeInterval = 0
        if let last = lastReadingActivityAt {
            let gap = now.timeIntervalSince(last)
            if gap > 0 && gap <= readingIdleThreshold {
                delta = gap
            }
        }
        lastReadingActivityAt = now
        guard delta > 0 || pages > 0 else { return }

        let calendar = Self.readingStatsCalendar
        var updated = dailyReadingStats
        if delta > 0 {
            let last = now.addingTimeInterval(-delta)
            if !calendar.isDate(last, inSameDayAs: now) {
                // 跨零点：按零点切分到前后两天
                let midnight = calendar.startOfDay(for: now)
                let beforeMidnight = max(0, midnight.timeIntervalSince(last))
                let prevKey = readingStatsDayKey(for: last)
                updated[prevKey, default: DailyReadingStat()].seconds += beforeMidnight
                delta = max(0, delta - beforeMidnight)
            }
        }
        let key = readingStatsDayKey(for: now)
        var stat = updated[key] ?? DailyReadingStat()
        stat.seconds += delta
        stat.pages += pages
        updated[key] = stat

        // 仅保留近 400 天，防止 UserDefaults 无限膨胀
        if updated.count > 400,
           let cutoff = calendar.date(byAdding: .day, value: -400, to: now) {
            let cutoffKey = readingStatsDayKey(for: cutoff)
            updated = updated.filter { $0.key >= cutoffKey }
        }
        dailyReadingStats = updated
    }

    /// 汇总阅读统计：本周（周一起）时长与页数、连续打卡天数、累计数据与近 7 日趋势
    public func readingStatsSummary(now: Date = Date()) -> ReadingStatsSummary {
        let calendar = Self.readingStatsCalendar
        let stats = dailyReadingStats
        let today = calendar.startOfDay(for: now)

        var weekSeconds: Double = 0
        var weekPages = 0
        if let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
            var cursor = calendar.startOfDay(for: weekStart)
            while cursor <= today {
                if let stat = stats[readingStatsDayKey(for: cursor)] {
                    weekSeconds += stat.seconds
                    weekPages += stat.pages
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        // 连续打卡：今天未读时从昨天起算，不中断连胜
        var streak = 0
        var cursor = today
        if stats[readingStatsDayKey(for: today)]?.isActiveDay != true {
            cursor = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        }
        while stats[readingStatsDayKey(for: cursor)]?.isActiveDay == true {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }

        let totalSeconds = stats.values.reduce(0) { $0 + $1.seconds }
        let totalPages = stats.values.reduce(0) { $0 + $1.pages }

        let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
        var recent: [ReadingStatsDayPoint] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = readingStatsDayKey(for: day)
            let stat = stats[key] ?? DailyReadingStat()
            let weekday = calendar.component(.weekday, from: day)
            recent.append(
                ReadingStatsDayPoint(
                    id: key,
                    label: offset == 0 ? "今" : weekdaySymbols[(weekday - 1) % 7],
                    seconds: stat.seconds,
                    pages: stat.pages,
                    isToday: offset == 0
                )
            )
        }

        return ReadingStatsSummary(
            weekSeconds: weekSeconds,
            weekPages: weekPages,
            streakDays: streak,
            totalSeconds: totalSeconds,
            totalPages: totalPages,
            recentDays: recent
        )
    }

    /// 清空全部阅读统计
    public func resetReadingStats() {
        dailyReadingStats = [:]
        lastReadingActivityAt = nil
        lastRecordedPageToken = nil
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
        let category = detectedCategory(for: manga)
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

    /// 记录阅读器通过实际正文图片尺寸识别出的漫画分类（与详情页同步）
    public func recordAutoDetectedCategory(_ category: MangaLayoutCategory, for manga: Manga) {
        let key = manga.compositeKey
        if autoDetectedCategories[key] != category {
            autoDetectedCategories[key] = category
        }
    }

    /// 获取特定漫画的智能分类（优先采用阅读器实测图片尺寸结果，否则按标题/标签静态推断）
    public func detectedCategory(for manga: Manga) -> MangaLayoutCategory {
        if let measured = autoDetectedCategories[manga.compositeKey] {
            return measured
        }
        return MangaLayoutDetector.detectCategory(for: manga)
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
