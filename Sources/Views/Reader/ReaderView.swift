import SwiftUI

/// 单页加载与超分状态模型
@MainActor
private final class ReaderPageSlot: ObservableObject {
    @Published var originalImage: UIImage?
    @Published var processed: ProcessedPageImage?
    @Published var displayImage: UIImage?
    @Published var isLoading = true
    @Published var isUpscaling = false
    @Published var errorMessage: String?

    private var lastAppliedConfig: ImageUpscalerConfig?
    private var lastIsEnabled: Bool?
    private var lastAppliedFilterSignature: String?

    func loadAndProcess(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    ) async {
        errorMessage = nil

        let targetFilterSig = filterConfig.cacheSignature

        // 如果原图已经存在，检查是否已经达到目标状态以避免重复计算
        if let original = originalImage {
            if !isEnabled {
                if lastIsEnabled == false,
                   processed?.appliedModel == nil,
                   lastAppliedFilterSignature == targetFilterSig,
                   displayImage != nil {
                    return
                }
            } else if lastIsEnabled == true,
                      lastAppliedConfig == config,
                      lastAppliedFilterSignature == targetFilterSig,
                      let currentProcessed = processed,
                      displayImage != nil {
                return
            }
        }

        if originalImage == nil {
            isLoading = true
            do {
                let img = try await OnlineImageLoader.shared.loadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
                self.originalImage = img
                self.displayImage = img
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
            isLoading = false
            await Task.yield()
        }

        guard let original = originalImage else { return }

        guard isEnabled else {
            let size = CGSize(
                width: original.cgImage?.width ?? Int(original.size.width),
                height: original.cgImage?.height ?? Int(original.size.height)
            )
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedModel: nil
            )
            lastIsEnabled = false
            lastAppliedConfig = nil

            let finalImage: UIImage
            if filterConfig.hasActiveFilters {
                finalImage = ImageFilterPipeline.shared.process(
                    image: original,
                    cacheKey: "\(page.imageURL)_webtoon_raw",
                    config: filterConfig
                )
            } else {
                finalImage = original
            }
            self.lastAppliedFilterSignature = targetFilterSig
            self.displayImage = finalImage
            return
        }

        isUpscaling = true
        defer { isUpscaling = false }
        let result = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config,
            isEnabled: isEnabled
        )
        self.processed = result
        self.lastIsEnabled = true
        self.lastAppliedConfig = config

        let finalImage: UIImage
        if filterConfig.hasActiveFilters {
            finalImage = ImageFilterPipeline.shared.process(
                image: result.image,
                cacheKey: "\(page.imageURL)_webtoon_upscaled",
                config: filterConfig
            )
        } else {
            finalImage = result.image
        }
        self.lastAppliedFilterSignature = targetFilterSig

        if transitionAfterUpscaled {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = finalImage
            }
        } else {
            self.displayImage = finalImage
        }
    }

    /// 释放大图内存，防止 LazyVStack 长列表堆积爆内存
    func releaseMemoryPreservingState() {
        originalImage = nil
        processed = nil
        displayImage = nil
        lastAppliedConfig = nil
        lastIsEnabled = nil
        lastAppliedFilterSignature = nil
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
                        .frame(width: windowGeo.size.width, height: windowGeo.size.height)
                        .clipped()
                }

                chromeOverlay
                    .zIndex(10)

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
                    .zIndex(11)
                }
            }
            .frame(width: windowGeo.size.width, height: windowGeo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .statusBarHidden(!showChrome)
        .onAppear {
            initializeLayoutIfNeeded()
        }
        .task(id: currentChapter.id) {
            initializeLayoutIfNeeded()
            await loadChapterPages()
        }
        .onDisappear {
            if !pages.isEmpty {
                store.updateProgress(manga: manga, chapter: currentChapter, pageIndex: currentPageIndex)
            }
        }
        .onChange(of: currentPageIndex) { newIndex in
            if pages.indices.contains(newIndex),
               let cached = OnlineImageLoader.shared.cachedImage(for: pages[newIndex].imageURL) {
                capturedPreviewImage = cached
            }
            guard !isRestoringInitialPage, !pages.isEmpty else { return }
            store.updateProgress(manga: manga, chapter: currentChapter, pageIndex: newIndex)
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
                        tintOpacity: store.readerTextureTintOpacity
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
                        ScrollView {
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
                                        textureTarget: store.readerTextureTarget,
                                        imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                                        texturePhaseAnchor: .namedSpace("webtoon_scroll_content"),
                                        textureReferenceSize: geo.size,
                                        onStatusUpdate: { text in
                                            if page.index == currentPageIndex {
                                                currentHUDText = text
                                            }
                                        },
                                        onImageLoaded: { img in
                                            if page.index == currentPageIndex {
                                                capturedPreviewImage = img
                                            }
                                            checkAspectRatioIfUndetermined(with: img.size)
                                        }
                                    )
                                    .id(page.index)
                                    .padding(.bottom, -pixelOverlap)
                                    .onAppear {
                                        if !isRestoringInitialPage {
                                            currentPageIndex = page.index
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(name: "webtoon_scroll_content")
                        }
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
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                showDividingLine: store.showSpineDividingLine,
                currentPageIndex: $currentPageIndex,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
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
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                showDividingLine: store.showSpineDividingLine,
                currentPageIndex: $currentPageIndex,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
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
                textureTarget: store.readerTextureTarget,
                imageOnlyBackdrop: store.readerImageOnlyBackdrop,
                currentPageIndex: $currentPageIndex,
                onSingleTap: {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.92)) {
                        showChrome.toggle()
                    }
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                    checkAspectRatioIfUndetermined(with: img.size)
                }
            )
        }
    }

    private var chromeOverlay: some View {
        let insets = safeAreaInsetsResolved
        return VStack(spacing: 0) {
            // 顶部导航栏
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
                    Text(currentChapter.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(currentHUDText.isEmpty ? (store.enableImageUpscaler ? store.upscalerConfig.summaryText : "原图显示") : currentHUDText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }

                Spacer()

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
            .opacity(showChrome ? 1 : 0)
            .allowsHitTesting(showChrome)

            Spacer()

            // 底部控制栏
            VStack(spacing: 12) {
                if pages.count > 1 {
                    HStack(spacing: 10) {
                        Text("\(currentPageIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 28)

                        Slider(
                            value: Binding(
                                get: { Double(currentPageIndex) },
                                set: { val in
                                    let newIndex = Int(val.rounded())
                                    currentPageIndex = newIndex
                                    if activeLayoutMode == .verticalWebtoon {
                                        requestedScrollIndex = newIndex
                                    }
                                }
                            ),
                            in: 0...Double(max(pages.count - 1, 1)),
                            step: 1
                        )
                        .tint(.accentColor)

                        Text("\(pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(width: 28)
                    }
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
            )
            .offset(y: showChrome ? 0 : (insets.bottom + 148))
            .opacity(showChrome ? 1 : 0)
            .allowsHitTesting(showChrome)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.92), value: showChrome)
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
        store.updateProgress(manga: manga, chapter: currentChapter, pageIndex: currentPageIndex)
        currentChapter = nextChapter
    }

    private func loadChapterPages() async {
        isLoadingChapter = true
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

        guard let adapter = store.adapter(for: manga.sourceID) else {
            chapterError = "未找到图源适配器 [\(manga.sourceID)]"
            isLoadingChapter = false
            return
        }

        do {
            let loadedPages = try await adapter.fetchPages(for: currentChapter)
            self.pages = loadedPages
            let resolvedIndex = min(targetIndex, max(0, loadedPages.count - 1))
            self.currentPageIndex = resolvedIndex
            if resolvedIndex > 0 {
                self.isRestoringInitialPage = true
            }
        } catch {
            self.chapterError = error.localizedDescription
        }

        isLoadingChapter = false
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
    var textureTarget: ReaderTextureTarget = .both
    var imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    var texturePhaseAnchor: TexturePhaseAnchor = .local
    var textureReferenceSize: CGSize? = nil
    let onStatusUpdate: (String) -> Void
    var onImageLoaded: ((UIImage) -> Void)? = nil

    @StateObject private var slot = ReaderPageSlot()

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
                            phaseAnchor: texturePhaseAnchor,
                            referenceSize: textureReferenceSize
                        )
                    }
                }

                if slot.isUpscaling {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75).tint(.white)
                        Text("\(config.model.displayName) 超分中")
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
                .frame(height: 380)
                .clipped()
            }
        }
        .task(id: "\(page.id)::\(config.reloadKey)::\(isEnabled)::\(filterConfig.cacheSignature)") {
            await triggerLoad()
        }
        .onChange(of: isEnabled) { _ in
            Task {
                await triggerLoad()
            }
        }
        .onChange(of: config.reloadKey) { _ in
            Task {
                await triggerLoad()
            }
        }
        .onChange(of: filterConfig.cacheSignature) { _ in
            Task {
                await triggerLoad()
            }
        }
        .onDisappear {
            slot.releaseMemoryPreservingState()
        }
        .onAppear {
            if slot.originalImage == nil {
                Task { await triggerLoad() }
            }
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

                        Toggle("翻页音效与轻触震动", isOn: $soundEnabled)

                        if turningEffect == .curling {
                            Toggle("书脊中缝立体渐变阴影", isOn: $showSpineShadow)
                        }
                    }
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
