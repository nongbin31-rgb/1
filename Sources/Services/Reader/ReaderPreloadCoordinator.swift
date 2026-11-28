import Foundation
import SwiftUI
import UIKit

/// 非隔离的通知观察者令牌，确保 deinit 自动反注册而无 Swift 并发隔离冲突
private final class MemoryWarningObserverToken {
    private let tokens: [NSObjectProtocol]

    init(
        onWarning: @escaping @Sendable () -> Void,
        onBackground: @escaping @Sendable () -> Void
    ) {
        let nc = NotificationCenter.default
        let t1 = nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            onWarning()
        }
        let t2 = nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            onBackground()
        }
        let t3 = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            onBackground()
        }
        self.tokens = [t1, t2, t3]
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

/// 在线漫画阅读器统一三级预载入调度中心
/// - L1（原图预载）：围绕当前页维护滑动窗口（向后 N 页 + 向前 M 页），并发受限 ≤ 2，防抖并自动取消窗口外任务
/// - L2（超分与滤镜预热）：仅在当前页就绪且设备电量/温控/内存健康时，在后台串行预热下一页（i+1）
/// - L3（章末衔接预取）：阅读至当前章节最后 2 页时，静默预取下一话页面列表及前 2 页原图
@MainActor
public final class ReaderPreloadCoordinator: ObservableObject {
    private let debounceNanoseconds: UInt64 = 120_000_000 // 120ms 滑动防抖
    private let memoryWarningCooldownSeconds: TimeInterval = 30
    private let maxPrefetchedChapters = 3

    // MARK: - 章节上下文
    private var chapterID: String = ""
    private var pages: [MangaPage] = []
    private var chapters: [MangaChapter] = []
    private var currentChapterIndex: Int?
    private var sourceID: String = ""
    private var adapterProvider: ((String) -> (any MangaSourceProtocol)?)?

    // MARK: - 用户策略配置
    private var preloadMode: ReaderPreloadMode = .standard
    private var enableUpscaler: Bool = false
    private var enableUpscalerPreload: Bool = true
    private var upscalerConfig: ImageUpscalerConfig = ImageUpscalerConfig()
    private var filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    private var preloadNextChapterEnabled: Bool = true

    // MARK: - 调度运行态
    private var currentPageIndex: Int = 0
    private var readyPageIDs: Set<String> = []
    private var debounceTask: Task<Void, Never>?

    private var l1ActiveTasks: [String: Task<Void, Never>] = [:]
    private var l1PendingQueue: [MangaPage] = []

    private var l2Task: Task<Void, Never>?
    private var l2TargetPageID: String?
    private var l2TargetKey: String?

    private var l3Task: Task<Void, Never>?
    private var l3TargetChapterID: String?
    private var prefetchedChapterPages: [String: [MangaPage]] = [:]
    private var prefetchedChapterOrder: [String] = []

    // MARK: - 系统保护状态
    private var memoryWarningCooldownUntil: Date?
    private var memoryWarningToken: MemoryWarningObserverToken?

    public init() {
        self.memoryWarningToken = MemoryWarningObserverToken(
            onWarning: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleMemoryWarning()
                }
            },
            onBackground: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.cancelL2Task()
                }
            }
        )
    }

    // MARK: - 外部驱动接口

    /// 更新当前章节与页面列表上下文
    public func updateContext(
        chapterID: String,
        pages: [MangaPage],
        chapters: [MangaChapter],
        currentChapterIndex: Int?,
        sourceID: String,
        adapterProvider: @escaping (String) -> (any MangaSourceProtocol)?
    ) {
        let chapterChanged = (self.chapterID != chapterID)
        self.chapterID = chapterID
        self.pages = pages
        self.chapters = chapters
        self.currentChapterIndex = currentChapterIndex
        self.sourceID = sourceID
        self.adapterProvider = adapterProvider

        if chapterChanged {
            cancelL1AndL2Tasks()
            if l3TargetChapterID != chapterID {
                cancelL3Task()
            }
            readyPageIDs.removeAll()
        }

        if !pages.isEmpty {
            scheduleAfterDebounce(immediate: true)
        }
    }

    /// 同步预载入与画质/滤镜设置变更
    public func updateSettings(
        preloadMode: ReaderPreloadMode,
        enableUpscaler: Bool,
        enableUpscalerPreload: Bool,
        upscalerConfig: ImageUpscalerConfig,
        filterConfig: ImageFilterConfig,
        preloadNextChapter: Bool
    ) {
        let modeChanged = (self.preloadMode != preloadMode)
        let l2ConfigChanged = (self.enableUpscaler != enableUpscaler)
            || (self.enableUpscalerPreload != enableUpscalerPreload)
            || (self.upscalerConfig != upscalerConfig)
            || (self.filterConfig != filterConfig)
        let l3Changed = (self.preloadNextChapterEnabled != preloadNextChapter)

        self.preloadMode = preloadMode
        self.enableUpscaler = enableUpscaler
        self.enableUpscalerPreload = enableUpscalerPreload
        self.upscalerConfig = upscalerConfig
        self.filterConfig = filterConfig
        self.preloadNextChapterEnabled = preloadNextChapter

        guard preloadMode.isEnabled else {
            cancelAll()
            return
        }

        if l2ConfigChanged {
            cancelL2Task()
            readyPageIDs.removeAll()
        }

        if l3Changed && !preloadNextChapter {
            cancelL3Task()
        }

        if (modeChanged || l2ConfigChanged || l3Changed), !pages.isEmpty {
            scheduleAfterDebounce(immediate: false)
        }
    }

    /// 页码变化时驱动滑动窗口与优先级抢占
    public func updateCurrentPage(_ index: Int) {
        currentPageIndex = index

        guard preloadMode.isEnabled, !pages.isEmpty else {
            cancelL1AndL2Tasks()
            return
        }

        // 1. 立即裁剪已偏离新窗口的 L1 预载任务
        pruneOutOfWindowL1Tasks()

        // 2. 检查正在进行的 L2 任务：
        //    - 若正好是用户刚翻到的当前页，暂不取消，让前台 Slot 无缝承接 PageUpscalerPipeline 的 in-flight 进度；
        //    - 若正好是新的下一页，保留继续跑；
        //    - 若用户跨页跳走，立即取消释放 Waifu2x / Anime4K 串行队列
        if let activeL2PageID = l2TargetPageID {
            let currentID = pages.indices.contains(index) ? pages[index].id : nil
            let nextID = pages.indices.contains(index + 1) ? pages[index + 1].id : nil
            if activeL2PageID != currentID && activeL2PageID != nextID {
                cancelL2Task()
            }
        }

        scheduleAfterDebounce(immediate: false)
    }

    /// 通知某页的前台加载（含当前配置下的超分与滤镜）已彻底就绪
    public func markPageReady(pageID: String, index: Int) {
        readyPageIDs.insert(pageID)
        guard preloadMode.isEnabled, index == currentPageIndex else { return }

        // 当前页就绪后，放开 L1 并发槽位（1 -> 2）并立即尝试启动 L2 下一页预热
        pumpL1Queue()
        scheduleL2IfEligible()
    }

    /// 若 L3 已预取下一话页面列表，切换章节时直接瞬时取出免去网络等待
    public func consumePrefetchedPages(for chapterID: String) -> [MangaPage]? {
        guard let cached = prefetchedChapterPages.removeValue(forKey: chapterID) else {
            return nil
        }
        prefetchedChapterOrder.removeAll { $0 == chapterID }
        return cached
    }

    /// 退出阅读器或关闭预载时清理全部后台任务
    public func cancelAll() {
        debounceTask?.cancel()
        debounceTask = nil
        cancelL1AndL2Tasks()
        cancelL3Task()
    }

    // MARK: - 内部调度管线

    private func scheduleAfterDebounce(immediate: Bool) {
        debounceTask?.cancel()
        guard preloadMode.isEnabled, !pages.isEmpty else { return }

        if immediate {
            executeScheduleCycle()
            return
        }

        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: self?.debounceNanoseconds ?? 120_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.executeScheduleCycle()
        }
    }

    private func executeScheduleCycle() {
        guard preloadMode.isEnabled, !pages.isEmpty else { return }
        scheduleL1Window()
        scheduleL2IfEligible()
        scheduleL3IfEligible()
    }

    // MARK: - L1：原图预下载与反混淆

    private func computeL1WindowPages() -> [MangaPage] {
        guard !pages.isEmpty, preloadMode.isEnabled else { return [] }
        let clampedCurrent = min(max(0, currentPageIndex), pages.count - 1)
        var orderedIndices: [Int] = []

        // 优先向后预载（顺读方向）
        if preloadMode.aheadCount > 0 {
            let aheadEnd = min(pages.count - 1, clampedCurrent + preloadMode.aheadCount)
            if clampedCurrent + 1 <= aheadEnd {
                for i in (clampedCurrent + 1)...aheadEnd {
                    orderedIndices.append(i)
                }
            }
        }

        // 其次向前预载（防止回翻卡顿，距离越近越优先）
        if preloadMode.behindCount > 0 {
            let behindStart = max(0, clampedCurrent - preloadMode.behindCount)
            if behindStart < clampedCurrent {
                for i in stride(from: clampedCurrent - 1, through: behindStart, by: -1) {
                    orderedIndices.append(i)
                }
            }
        }

        return orderedIndices.map { pages[$0] }
    }

    private func pruneOutOfWindowL1Tasks() {
        let windowIDs = Set(computeL1WindowPages().map(\.id))
        for (pageID, task) in l1ActiveTasks where !windowIDs.contains(pageID) {
            task.cancel()
            l1ActiveTasks.removeValue(forKey: pageID)
        }
        l1PendingQueue.removeAll { !windowIDs.contains($0.id) }
    }

    private func scheduleL1Window() {
        let windowPages = computeL1WindowPages()
        let windowIDs = Set(windowPages.map(\.id))

        for (pageID, task) in l1ActiveTasks where !windowIDs.contains(pageID) {
            task.cancel()
            l1ActiveTasks.removeValue(forKey: pageID)
        }

        l1PendingQueue = windowPages.filter { page in
            l1ActiveTasks[page.id] == nil
                && OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) == nil
        }

        pumpL1Queue()
    }

    private func pumpL1Queue() {
        guard preloadMode.isEnabled else { return }
        // 当前页未就绪时仅允许 1 个后台下载槽位（优先预热 i+1），就绪后恢复 2 并发
        let maxConcurrency = isCurrentPageReady ? 2 : 1

        while l1ActiveTasks.count < maxConcurrency && !l1PendingQueue.isEmpty {
            let page = l1PendingQueue.removeFirst()
            if l1ActiveTasks[page.id] != nil {
                continue
            }
            if OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) != nil {
                continue
            }

            let task = Task(priority: .utility) { [weak self] in
                await OnlineImageLoader.shared.preloadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
                guard !Task.isCancelled else { return }
                self?.handleL1PageCompleted(page: page)
            }
            l1ActiveTasks[page.id] = task
        }
    }

    private func handleL1PageCompleted(page: MangaPage) {
        l1ActiveTasks.removeValue(forKey: page.id)
        pumpL1Queue()

        // 若刚下完的是下一页（i+1），且当前页已就绪，立刻尝试衔接 L2 超分/滤镜预热
        if page.index == currentPageIndex + 1, isCurrentPageReady {
            scheduleL2IfEligible()
        }
    }

    // MARK: - L2：下一页 AI 超分与画面滤镜预热

    private var isCurrentPageReady: Bool {
        guard pages.indices.contains(currentPageIndex) else { return false }
        let page = pages[currentPageIndex]
        if readyPageIDs.contains(page.id) {
            return true
        }
        guard OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) != nil else {
            return false
        }
        if enableUpscaler {
            return PageUpscalerPipeline.shared.hasCachedResult(
                pageKey: page.imageURL,
                config: upscalerConfig
            )
        }
        return true
    }

    private var isSystemHealthyForUpscalerPreload: Bool {
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            return false
        }
        if UpscalerRuntimeGuard.shared.isInMemoryWarningCooldown {
            return false
        }
        if let cooldownUntil = memoryWarningCooldownUntil, Date() < cooldownUntil {
            return false
        }
        // 可用进程内存低于 320MB 时暂停后台 L2 预超分，将内存余量完全让给当前前台展示页
        if let avail = UpscalerRuntimeGuard.shared.availableProcessMemoryBytes(),
           avail < 320 * 1024 * 1024 {
            return false
        }
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled {
            return false
        }
        switch processInfo.thermalState {
        case .serious, .critical:
            return false
        default:
            return true
        }
    }

    private func scheduleL2IfEligible() {
        guard preloadMode.isEnabled else {
            cancelL2Task()
            return
        }

        let shouldPreheatUpscaler = enableUpscaler && enableUpscalerPreload && isSystemHealthyForUpscalerPreload
        let shouldPreheatFilterOnly = !enableUpscaler && filterConfig.hasActiveFilters

        guard shouldPreheatUpscaler || shouldPreheatFilterOnly else {
            cancelL2Task()
            return
        }

        // 严守“当前页绝对优先”：当前页尚未渲染完成前绝不启动 L2 占算力
        guard isCurrentPageReady else { return }

        let nextIndex = currentPageIndex + 1
        guard pages.indices.contains(nextIndex) else {
            cancelL2Task()
            return
        }

        let nextPage = pages[nextIndex]
        let upscalerSnapshot = upscalerConfig
        let filterSnapshot = filterConfig

        // 若目标成品已完整命中缓存，直接跳过
        if isL2AlreadyCached(
            page: nextPage,
            upscale: shouldPreheatUpscaler,
            upscalerConfig: upscalerSnapshot,
            filterConfig: filterSnapshot
        ) {
            if l2TargetPageID != nextPage.id {
                cancelL2Task()
            }
            return
        }

        let targetKey = "\(nextPage.id)::\(shouldPreheatUpscaler)::\(upscalerSnapshot.cacheKey)::\(filterSnapshot.cacheSignature)"
        if l2TargetKey == targetKey, l2Task != nil {
            return
        }

        cancelL2Task()
        l2TargetPageID = nextPage.id
        l2TargetKey = targetKey

        l2Task = Task(priority: .background) { [weak self] in
            defer {
                if self?.l2TargetKey == targetKey {
                    self?.l2Task = nil
                    self?.l2TargetPageID = nil
                    self?.l2TargetKey = nil
                }
            }

            guard !Task.isCancelled else { return }

            let originalImage: UIImage
            if let mem = OnlineImageLoader.shared.cachedMemoryImage(for: nextPage.imageURL) {
                originalImage = mem
            } else {
                guard let loaded = try? await OnlineImageLoader.shared.loadImage(
                    urlString: nextPage.imageURL,
                    headers: nextPage.headers
                ) else {
                    return
                }
                originalImage = loaded
            }

            guard !Task.isCancelled else { return }

            if shouldPreheatUpscaler {
                // 提前预热 1x 原始底图的滤镜版本，确保即使用户在超分完成前翻页也能零闪烁秒显滤镜底图
                if filterSnapshot.hasActiveFilters {
                    let rawFilterKey = ImageFilterPipeline.cacheKey(
                        pageURL: nextPage.imageURL,
                        upscalerConfig: nil,
                        isUpscaled: false
                    )
                    if ImageFilterPipeline.shared.cachedImage(cacheKey: rawFilterKey, config: filterSnapshot) == nil {
                        _ = await ImageFilterPipeline.shared.processAsync(
                            image: originalImage,
                            cacheKey: rawFilterKey,
                            config: filterSnapshot
                        )
                    }
                }

                guard !Task.isCancelled else { return }

                // 超过单图缓存上限或硬件限制的巨图不参与后台预热，避免无用算力消耗
                guard PageUpscalerPipeline.shared.canCacheUpscaledOutput(
                    for: originalImage,
                    config: upscalerSnapshot
                ) else {
                    return
                }

                let processed = await PageUpscalerPipeline.shared.process(
                    image: originalImage,
                    pageKey: nextPage.imageURL,
                    config: upscalerSnapshot,
                    isEnabled: true
                )
                guard !Task.isCancelled else { return }

                if filterSnapshot.hasActiveFilters {
                    let filterKey = ImageFilterPipeline.cacheKey(
                        pageURL: nextPage.imageURL,
                        upscalerConfig: upscalerSnapshot,
                        isUpscaled: processed.appliedModel != nil
                    )
                    if ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterSnapshot) == nil {
                        _ = await ImageFilterPipeline.shared.processAsync(
                            image: processed.image,
                            cacheKey: filterKey,
                            config: filterSnapshot
                        )
                    }
                }
            } else if filterSnapshot.hasActiveFilters {
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: nextPage.imageURL,
                    upscalerConfig: nil,
                    isUpscaled: false
                )
                if ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterSnapshot) == nil {
                    _ = await ImageFilterPipeline.shared.processAsync(
                        image: originalImage,
                        cacheKey: filterKey,
                        config: filterSnapshot
                    )
                }
            }
        }
    }

    private func isL2AlreadyCached(
        page: MangaPage,
        upscale: Bool,
        upscalerConfig: ImageUpscalerConfig,
        filterConfig: ImageFilterConfig
    ) -> Bool {
        guard OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) != nil else {
            return false
        }
        if upscale {
            guard PageUpscalerPipeline.shared.hasCachedResult(pageKey: page.imageURL, config: upscalerConfig) else {
                return false
            }
            if filterConfig.hasActiveFilters {
                let key = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: upscalerConfig,
                    isUpscaled: true
                )
                return ImageFilterPipeline.shared.cachedImage(cacheKey: key, config: filterConfig) != nil
            }
            return true
        } else if filterConfig.hasActiveFilters {
            let key = ImageFilterPipeline.cacheKey(
                pageURL: page.imageURL,
                upscalerConfig: nil,
                isUpscaled: false
            )
            return ImageFilterPipeline.shared.cachedImage(cacheKey: key, config: filterConfig) != nil
        }
        return true
    }

    // MARK: - L3：章末下一话元数据与首页预载

    private func scheduleL3IfEligible() {
        guard preloadMode.isEnabled, preloadNextChapterEnabled else { return }
        guard !pages.isEmpty, currentPageIndex >= max(0, pages.count - 2) else { return }
        guard let currentIdx = currentChapterIndex, chapters.indices.contains(currentIdx + 1) else {
            return
        }

        let nextChapter = chapters[currentIdx + 1]
        if prefetchedChapterPages[nextChapter.id] != nil {
            return
        }
        if l3TargetChapterID == nextChapter.id, l3Task != nil {
            return
        }

        guard let adapter = adapterProvider?(sourceID) else { return }

        cancelL3Task()
        l3TargetChapterID = nextChapter.id

        l3Task = Task(priority: .utility) { [weak self] in
            defer {
                if self?.l3TargetChapterID == nextChapter.id {
                    self?.l3Task = nil
                    self?.l3TargetChapterID = nil
                }
            }

            guard !Task.isCancelled else { return }
            guard let nextPages = try? await adapter.fetchPages(for: nextChapter),
                  !Task.isCancelled,
                  !nextPages.isEmpty else {
                return
            }

            self?.storePrefetchedChapter(id: nextChapter.id, pages: nextPages)

            // 顺带预载下一话前 2 页原图，点击“下一话”瞬间零等待首屏渲染
            for page in nextPages.prefix(2) {
                guard !Task.isCancelled else { return }
                await OnlineImageLoader.shared.preloadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
            }
        }
    }

    private func storePrefetchedChapter(id: String, pages: [MangaPage]) {
        prefetchedChapterPages[id] = pages
        prefetchedChapterOrder.removeAll { $0 == id }
        prefetchedChapterOrder.append(id)

        while prefetchedChapterOrder.count > maxPrefetchedChapters {
            let evicted = prefetchedChapterOrder.removeFirst()
            prefetchedChapterPages.removeValue(forKey: evicted)
        }
    }

    // MARK: - 系统保护与任务清理

    private func handleMemoryWarning() {
        memoryWarningCooldownUntil = Date().addingTimeInterval(memoryWarningCooldownSeconds)
        cancelL2Task()
    }

    private func cancelL1AndL2Tasks() {
        for task in l1ActiveTasks.values {
            task.cancel()
        }
        l1ActiveTasks.removeAll()
        l1PendingQueue.removeAll()
        cancelL2Task()
    }

    private func cancelL2Task() {
        l2Task?.cancel()
        l2Task = nil
        l2TargetPageID = nil
        l2TargetKey = nil
    }

    private func cancelL3Task() {
        l3Task?.cancel()
        l3Task = nil
        l3TargetChapterID = nil
    }
}
