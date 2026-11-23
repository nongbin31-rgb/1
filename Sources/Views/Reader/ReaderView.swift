import SwiftUI

/// 单页加载与超分状态模型
@MainActor
private final class ReaderPageSlot: ObservableObject {
    @Published var originalImage: UIImage?
    @Published var processed: ProcessedPageImage?
    @Published var displayImage: UIImage?
    @Published var isLoading = true
    @Published var isUpscaling = false
    @Published var upscaleProgress: String = ""
    @Published var errorMessage: String?

    private var currentLoadedURL: String?
    private var lastAppliedConfig: ImageUpscalerConfig?
    private var lastIsEnabled: Bool?
    private var lastAppliedFilterSignature: String?
    private var loadGeneration: UInt64 = 0

    func loadAndProcess(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    ) async {
        errorMessage = nil

        let targetFilterSig = filterConfig.cacheSignature

        // 若当前 Slot 被复用于不同页面或不同章节 URL，彻底重置旧图像与状态，坚决防止复用上一话旧图
        if currentLoadedURL != page.imageURL {
            originalImage = nil
            processed = nil
            displayImage = nil
            lastAppliedConfig = nil
            lastIsEnabled = nil
            lastAppliedFilterSignature = nil
            isUpscaling = false
            upscaleProgress = ""
            currentLoadedURL = page.imageURL
        }

        // 动态调滤镜极速响应快路径：原图已在内存，且超分配置/开启状态未变，仅调整滤镜参数时直接对现有成品跑 CoreImage 滤镜
        if let existingOriginal = originalImage {
            if !isEnabled {
                if lastIsEnabled == false {
                    if lastAppliedFilterSignature == targetFilterSig, displayImage != nil {
                        return
                    }
                    let filterKey = ImageFilterPipeline.cacheKey(
                        pageURL: page.imageURL,
                        upscalerConfig: nil,
                        isUpscaled: false
                    )
                    let finalImage = filterConfig.hasActiveFilters
                        ? ImageFilterPipeline.shared.process(image: existingOriginal, cacheKey: filterKey, config: filterConfig)
                        : existingOriginal
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.displayImage = finalImage
                    self.isLoading = false
                    return
                }
            } else if lastIsEnabled == true, lastAppliedConfig == config, let existingProcessed = processed {
                if lastAppliedFilterSignature == targetFilterSig, displayImage != nil {
                    return
                }
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: config,
                    isUpscaled: existingProcessed.appliedModel != nil
                )
                let finalImage = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.process(image: existingProcessed.image, cacheKey: filterKey, config: filterConfig)
                    : existingProcessed.image
                self.lastAppliedFilterSignature = targetFilterSig
                self.displayImage = finalImage
                self.isLoading = false
                return
            }
        }

        // 零闪烁内存全命中快路径：预载入已备齐原图 + 目标超分/滤镜时同步直出
        if let memOriginal = originalImage ?? OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) {
            let origSize = Self.pixelSize(of: memOriginal)
            if !isEnabled {
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: nil,
                    isUpscaled: false
                )
                let fastDisplay = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterConfig)
                    : memOriginal
                if let fastDisplay {
                    loadGeneration &+= 1
                    self.originalImage = memOriginal
                    self.processed = ProcessedPageImage(
                        image: memOriginal,
                        originalSize: origSize,
                        outputSize: origSize,
                        elapsedMs: 0,
                        appliedModel: nil
                    )
                    self.lastIsEnabled = false
                    self.lastAppliedConfig = nil
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.isLoading = false
                    self.isUpscaling = false
                    self.upscaleProgress = ""
                    self.displayImage = fastDisplay
                    return
                }
            } else if let memUpscaled = PageUpscalerPipeline.shared.cachedImage(
                pageKey: page.imageURL,
                config: config
            ) {
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: config,
                    isUpscaled: true
                )
                let fastDisplay = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterConfig)
                    : memUpscaled
                if let fastDisplay {
                    loadGeneration &+= 1
                    self.originalImage = memOriginal
                    self.processed = ProcessedPageImage(
                        image: memUpscaled,
                        originalSize: origSize,
                        outputSize: Self.pixelSize(of: memUpscaled),
                        elapsedMs: 0,
                        appliedModel: config.model,
                        notice: "命中缓存"
                    )
                    self.lastIsEnabled = true
                    self.lastAppliedConfig = config
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.isLoading = false
                    self.isUpscaling = false
                    self.upscaleProgress = ""
                    self.displayImage = fastDisplay
                    return
                }
            }
        }

        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        var rawLoadedImage: UIImage? = originalImage
        if rawLoadedImage == nil {
            if let memOriginal = OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) {
                rawLoadedImage = memOriginal
            } else {
                isLoading = true
                do {
                    let img = try await OnlineImageLoader.shared.loadImage(
                        urlString: page.imageURL,
                        headers: page.headers
                    )
                    guard !Task.isCancelled, loadGeneration == currentGeneration else { return }
                    rawLoadedImage = img
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, loadGeneration == currentGeneration else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                    return
                }
            }
        }

        guard let original = rawLoadedImage else { return }
        self.originalImage = original

        // 【原子化滤镜门禁】：先根据当前滤镜配置生成 1x 基准底图，绝不在屏幕上提前暴露未处理的原图
        let rawFilterKey = ImageFilterPipeline.cacheKey(
            pageURL: page.imageURL,
            upscalerConfig: nil,
            isUpscaled: false
        )
        let baselineFilteredImage = filterConfig.hasActiveFilters
            ? ImageFilterPipeline.shared.process(
                image: original,
                cacheKey: rawFilterKey,
                config: filterConfig
            )
            : original

        // 若超分未启用，直接呈现带滤镜的原图，首帧即是最终效果，绝无二次跳变闪烁
        guard isEnabled else {
            let size = Self.pixelSize(of: original)
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedModel: nil
            )
            lastIsEnabled = false
            lastAppliedConfig = nil
            self.lastAppliedFilterSignature = targetFilterSig
            self.displayImage = baselineFilteredImage
            self.isLoading = false
            return
        }

        // 超分已启用：秒显底图直接展示带滤镜的 baselineFilteredImage，基准色调从第 0 毫秒起就与最终成品完全一致
        self.displayImage = baselineFilteredImage
        self.isLoading = false

        isUpscaling = true
        upscaleProgress = ""
        defer {
            if loadGeneration == currentGeneration {
                isUpscaling = false
                upscaleProgress = ""
            }
        }
        let result = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config,
            isEnabled: isEnabled,
            progress: { [weak self] pct in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == currentGeneration else { return }
                    self.upscaleProgress = pct
                }
            }
        )
        guard !Task.isCancelled, loadGeneration == currentGeneration else { return }
        self.processed = result
        self.lastIsEnabled = true
        self.lastAppliedConfig = config

        let finalImage: UIImage
        if filterConfig.hasActiveFilters {
            let filterKey = ImageFilterPipeline.cacheKey(
                pageURL: page.imageURL,
                upscalerConfig: config,
                isUpscaled: result.appliedModel != nil
            )
            finalImage = ImageFilterPipeline.shared.process(
                image: result.image,
                cacheKey: filterKey,
                config: filterConfig
            )
        } else {
            finalImage = result.image
        }
        self.lastAppliedFilterSignature = targetFilterSig

        // 命中预热缓存时零闪烁直出；仅现场等待超分完成后播放平滑淡入（色调完全一致，仅清晰度由 1x 柔和过渡到 2x）
        let shouldAnimateTransition = transitionAfterUpscaled
            && result.appliedModel != nil
            && result.notice != "命中缓存"
            && result.elapsedMs > 0
        if shouldAnimateTransition {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = finalImage
            }
        } else {
            self.displayImage = finalImage
        }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CGSize(width: cg.height, height: cg.width)
            default:
                return CGSize(width: cg.width, height: cg.height)
            }
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// 释放大图内存，防止 LazyVStack 长列表堆积爆内存
    func releaseMemoryPreservingState() {
        loadGeneration &+= 1
        isUpscaling = false
        upscaleProgress = ""
        originalImage = nil
        processed = nil
        displayImage = nil
        lastAppliedConfig = nil
        lastIsEnabled = nil
        lastAppliedFilterSignature = nil
        currentLoadedURL = nil
    }
}

/// 沉浸式在线漫画阅读器（支持条漫/翻页、实时切换 Waifu2x & Anime4K、左右分屏对比）
public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let manga: Manga
    let chapters: [MangaChapter]
    private let initialChapterID: String

    @State private var currentChapter: MangaChapter
    @State private var pages: [MangaPage] = []
    @State private var currentPageIndex = 0
    @State private var initialSpecifiedPageIndex: Int?
    @State private var isRestoringInitialPage = false
    @State private var requestedScrollIndex: Int? = nil
    @State private var isLoadingChapter = true
    @State private var chapterError: String?

    @State private var showChrome = false
    @State private var showUpscalerSheet = false
    @State private var showConfigPreviewSheet = false
    @State private var showBackgroundPickerSheet = false
    @State private var showImageFilterSheet = false
    @State private var isCompareMode = false
    @State private var currentHUDText = ""
    @State private var capturedPreviewImage: UIImage?
    @State private var activeLayoutMode: ReaderLayoutMode = .verticalWebtoon
    @State private var hasInitializedLayout = false
    @StateObject private var preloader = ReaderPreloadCoordinator()
    @StateObject private var pageCacheSnapshot = ReaderPageCacheSnapshotStore()
    @ObservedObject private var thumbnailStore = ReaderThumbnailStore.shared

    // 进度条预览交互与原点回溯状态
    @State private var isScrubbingProgress = false
    @State private var scrubFraction: Double = 0
    @State private var activeScrubSpeed: ReaderScrubSpeed = .fast
    @State private var scrubSessionOriginIndex = 0
    @State private var returnAnchorPageIndex: Int? = nil
    @State private var anchorJumpDestinationIndex: Int? = nil
    @State private var isProgrammaticJumping = false
    @State private var programmaticJumpToken = UUID()
    @State private var externalJumpNonce = 0
    @State private var cachedPageAspectRatios: [String: CGFloat] = [:]

    public init(manga: Manga, chapters: [MangaChapter], initialChapter: MangaChapter, initialPageIndex: Int? = nil) {
        self.manga = manga
        self.chapters = chapters
        self.initialChapterID = initialChapter.id
        _currentChapter = State(initialValue: initialChapter)
        _currentPageIndex = State(initialValue: initialPageIndex ?? 0)
        _initialSpecifiedPageIndex = State(initialValue: initialPageIndex)
    }

    private var currentChapterArrayIndex: Int? {
        chapters.firstIndex(where: { $0.id == currentChapter.id })
    }

    private var preloadSettingsSignature: String {
        "\(store.readerPreloadMode.rawValue)::\(store.enableImageUpscaler)::\(store.enableUpscalerPreload)::\(store.upscalerConfig.reloadKey)::\(store.imageFilterConfig.cacheSignature)::\(store.preloadNextChapter)"
    }

    public var body: some View {
        GeometryReader { windowGeo in
            ZStack {
                readerBackgroundView
                    .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                    .clipped()

                if isLoadingChapter {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("正在加载章节页面...")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                } else if let chapterError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(chapterError)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        HStack {
                            Button("返回") { dismiss() }
                                .buttonStyle(.bordered)
                            Button("重试") {
                                Task { await loadChapterPages() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                } else if pages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.questionmark")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("该章节暂无图片页")
                            .foregroundStyle(.white.opacity(0.8))
                        Button("返回") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                } else {
                    readerContent
                        .id(currentChapter.id)
                        .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                        .clipped()
                }

                if isScrubbingProgress && pages.count > 1 && store.readerProgressStyle != .sideRail {
                    let insets = safeAreaInsetsResolved
                    ReaderScrubberPreviewOverlay(
                        pages: pages,
                        scrubFraction: scrubFraction,
                        originIndex: scrubSessionOriginIndex,
                        returnAnchorIndex: returnAnchorPageIndex,
                        isRightToLeft: activeLayoutMode == .pagedRTL,
                        upscalerConfig: store.upscalerConfig,
                        enableUpscaler: store.enableImageUpscaler,
                        bottomReservedHeight: insets.bottom + 108,
                        progressStyle: store.readerProgressStyle,
                        scrubSpeed: activeScrubSpeed,
                        thumbnailStore: thumbnailStore
                    )
                    .transition(.opacity)
                    .zIndex(11)
                }

                // 沉浸阅读态极简进度微轨 & 侧边隐形纵轨
                ReaderAmbientProgressOverlay(
                    style: store.readerProgressStyle,
                    showChrome: showChrome,
                    showAmbientProgress: store.showAmbientProgressInReader,
                    isScrubbing: isScrubbingProgress,
                    totalPages: pages.count,
                    currentPageIndex: currentPageIndex,
                    isRightToLeft: activeLayoutMode == .pagedRTL,
                    readerBackground: store.preferredReaderBackground,
                    safeAreaInsets: safeAreaInsetsResolved,
                    chapterTitle: currentChapter.title,
                    chapterIndex: currentChapterArrayIndex,
                    totalChapters: chapters.count,
                    onSideRailScrubBegin: { initialFraction in
                        scrubSessionOriginIndex = currentPageIndex
                        scrubFraction = initialFraction
                        isScrubbingProgress = true
                    },
                    onSideRailScrubChanged: { newFraction in
                        scrubFraction = newFraction
                    },
                    onSideRailScrubEnd: { finalIndex in
                        isScrubbingProgress = false
                        commitProgressJump(
                            to: finalIndex,
                            originIndex: scrubSessionOriginIndex,
                            recordAnchor: true
                        )
                    }
                )
                .zIndex(10)

                chromeOverlay
                    .zIndex(12)

                // 两侧物理边缘快速滑入退出漫画（原生 UIScreenEdgePanGestureRecognizer，零干扰翻页）
                ReaderEdgeSwipeDismissOverlay(
                    isEnabled: store.enableEdgeSwipeDismiss,
                    isBlocked: isScrubbingProgress || isCompareMode,
                    onDismiss: {
                        dismiss()
                    }
                )
                .zIndex(14)

                // 当处于对比模式且导航栏收起时，提供常驻半透明快捷退出按钮，彻底解决无法退出的死锁
                if isCompareMode {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                                    isCompareMode = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark")
                                        .font(.caption.bold())
                                    Text("退出对比")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                                .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
                            }
                            .padding(.trailing, max(windowGeo.safeAreaInsets.trailing, 16))
                            .padding(.top, max(windowGeo.safeAreaInsets.top, 16) + 4)
                        }
                        Spacer()
                    }
                    .opacity(showChrome ? 0 : 1)
                    .scaleEffect(showChrome ? 0.92 : 1.0)
                    .allowsHitTesting(!showChrome)
                    .animation(.spring(response: 0.30, dampingFraction: 0.92), value: showChrome)
                    .zIndex(13)
                }
            }
            .frame(width: windowGeo.size.width, height: windowGeo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .statusBarHidden(!showChrome)
        .onAppear {
            initializeLayoutIfNeeded()
            syncPreloaderSettings()
            store.beginReadingSession()
            ReaderDeviceInfoStore.shared.startMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            store.endReadingSession()
            ReaderDeviceInfoStore.shared.stopMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            store.beginReadingSession()
            ReaderDeviceInfoStore.shared.startMonitoring()
        }
        .task(id: currentChapter.id) {
            initializeLayoutIfNeeded()
            syncPreloaderSettings()
            await loadChapterPages()
        }
        .onDisappear {
            preloader.cancelAll()
            thumbnailStore.cancelHoverPrefetch()
            if !pages.isEmpty {
                store.updateProgress(
                    manga: manga,
                    chapter: currentChapter,
                    pageIndex: currentPageIndex,
                    totalPages: pages.count,
                    chapterIndex: currentChapterArrayIndex,
                    totalChapters: chapters.count
                )
            }
            store.endReadingSession()
            ReaderDeviceInfoStore.shared.stopMonitoring()
        }
        .onChange(of: currentPageIndex) { newIndex in
            if pages.indices.contains(newIndex),
               let cached = OnlineImageLoader.shared.cachedMemoryImage(for: pages[newIndex].imageURL) {
                capturedPreviewImage = cached
            }
            if let anchor = returnAnchorPageIndex {
                if newIndex == anchor {
                    returnAnchorPageIndex = nil
                    anchorJumpDestinationIndex = nil
                } else if !isProgrammaticJumping,
                          let dest = anchorJumpDestinationIndex,
                          abs(newIndex - dest) > 5 {
                    returnAnchorPageIndex = nil
                    anchorJumpDestinationIndex = nil
                }
            }
            preloader.updateCurrentPage(newIndex)
            if showChrome && (store.readerProgressStyle == .vernierDial || store.readerProgressStyle == .heatmapSeg) {
                refreshPageCacheSnapshot()
            }
            guard !isRestoringInitialPage, !pages.isEmpty else { return }
            store.updateProgress(
                manga: manga,
                chapter: currentChapter,
                pageIndex: newIndex,
                totalPages: pages.count,
                chapterIndex: currentChapterArrayIndex,
                totalChapters: chapters.count
            )
        }
        .onChange(of: preloadSettingsSignature) { _ in
            syncPreloaderSettings()
            refreshPageCacheSnapshot()
        }
        .onChange(of: showChrome) { isVisible in
            if isVisible {
                refreshPageCacheSnapshot()
            }
        }
        .onChange(of: store.readerProgressStyle) { _ in
            refreshPageCacheSnapshot()
        }
        .onChange(of: pages.count) { _ in
            refreshPageCacheSnapshot()
        }
        .onDisappear {
            pageCacheSnapshot.cancel()
        }
        .sheet(isPresented: $showUpscalerSheet) {
            ReaderUpscalerSheet(
                manga: manga,
                config: $store.upscalerConfig,
                enableUpscaler: $store.enableImageUpscaler,
                transitionAfterUpscaled: $store.transitionAfterImageUpscaled,
                layoutMode: $activeLayoutMode,
                turningEffect: $store.pageTurningEffect,
                soundEnabled: $store.pageTurnSoundEnabled,
                showSpineShadow: $store.showSpineShadowInCurl,
                onOpenAdvancedConfig: {
                    capturedPreviewImage = resolveCurrentImageForPreview()
                    showUpscalerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showConfigPreviewSheet = true
                    }
                },
                onOpenImageFilter: {
                    capturedPreviewImage = resolveCurrentImageForPreview()
                    showUpscalerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showImageFilterSheet = true
                    }
                }
            )
            .environmentObject(store)
            .compatPresentationDetentsMediumLarge()
        }
        .fullScreenCover(isPresented: $showConfigPreviewSheet) {
            ReaderImageUpscalerConfigView(
                imageForPreview: resolveCurrentImageForPreview()
            )
            .environmentObject(store)
        }
        .fullScreenCover(isPresented: $showImageFilterSheet) {
            ReaderImageFilterView(
                previewImage: resolveCurrentImageForPreview()
            )
            .environmentObject(store)
        }
        .sheet(isPresented: $showBackgroundPickerSheet) {
            ReaderBackgroundPickerSheet()
                .environmentObject(store)
        }
    }

    @ViewBuilder
    private var readerBackgroundView: some View {
        switch store.preferredReaderBackground {
        case .followSystem:
            Color(uiColor: .systemBackground).ignoresSafeArea()
        case .light:
            Color.white.ignoresSafeArea()
        case .dark:
            Color.black.ignoresSafeArea()
        case .immersive:
            immersiveBackdropView
                .ignoresSafeArea()
        case .texture:
            if store.readerTextureTarget == .imageOnly {
                imageOnlyBackdropView
                    .ignoresSafeArea()
            } else {
                ZStack {
                    paperTintBackdropView
                    PaperTextureOverlayView(
                        texture: store.readerTextureType,
                        opacity: store.readerTextureOpacity,
                        tintOpacity: store.readerTextureTintOpacity,
                        grainDensity: store.readerClassicGrainDensity
                    )
                }
                .ignoresSafeArea()
            }
        }
    }

    private var paperTintBackdropView: some View {
        ZStack {
            Color.white
            if store.readerTextureTintOpacity > 0.001 {
                store.readerTextureType.basePaperSwiftUIColor
                    .opacity(store.readerTextureTintOpacity)
            }
        }
    }

    private var immersiveBackdropView: some View {
        GeometryReader { geo in
            let bgImg = capturedPreviewImage
                ?? (pages.indices.contains(currentPageIndex)
                    ? OnlineImageLoader.shared.cachedImage(for: pages[currentPageIndex].imageURL)
                    : nil)
            ZStack {
                Color.black
                if let bgImg {
                    Image(uiImage: bgImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 45)
                        .opacity(0.8)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    @ViewBuilder
    private var imageOnlyBackdropView: some View {
        switch store.readerImageOnlyBackdrop {
        case .paperTint:
            paperTintBackdropView
        case .followSystem:
            Color(uiColor: .systemBackground)
        case .light:
            Color.white
        case .dark:
            Color.black
        case .immersive:
            immersiveBackdropView
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if activeLayoutMode == .verticalWebtoon && !isCompareMode {
            GeometryReader { geo in
                let contentWidth = geo.size.width
                let scale = UIScreen.main.scale
                let pixelOverlap = 1.0 / scale

                ZoomableWebtoonContainer(
                    onSingleTap: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                            showChrome.toggle()
                        }
                    }
                ) {
                    ScrollViewReader { scrollProxy in
                        let showsSystemIndicator = store.readerProgressStyle != .sideRail
                        ScrollView(.vertical, showsIndicators: showsSystemIndicator) {
                            LazyVStack(spacing: 0) {
                                ForEach(pages) { page in
                                    VerticalMangaPageCell(
                                        page: page,
                                        contentWidth: contentWidth,
                                        config: store.upscalerConfig,
                                        isEnabled: store.enableImageUpscaler,
                                        transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                                        filterConfig: store.imageFilterConfig,
                                        background: store.preferredReaderBackground,
                                        texture: store.readerTextureType,
                                        textureOpacity: store.readerTextureOpacity,
                                        textureTintOpacity: store.readerTextureTintOpacity,
                                        textureGrainDensity: store.readerClassicGrainDensity,
                                        textureTarget: store.readerTextureTarget,
                                        imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                                        texturePhaseAnchor: .namedSpace("webtoon_scroll_content"),
                                        textureReferenceSize: geo.size,
                                        cachedAspectRatio: cachedPageAspectRatios[page.id],
                                        onStatusUpdate: { text in
                                            if page.index == currentPageIndex {
                                                currentHUDText = text
                                            }
                                        },
                                        onImageLoaded: { img in
                                            if img.size.width > 0, img.size.height > 0 {
                                                let aspect = img.size.height / img.size.width
                                                if cachedPageAspectRatios[page.id] == nil {
                                                    cachedPageAspectRatios[page.id] = aspect
                                                }
                                            }
                                            if page.index == currentPageIndex {
                                                capturedPreviewImage = img
                                            }
                                            checkAspectRatioIfUndetermined(with: img.size)
                                        },
                                        onPageReady: { readyIdx in
                                            if pages.indices.contains(readyIdx) {
                                                preloader.markPageReady(pageID: pages[readyIdx].id, index: readyIdx)
                                            }
                                        }
                                    )
                                    .id(page.index)
                                    .padding(.bottom, -pixelOverlap)
                                    .onAppear {
                                        if !isRestoringInitialPage && !isProgrammaticJumping {
                                            currentPageIndex = page.index
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(name: "webtoon_scroll_content")
                            .background(WebtoonScrollIndicatorSyncView(showsIndicator: showsSystemIndicator))
                        }
                        .id("webtoon_scroll_\(currentChapter.id)")
                        .onAppear {
                            if isRestoringInitialPage && currentPageIndex > 0 {
                                restoreWebtoonInitialPage(proxy: scrollProxy)
                            }
                        }
                        .onChange(of: requestedScrollIndex) { target in
                            if let target = target {
                                scrollProxy.scrollTo(target, anchor: .top)
                                requestedScrollIndex = nil
                            }
                        }
                    }
                }
            }
        } else if store.pageTurningEffect == .curling {
            // 仿真书本卷页模式 (PageCurl 3D立体网格折叠)
            StablePageCurlReaderView(
                pages: pages,
                upscalerConfig: store.upscalerConfig,
                enableUpscaler: store.enableImageUpscaler,
                transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                filterConfig: store.imageFilterConfig,
                isCompareMode: isCompareMode,
                isRightToLeft: activeLayoutMode == .pagedRTL,
                soundEnabled: store.pageTurnSoundEnabled,
                showSpineShadow: store.showSpineShadowInCurl,
                background: store.preferredReaderBackground,
                texture: store.readerTextureType,
                textureOpacity: store.readerTextureOpacity,
                textureTintOpacity: store.readerTextureTintOpacity,
                textureGrainDensity: store.readerClassicGrainDensity,
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                showDividingLine: store.showSpineDividingLine,
                currentPageIndex: $currentPageIndex,
                externalJumpNonce: externalJumpNonce,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onTapLocation: { normalizedX, isZoomed in
                    handleHorizontalPageTap(normalizedX: normalizedX, isZoomed: isZoomed)
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
                },
                onPageReady: { readyIdx in
                    if pages.indices.contains(readyIdx) {
                        preloader.markPageReady(pageID: pages[readyIdx].id, index: readyIdx)
                    }
                }
            )
        } else if store.pageTurningEffect == .cover {
            // 层叠覆盖模式 (Cover 纸页平移抽离与边缘落影)
            CoverPageReaderView(
                pages: pages,
                upscalerConfig: store.upscalerConfig,
                enableUpscaler: store.enableImageUpscaler,
                transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                filterConfig: store.imageFilterConfig,
                isCompareMode: isCompareMode,
                isRightToLeft: activeLayoutMode == .pagedRTL,
                soundEnabled: store.pageTurnSoundEnabled,
                background: store.preferredReaderBackground,
                texture: store.readerTextureType,
                textureOpacity: store.readerTextureOpacity,
                textureTintOpacity: store.readerTextureTintOpacity,
                textureGrainDensity: store.readerClassicGrainDensity,
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                showDividingLine: store.showSpineDividingLine,
                currentPageIndex: $currentPageIndex,
                externalJumpNonce: externalJumpNonce,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onTapLocation: { normalizedX, isZoomed in
                    handleHorizontalPageTap(normalizedX: normalizedX, isZoomed: isZoomed)
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
                },
                onPageReady: { readyIdx in
                    if pages.indices.contains(readyIdx) {
                        preloader.markPageReady(pageID: pages[readyIdx].id, index: readyIdx)
                    }
                }
            )
        } else {
            // 阻尼磁吸滑动 (SnapPage) 与 零延迟模式 (Instant)
            SnapPageReaderView(
                pages: pages,
                upscalerConfig: store.upscalerConfig,
                enableUpscaler: store.enableImageUpscaler,
                transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                filterConfig: store.imageFilterConfig,
                isCompareMode: isCompareMode,
                isRightToLeft: activeLayoutMode == .pagedRTL,
                turningEffect: store.pageTurningEffect,
                soundEnabled: store.pageTurnSoundEnabled,
                background: store.preferredReaderBackground,
                texture: store.readerTextureType,
                textureOpacity: store.readerTextureOpacity,
                textureTintOpacity: store.readerTextureTintOpacity,
                textureGrainDensity: store.readerClassicGrainDensity,
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                currentPageIndex: $currentPageIndex,
                externalJumpNonce: externalJumpNonce,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onTapLocation: { normalizedX, isZoomed in
                    handleHorizontalPageTap(normalizedX: normalizedX, isZoomed: isZoomed)
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
                },
                onPageReady: { readyIdx in
                    if pages.indices.contains(readyIdx) {
                        preloader.markPageReady(pageID: pages[readyIdx].id, index: readyIdx)
                    }
                }
            )
        }
    }

    private var chromeOverlay: some View {
        let insets = safeAreaInsetsResolved
        return ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // 顶部导航栏（拖动预览期间平滑隐退，聚焦微弧画廊）
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(currentChapter.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            if chapters.count > 1, let chIdx = currentChapterArrayIndex {
                                Text("\(chIdx + 1)/\(chapters.count)话")
                                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.92))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.white.opacity(0.18), in: Capsule())
                                    .fixedSize()
                            }
                        }
                        Text(currentHUDText.isEmpty ? (store.enableImageUpscaler ? store.upscalerConfig.summaryText : "原图显示") : currentHUDText)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }

                    Spacer()

                    readerProgressStyleMenuButton

                    Button {
                        if !store.enableImageUpscaler {
                            currentHUDText = "请先开启画质增强"
                            showUpscalerSheet = true
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isCompareMode.toggle()
                            }
                        }
                    } label: {
                        Label(isCompareMode ? "退出对比" : "对比", systemImage: "rectangle.split.2x1")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                isCompareMode ? Color.accentColor : Color.white.opacity(0.18),
                                in: Capsule()
                            )
                            .foregroundStyle(.white)
                    }
                }
                .padding(.leading, max(insets.left, 16))
                .padding(.trailing, max(insets.right, 16))
                .padding(.top, insets.top + 8)
                .padding(.bottom, 14)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.88),
                            Color.black.opacity(0.70),
                            Color.black.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .offset(y: showChrome ? 0 : -(insets.top + 88))
                .opacity(showChrome && !isScrubbingProgress ? 1 : 0)
                .allowsHitTesting(showChrome && !isScrubbingProgress)

                Spacer()

                // 底部控制栏（拖动轨道常驻不销毁，防止触摸流中断）
                VStack(spacing: 12) {
                    if pages.count > 1 {
                        ReaderActiveProgressBar(
                            style: store.readerProgressStyle,
                            totalPages: pages.count,
                            currentPageIndex: currentPageIndex,
                            isScrubbing: isScrubbingProgress,
                            scrubFraction: scrubFraction,
                            isRightToLeft: activeLayoutMode == .pagedRTL,
                            originAnchorIndex: isScrubbingProgress
                                ? (returnAnchorPageIndex ?? scrubSessionOriginIndex)
                                : returnAnchorPageIndex,
                            cacheStatuses: pageCacheSnapshot,
                            chapterIndex: currentChapterArrayIndex,
                            totalChapters: chapters.count,
                            onScrubBegin: { initialFraction in
                                scrubSessionOriginIndex = currentPageIndex
                                scrubFraction = initialFraction
                                activeScrubSpeed = .fast
                                withAnimation(.easeOut(duration: 0.16)) {
                                    isScrubbingProgress = true
                                }
                                let focusIdx = min(max(Int(initialFraction.rounded()), 0), max(pages.count - 1, 0))
                                thumbnailStore.scheduleHoverUpdate(pages: pages, focusIndex: focusIdx)
                            },
                            onScrubChanged: { newFraction in
                                scrubFraction = newFraction
                                let focusIdx = min(max(Int(newFraction.rounded()), 0), max(pages.count - 1, 0))
                                thumbnailStore.scheduleHoverUpdate(pages: pages, focusIndex: focusIdx)
                            },
                            onSpeedChanged: { speed in
                                activeScrubSpeed = speed
                            },
                            onScrubEnd: { finalIndex in
                                thumbnailStore.cancelHoverPrefetch()
                                activeScrubSpeed = .fast
                                withAnimation(.easeOut(duration: 0.18)) {
                                    isScrubbingProgress = false
                                }
                                commitProgressJump(
                                    to: finalIndex,
                                    originIndex: scrubSessionOriginIndex,
                                    recordAnchor: true
                                )
                            }
                        )
                    }

                    HStack {
                        Button {
                            switchChapter(delta: -1)
                        } label: {
                            Label("上一话", systemImage: "backward.end")
                                .font(.caption)
                        }
                        .disabled((currentChapterArrayIndex ?? 0) <= 0)

                        Spacer()

                        Button {
                            showBackgroundPickerSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: store.preferredReaderBackground.systemIcon)
                                Text(store.preferredReaderBackground == .texture ? store.readerTextureType.shortName : store.preferredReaderBackground.title)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                        }

                        Spacer()

                        Button {
                            showUpscalerSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                Text(store.enableImageUpscaler ? store.upscalerConfig.model.displayName : "画质增强")
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(store.enableImageUpscaler ? Color.accentColor : Color.white.opacity(0.2), in: Capsule())
                            .foregroundStyle(.white)
                        }

                        Spacer()

                        Button {
                            switchChapter(delta: 1)
                        } label: {
                            Label("下一话", systemImage: "forward.end")
                                .font(.caption)
                        }
                        .disabled({
                            guard let idx = currentChapterArrayIndex else { return true }
                            return idx >= chapters.count - 1
                        }())
                    }
                    .foregroundStyle(.white)
                    .opacity(isScrubbingProgress ? 0 : 1)
                    .allowsHitTesting(!isScrubbingProgress)
                }
                .padding(.leading, max(insets.left, 18))
                .padding(.trailing, max(insets.right, 18))
                .padding(.top, 14)
                .padding(.bottom, insets.bottom + 10)
                .background(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.0),
                            Color.black.opacity(0.70),
                            Color.black.opacity(0.88)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(isScrubbingProgress ? 0.35 : 1.0)
                )
                .offset(y: showChrome ? 0 : (insets.bottom + 148))
                .opacity(showChrome ? 1 : 0)
                .allowsHitTesting(showChrome)
            }
            .animation(.spring(response: 0.30, dampingFraction: 0.92), value: showChrome)

            // 跨页跳转后的返回原点锚点胶囊（独立叠放在进度条上方，完全不影响滑轨几何位置）
            if showChrome && !isScrubbingProgress,
               let anchor = returnAnchorPageIndex,
               anchor >= 0,
               anchor < pages.count,
               anchor != currentPageIndex {
                HStack {
                    Spacer()
                    ReaderReturnAnchorPill(
                        anchorPageIndex: anchor,
                        onReturn: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                commitProgressJump(to: anchor, originIndex: nil, recordAnchor: false)
                            }
                        },
                        onDismiss: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                returnAnchorPageIndex = nil
                                anchorJumpDestinationIndex = nil
                            }
                        }
                    )
                }
                .padding(.trailing, max(insets.right, 16))
                .padding(.bottom, insets.bottom + (pages.count > 1 ? 104 : 66))
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }

    /// 获取当前设备绝对可靠的安全区域边距（防止全屏沉浸/隐藏状态栏时系统 UIWindow 错误返回 0）
    private var safeAreaInsetsResolved: UIEdgeInsets {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first

        if let scene = activeScene {
            let validWindows = scene.windows.filter {
                $0.bounds.width > 0 && ($0.safeAreaInsets.top > 0 || $0.safeAreaInsets.bottom > 0)
            }
            if let window = validWindows.first(where: { $0.isKeyWindow }) ?? validWindows.first {
                var insets = window.safeAreaInsets
                let isPortrait = (scene.interfaceOrientation.isPortrait || window.bounds.height >= window.bounds.width)
                if isPortrait && insets.top < hardwareBaselineSafeAreaTop {
                    insets.top = hardwareBaselineSafeAreaTop
                }
                if isPortrait && insets.bottom < 34 && hardwareBaselineSafeAreaTop > 24 {
                    insets.bottom = 34
                }
                return insets
            }
        }

        // 终极硬件基线兜底（按屏幕物理特征）
        let screenBounds = UIScreen.main.bounds
        let isPortrait = screenBounds.height >= screenBounds.width
        if isPortrait {
            return UIEdgeInsets(top: hardwareBaselineSafeAreaTop, left: 0, bottom: hardwareBaselineSafeAreaBottom, right: 0)
        } else {
            return UIEdgeInsets(top: 0, left: hardwareBaselineSafeAreaTop, bottom: 21, right: hardwareBaselineSafeAreaTop)
        }
    }

    /// 基于物理屏幕尺寸的硬件基线顶部安全区（即使系统窗口返回 0 也能精准规避灵动岛与刘海）
    private var hardwareBaselineSafeAreaTop: CGFloat {
        let maxDimension = max(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
        if maxDimension >= 852 {
            // 灵动岛机型 (iPhone 14 Pro/Pro Max, 15/15 Pro 全系, 16 全系)
            return 59
        } else if maxDimension >= 812 {
            // 刘海屏机型 (iPhone X/XS/XR/11/12/13/14 标准版)
            return 47
        } else {
            // 经典无刘海机型或 iPad
            return 24
        }
    }

    /// 基于物理屏幕尺寸的硬件基线底部安全区
    private var hardwareBaselineSafeAreaBottom: CGFloat {
        let maxDimension = max(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
        return maxDimension >= 812 ? 34 : 12
    }

    private func initializeLayoutIfNeeded() {
        guard !hasInitializedLayout else { return }
        activeLayoutMode = store.layoutMode(for: manga)
        hasInitializedLayout = true
    }

    /// 水平翻页模式（日漫 / 常规）三段式点击热区处理：
    /// 左侧 [0, 0.30) / 中间 [0.30, 0.70] 唤出工具栏 / 右侧 (0.70, 1.0]
    private func handleHorizontalPageTap(normalizedX: CGFloat, isZoomed: Bool) {
        // 工具栏展开时，点击屏幕任意位置优先收起工具栏，避免误翻页
        if showChrome {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                showChrome = false
            }
            return
        }

        // 未启用点击翻页、处于放大态、对比态或仅单页时，退回普通单击唤出工具栏
        guard store.enableTapPageTurn,
              activeLayoutMode != .verticalWebtoon,
              !isCompareMode,
              !isZoomed,
              pages.count > 1 else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                showChrome.toggle()
            }
            return
        }

        let isLeftZone = normalizedX < 0.30
        let isRightZone = normalizedX > 0.70
        guard isLeftZone || isRightZone else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                showChrome.toggle()
            }
            return
        }

        // 默认：日漫 (RTL) 左=下一页、右=上一页；常规 (LTR) 左=上一页、右=下一页
        // 开启翻转方向开关后左右语义互换
        let baseLeftIsNext = (activeLayoutMode == .pagedRTL)
        let effectiveLeftIsNext = store.invertTapPageTurn ? !baseLeftIsNext : baseLeftIsNext
        let goNext = isLeftZone ? effectiveLeftIsNext : !effectiveLeftIsNext
        let targetIndex = currentPageIndex + (goNext ? 1 : -1)

        guard pages.indices.contains(targetIndex) else {
            #if canImport(UIKit)
            let generator = UIImpactFeedbackGenerator(style: .rigid)
            generator.impactOccurred(intensity: 0.65)
            #endif
            currentHUDText = goNext ? "已是本话最后一页" : "已是本话第 1 页"
            return
        }

        // 仅更新 currentPageIndex（不递增 externalJumpNonce），驱动底层容器执行对应翻页动画与音效
        currentPageIndex = targetIndex
    }

    private var readerProgressStyleMenuButton: some View {
        Menu {
            Section("进度条交互风格") {
                ForEach(ReaderProgressStyle.allCases) { style in
                    Button {
                        guard store.readerProgressStyle != style else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.readerProgressStyle = style
                        }
                        currentHUDText = "进度条：\(style.displayName)"
                    } label: {
                        Label {
                            Text(style.displayName)
                        } icon: {
                            Image(systemName: store.readerProgressStyle == style ? "checkmark" : style.iconName)
                        }
                    }
                }
            }

            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.showAmbientProgressInReader.toggle()
                }
                currentHUDText = store.showAmbientProgressInReader
                    ? "已开启沉浸态极简进度"
                    : "已开启纯净全屏（隐藏进度）"
            } label: {
                Label(
                    store.showAmbientProgressInReader ? "隐藏控制栏时显示进度 ✓" : "隐藏控制栏时显示进度",
                    systemImage: store.showAmbientProgressInReader ? "eye" : "eye.slash"
                )
            }
        } label: {
            Image(systemName: store.readerProgressStyle.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("切换进度条风格与沉浸态显示，当前为\(store.readerProgressStyle.displayName)")
    }

    private func refreshPageCacheSnapshot() {
        pageCacheSnapshot.refresh(
            pages: pages,
            enableUpscaler: store.enableImageUpscaler,
            upscalerConfig: store.upscalerConfig
        )
    }

    private func checkAspectRatioIfUndetermined(with size: CGSize) {
        guard store.autoDetectMangaLayout, store.customLayoutMode(for: manga) == nil else { return }
        guard size.width > 0, size.height > 0 else { return }

        let ratio = size.height / size.width
        // 若为高瘦条漫长图（>= 1.85）且当前未处于条漫模式，智能自适应切换为条漫
        if ratio >= 1.85 && activeLayoutMode != .verticalWebtoon {
            withAnimation(.easeInOut(duration: 0.25)) {
                activeLayoutMode = .verticalWebtoon
            }
        }
    }

    private func switchChapter(delta: Int) {
        guard let currentIndex = currentChapterArrayIndex else { return }
        let targetIndex = currentIndex + delta
        guard chapters.indices.contains(targetIndex) else { return }
        let nextChapter = chapters[targetIndex]
        thumbnailStore.cancelHoverPrefetch()
        isScrubbingProgress = false
        returnAnchorPageIndex = nil
        anchorJumpDestinationIndex = nil
        isProgrammaticJumping = false
        cachedPageAspectRatios.removeAll()
        store.updateProgress(
            manga: manga,
            chapter: currentChapter,
            pageIndex: currentPageIndex,
            totalPages: pages.count > 0 ? pages.count : nil,
            chapterIndex: currentIndex,
            totalChapters: chapters.count
        )
        // 关键防御：切换章节时立即清空旧页面并置位加载状态，杜绝上一话内容在切换瞬间残留闪烁
        self.pages = []
        self.currentPageIndex = 0
        self.isLoadingChapter = true
        currentChapter = nextChapter
    }

    /// 统一处理进度条松手跳转或回跳锚点定位，避免拖动过程高频写回页码导致滑块抽动
    private func commitProgressJump(to targetIndex: Int, originIndex: Int?, recordAnchor: Bool) {
        guard pages.indices.contains(targetIndex) else { return }

        if targetIndex == returnAnchorPageIndex {
            returnAnchorPageIndex = nil
            anchorJumpDestinationIndex = nil
        } else if recordAnchor, let origin = originIndex, origin != targetIndex {
            if returnAnchorPageIndex == nil {
                returnAnchorPageIndex = origin
            }
            anchorJumpDestinationIndex = targetIndex
        }

        guard targetIndex != currentPageIndex else { return }

        let token = UUID()
        programmaticJumpToken = token
        isProgrammaticJumping = true
        externalJumpNonce &+= 1
        currentPageIndex = targetIndex

        if activeLayoutMode == .verticalWebtoon && !isCompareMode {
            requestedScrollIndex = targetIndex
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 85_000_000)
                guard programmaticJumpToken == token else { return }
                requestedScrollIndex = targetIndex

                try? await Task.sleep(nanoseconds: 220_000_000)
                guard programmaticJumpToken == token else { return }
                isProgrammaticJumping = false
            }
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard programmaticJumpToken == token else { return }
                isProgrammaticJumping = false
            }
        }
    }

    private func syncPreloaderSettings() {
        preloader.updateSettings(
            preloadMode: store.readerPreloadMode,
            enableUpscaler: store.enableImageUpscaler,
            enableUpscalerPreload: store.enableUpscalerPreload,
            upscalerConfig: store.upscalerConfig,
            filterConfig: store.imageFilterConfig,
            preloadNextChapter: store.preloadNextChapter
        )
    }

    private func loadChapterPages() async {
        chapterError = nil

        let targetIndex: Int
        if let specified = initialSpecifiedPageIndex, currentChapter.id == initialChapterID {
            targetIndex = specified
            self.initialSpecifiedPageIndex = nil
        } else if let saved = store.progress(for: manga), saved.chapterID == currentChapter.id {
            targetIndex = saved.pageIndex
        } else {
            targetIndex = 0
        }

        // 优先命中永久离线缓存页面清单（断网/弱网下实现零网络等待秒开）
        if let offlinePages = OfflineDownloadManager.shared.offlinePages(
            mangaKey: manga.compositeKey,
            chapterID: currentChapter.id
        ), !offlinePages.isEmpty {
            applyLoadedChapterPages(offlinePages, targetIndex: targetIndex)
            isLoadingChapter = false
            return
        }

        // 若 L3 已预取本话页面列表，直接瞬时切入免去章节 Loading 等待
        if let prefetchedPages = preloader.consumePrefetchedPages(for: currentChapter.id), !prefetchedPages.isEmpty {
            applyLoadedChapterPages(prefetchedPages, targetIndex: targetIndex)
            isLoadingChapter = false
            return
        }

        isLoadingChapter = true

        guard let adapter = store.adapter(for: manga.sourceID) else {
            chapterError = "未找到图源适配器 [\(manga.sourceID)]"
            isLoadingChapter = false
            return
        }

        do {
            let loadedPages = try await adapter.fetchPages(for: currentChapter)
            applyLoadedChapterPages(loadedPages, targetIndex: targetIndex)
        } catch {
            self.chapterError = error.localizedDescription
        }

        isLoadingChapter = false
    }

    private func applyLoadedChapterPages(_ loadedPages: [MangaPage], targetIndex: Int) {
        self.pages = loadedPages
        self.isScrubbingProgress = false
        self.returnAnchorPageIndex = nil
        self.anchorJumpDestinationIndex = nil
        self.isProgrammaticJumping = false
        self.cachedPageAspectRatios.removeAll()
        let resolvedIndex = min(targetIndex, max(0, loadedPages.count - 1))
        self.currentPageIndex = resolvedIndex
        self.isRestoringInitialPage = (resolvedIndex > 0)
        if !loadedPages.isEmpty {
            store.updateProgress(
                manga: manga,
                chapter: currentChapter,
                pageIndex: resolvedIndex,
                totalPages: loadedPages.count,
                chapterIndex: currentChapterArrayIndex,
                totalChapters: chapters.count
            )
            let appStore = store
            syncPreloaderSettings()
            preloader.updateContext(
                chapterID: currentChapter.id,
                pages: loadedPages,
                chapters: chapters,
                currentChapterIndex: currentChapterArrayIndex,
                sourceID: manga.sourceID,
                adapterProvider: { [weak appStore] sourceID in
                    appStore?.adapter(for: sourceID)
                }
            )
            preloader.updateCurrentPage(resolvedIndex)
        }
    }

    /// 条漫模式平滑精准恢复初始历史页码（双帧渐进式定位，避让首屏 LazyVStack 重绘）
    private func restoreWebtoonInitialPage(proxy: ScrollViewProxy) {
        guard currentPageIndex > 0 else {
            isRestoringInitialPage = false
            return
        }
        let target = currentPageIndex
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            proxy.scrollTo(target, anchor: .top)
            try? await Task.sleep(nanoseconds: 160_000_000)
            proxy.scrollTo(target, anchor: .top)
            isRestoringInitialPage = false
        }
    }

    /// 解析用于超分高级预览的图片（多层兜底保障，绝不返回无效空图）
    private func resolveCurrentImageForPreview() -> UIImage {
        if let captured = capturedPreviewImage, captured.size.width > 0 {
            return captured
        }
        if pages.indices.contains(currentPageIndex) {
            let page = pages[currentPageIndex]
            if let cached = OnlineImageLoader.shared.cachedImage(for: page.imageURL) {
                return cached
            }
        }
        if let sample = ReaderTextureCache.shared.previewSampleImage() {
            return sample
        }
        for ext in ["jpg", "png", "heic"] {
            if let path = Bundle.main.path(forResource: "Starry_night_in_manga_original", ofType: ext),
               let img = UIImage(contentsOfFile: path) {
                return img
            }
            if let path = Bundle.main.path(forResource: "Texture_Preview_sample", ofType: ext),
               let img = UIImage(contentsOfFile: path) {
                return img
            }
        }
        return UIImage()
    }
}

private struct VerticalMangaPageCell: View {
    let page: MangaPage
    let contentWidth: CGFloat
    let config: ImageUpscalerConfig
    let isEnabled: Bool
    let transitionAfterUpscaled: Bool
    var filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    var background: ReaderBackground = .followSystem
    var texture: ReaderTextureType = .classic
    var textureOpacity: Double = 0.4
    var textureTintOpacity: Double = 1.0
    var textureGrainDensity: Double = 1.0
    var textureTarget: ReaderTextureTarget = .both
    var imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    var texturePhaseAnchor: TexturePhaseAnchor = .local
    var textureReferenceSize: CGSize? = nil
    var cachedAspectRatio: CGFloat? = nil
    let onStatusUpdate: (String) -> Void
    var onImageLoaded: ((UIImage) -> Void)? = nil
    var onPageReady: ((Int) -> Void)? = nil

    @StateObject private var slot = ReaderPageSlot()

    private var resolvedPlaceholderHeight: CGFloat {
        guard contentWidth > 0, let ratio = cachedAspectRatio, ratio > 0 else {
            return 380
        }
        return max(160, ceil(contentWidth * ratio))
    }

    private var shouldApplyImageTexture: Bool {
        background == .texture && (textureTarget == .both || textureTarget == .imageOnly)
    }

    private var shouldApplyPlaceholderTexture: Bool {
        background == .texture && (textureTarget == .both || textureTarget == .backgroundOnly)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let displayImage = slot.displayImage {
                if contentWidth > 0, displayImage.size.width > 0 {
                    let scale = UIScreen.main.scale
                    let pixelSize = 1.0 / scale
                    let rawHeight = contentWidth * (displayImage.size.height / displayImage.size.width)
                    // 向上对齐物理像素，彻底杜绝向下取整造成的像素缺失
                    let alignedHeight = max(pixelSize, ceil(rawHeight * scale) / scale)

                    // 透明漫画兜底白底，避免透出底层静态背景造成纹理重影
                    if shouldApplyImageTexture {
                        Color.white
                            .frame(width: contentWidth, height: alignedHeight)
                    }

                    // 核心抗接缝设计 (Subpixel Anti-Seam Overlap)：
                    // 图片高度增加 1 物理像素微重叠，并在显示上严格无缝衔接
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: contentWidth, height: alignedHeight + pixelSize)
                        .frame(width: contentWidth, height: alignedHeight, alignment: .top)
                        .clipped()

                    // 真实物理纸张原生底色正片叠底 (支持 0%~100% 着色浓度调节，0% 时保留原图纯白不发黄)
                    if shouldApplyImageTexture {
                        if textureTintOpacity > 0.001 {
                            texture.basePaperSwiftUIColor
                                .opacity(textureTintOpacity)
                                .blendMode(.multiply)
                                .frame(width: contentWidth, height: alignedHeight)
                                .clipped()
                        }

                        // 拟真纸质材质纹理正片叠底：绑定滚动内容坐标系，随漫画紧贴同步滚动且多图接缝无缝对齐
                        PaperTextureOverlayView(
                            texture: texture,
                            opacity: textureOpacity,
                            tintOpacity: textureTintOpacity,
                            grainDensity: textureGrainDensity,
                            phaseAnchor: texturePhaseAnchor,
                            referenceSize: textureReferenceSize
                        )
                        .frame(width: contentWidth, height: alignedHeight)
                    }
                } else {
                    if shouldApplyImageTexture {
                        Color.white
                    }

                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)

                    if shouldApplyImageTexture {
                        if textureTintOpacity > 0.001 {
                            texture.basePaperSwiftUIColor
                                .opacity(textureTintOpacity)
                                .blendMode(.multiply)
                        }

                        PaperTextureOverlayView(
                            texture: texture,
                            opacity: textureOpacity,
                            tintOpacity: textureTintOpacity,
                            grainDensity: textureGrainDensity,
                            phaseAnchor: texturePhaseAnchor,
                            referenceSize: textureReferenceSize
                        )
                    }
                }

                if slot.isUpscaling {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75).tint(.white)
                        Text(
                            slot.upscaleProgress.isEmpty
                                ? "\(config.model.displayName) 超分中"
                                : "\(config.model.displayName) 超分中 \(slot.upscaleProgress)"
                        )
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.75), in: Capsule())
                    .padding(8)
                }
            } else if let err = slot.errorMessage {
                ZStack {
                    if shouldApplyPlaceholderTexture {
                        Color.white
                        if textureTintOpacity > 0.001 {
                            texture.basePaperSwiftUIColor
                                .opacity(textureTintOpacity)
                        }
                        PaperTextureOverlayView(
                            texture: texture,
                            opacity: textureOpacity,
                            tintOpacity: textureTintOpacity,
                            grainDensity: textureGrainDensity,
                            phaseAnchor: texturePhaseAnchor,
                            referenceSize: textureReferenceSize
                        )
                    } else {
                        Color.white.opacity(0.06)
                    }

                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(textColorForBackground.opacity(0.8))
                        Button("重试") {
                            Task { await triggerLoad() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .clipped()
            } else {
                ZStack {
                    if shouldApplyPlaceholderTexture {
                        Color.white
                        if textureTintOpacity > 0.001 {
                            texture.basePaperSwiftUIColor
                                .opacity(textureTintOpacity)
                        }
                        PaperTextureOverlayView(
                            texture: texture,
                            opacity: textureOpacity,
                            tintOpacity: textureTintOpacity,
                            grainDensity: textureGrainDensity,
                            phaseAnchor: texturePhaseAnchor,
                            referenceSize: textureReferenceSize
                        )
                    } else {
                        Color.white.opacity(0.05)
                    }

                    VStack(spacing: 10) {
                        ProgressView().tint(textColorForBackground)
                        Text("加载第 \(page.index + 1) 页...")
                            .font(.caption)
                            .foregroundStyle(textColorForBackground.opacity(0.75))
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: resolvedPlaceholderHeight)
                .clipped()
            }
        }
        .task(id: "\(page.id)::\(config.reloadKey)::\(isEnabled)::\(filterConfig.cacheSignature)") {
            await triggerLoad()
        }
        .onDisappear {
            slot.releaseMemoryPreservingState()
        }
    }

    private var textColorForBackground: Color {
        switch background {
        case .light:
            return .black
        case .followSystem:
            return .primary
        case .texture:
            if textureTarget == .imageOnly {
                return imageOnlyBackdrop.placeholderTextColor
            }
            return Color(red: 0.2, green: 0.18, blue: 0.15)
        default:
            return .white
        }
    }

    private func triggerLoad() async {
        await slot.loadAndProcess(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig
        )
        guard !Task.isCancelled else { return }
        if slot.errorMessage == nil, slot.displayImage != nil {
            onPageReady?(page.index)
        }
        if let orig = slot.originalImage {
            onImageLoaded?(orig)
        }
        if let p = slot.processed {
            let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
            let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
            if let notice = p.notice {
                onStatusUpdate("\(orig) → \(out) · \(notice)")
            } else if let model = p.appliedModel {
                onStatusUpdate("\(model.displayName) · \(orig) → \(out) · \(p.elapsedMs)ms")
            } else {
                onStatusUpdate("原图 \(orig)")
            }
        }
    }
}

/// 阅读器底部弹出的实时超分 & 排版配置面板
private struct ReaderUpscalerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let manga: Manga
    @Binding var config: ImageUpscalerConfig
    @Binding var enableUpscaler: Bool
    @Binding var transitionAfterUpscaled: Bool
    @Binding var layoutMode: ReaderLayoutMode
    @Binding var turningEffect: PageTurningEffect
    @Binding var soundEnabled: Bool
    @Binding var showSpineShadow: Bool
    var onOpenAdvancedConfig: () -> Void
    var onOpenImageFilter: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Button {
                        onOpenImageFilter()
                    } label: {
                        HStack {
                            Image(systemName: "camera.filters")
                                .foregroundStyle(Color.accentColor)
                            Text("画面滤镜")
                                .font(.body.weight(.medium))
                            Spacer()
                            if store.imageFilterConfig.hasActiveFilters {
                                Text("\(store.imageFilterConfig.activeFilterTypes.count) 项启用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("未启用")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("画面色彩与线条调节")
                } footer: {
                    Text("支持将彩漫转黑白、改善扫描图发灰、锐化画面线条、调节色温护眼以及暗部层次微调。")
                }
                Section {
                    Picker("排版方式", selection: Binding(
                        get: { layoutMode },
                        set: { newMode in
                            layoutMode = newMode
                            store.setLayoutMode(newMode, for: manga)
                        }
                    )) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }

                    if store.customLayoutMode(for: manga) != nil {
                        HStack {
                            Label("已单独为此漫画指定排版", systemImage: "pin.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("恢复智能匹配") {
                                store.setLayoutMode(nil, for: manga)
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    layoutMode = store.layoutMode(for: manga)
                                }
                            }
                            .font(.caption.weight(.semibold))
                        }
                    } else if store.autoDetectMangaLayout {
                        let category = store.detectedCategory(for: manga)
                        HStack {
                            Label(
                                category == .koreanWebtoon
                                    ? "智能匹配：韩漫 (已自动切换条漫滚动)"
                                    : (category == .japaneseManga
                                        ? "智能匹配：日漫 (已自动切换日漫翻页)"
                                        : "常规模式 (使用默认排版)"),
                                systemImage: category == .normal ? "info.circle" : "sparkles"
                            )
                            .font(.caption)
                            .foregroundStyle(category == .normal ? Color.secondary : Color.accentColor)
                        }
                    }

                    if layoutMode != .verticalWebtoon {
                        Picker("左右翻页特效", selection: $turningEffect) {
                            ForEach(PageTurningEffect.allCases) { effect in
                                Text(effect.displayName).tag(effect)
                            }
                        }

                        Toggle("点击左右两侧翻页", isOn: $store.enableTapPageTurn)

                        if store.enableTapPageTurn {
                            let baseLeftIsNext = (layoutMode == .pagedRTL)
                            let effectiveLeftIsNext = store.invertTapPageTurn ? !baseLeftIsNext : baseLeftIsNext
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("点击翻页方向")
                                        .font(.body)
                                    Text(effectiveLeftIsNext ? "左→下一页 · 右→上一页" : "左→上一页 · 右→下一页")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        store.invertTapPageTurn.toggle()
                                    }
                                    #if canImport(UIKit)
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    #endif
                                } label: {
                                    Label("翻转方向", systemImage: "arrow.left.arrow.right")
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Toggle("翻页音效与轻触震动", isOn: $soundEnabled)

                        if turningEffect == .curling {
                            Toggle("书脊中缝立体渐变阴影", isOn: $showSpineShadow)
                        }
                    }

                    Toggle("两侧边缘快滑退出漫画", isOn: $store.enableEdgeSwipeDismiss)
                } header: {
                    Text("阅读排版与翻页动画")
                } footer: {
                    if store.autoDetectMangaLayout {
                        Text("系统已开启智能排版：韩漫自动采用条漫滚动，日漫自动采用从右向左翻页；手动切换后将仅为当前漫画记住选择。")
                    }
                }

                Section {
                    Toggle("启用 AI 画质增强", isOn: $enableUpscaler)
                    Toggle("增强后平滑淡入", isOn: $transitionAfterUpscaled)
                    if enableUpscaler && store.readerPreloadMode.isEnabled {
                        Toggle("空闲预热下一页超分", isOn: $store.enableUpscalerPreload)
                    }
                    Toggle("解除超分尺寸限制（慎用）", isOn: $config.bypassSizeLimit)

                    Picker("超分引擎", selection: $config.model) {
                        ForEach(ImageUpscalerModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    Button {
                        onOpenAdvancedConfig()
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.2.square.on.square")
                            Text("画质增强高级配置与实时对比")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("画质超分选项")
                } footer: {
                    Text(
                        config.bypassSizeLimit
                            ? "已解除 1200 万总像素限制，超巨图可能内存飙升或闪退；Anime4K 仍受 Metal 8192px 单边硬件限制。"
                            : "默认采用 1200 万总像素保护，支持 800×8000 等模糊条漫长图直接超分。"
                    )
                }
            }
            .navigationTitle("画质超分与阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 同步条漫 ScrollView 底层 UIScrollView 的垂直滚动条显示状态（兼容 iOS 15+，支持阅读中动态切换进度器风格而不丢失滚动位置）
private struct WebtoonScrollIndicatorSyncView: UIViewRepresentable {
    let showsIndicator: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var current: UIView? = uiView.superview
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView {
                    if scrollView.showsVerticalScrollIndicator != showsIndicator {
                        scrollView.showsVerticalScrollIndicator = showsIndicator
                    }
                    break
                }
                current = candidate.superview
            }
        }
    }
}
