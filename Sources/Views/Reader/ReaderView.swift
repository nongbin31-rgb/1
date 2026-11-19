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

    func loadAndProcess(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool
    ) async {
        errorMessage = nil
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
            displayImage = original
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

        if transitionAfterUpscaled {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = result.image
            }
        } else {
            self.displayImage = result.image
        }
    }

    /// 释放大图内存，防止 LazyVStack 长列表堆积爆内存
    func releaseMemoryPreservingState() {
        originalImage = nil
        processed = nil
        displayImage = nil
    }
}

/// 沉浸式在线漫画阅读器（支持条漫/翻页、实时切换 Waifu2x & Anime4K、左右分屏对比）
public struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    let manga: Manga
    let chapters: [MangaChapter]

    @State private var currentChapter: MangaChapter
    @State private var pages: [MangaPage] = []
    @State private var currentPageIndex = 0
    @State private var isLoadingChapter = true
    @State private var chapterError: String?

    @State private var showChrome = false
    @State private var showUpscalerSheet = false
    @State private var showConfigPreviewSheet = false
    @State private var showBackgroundPickerSheet = false
    @State private var isCompareMode = false
    @State private var currentHUDText = ""
    @State private var capturedPreviewImage: UIImage?

    public init(manga: Manga, chapters: [MangaChapter], initialChapter: MangaChapter) {
        self.manga = manga
        self.chapters = chapters
        _currentChapter = State(initialValue: initialChapter)
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

                if showChrome {
                    chromeOverlay
                }
            }
            .frame(width: windowGeo.size.width, height: windowGeo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .statusBarHidden(!showChrome)
        .task(id: currentChapter.id) {
            await loadChapterPages()
        }
        .onDisappear {
            if !pages.isEmpty {
                store.updateProgress(manga: manga, chapter: currentChapter, pageIndex: currentPageIndex)
            }
        }
        .sheet(isPresented: $showUpscalerSheet) {
            ReaderUpscalerSheet(
                config: $store.upscalerConfig,
                enableUpscaler: $store.enableImageUpscaler,
                transitionAfterUpscaled: $store.transitionAfterImageUpscaled,
                layoutMode: $store.readerLayoutMode,
                turningEffect: $store.pageTurningEffect,
                soundEnabled: $store.pageTurnSoundEnabled,
                showSpineShadow: $store.showSpineShadowInCurl,
                onOpenAdvancedConfig: {
                    capturedPreviewImage = resolveCurrentImageForPreview()
                    showUpscalerSheet = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        showConfigPreviewSheet = true
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showConfigPreviewSheet) {
            ReaderImageUpscalerConfigView(
                imageForPreview: resolveCurrentImageForPreview()
            )
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
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if let bgImg = capturedPreviewImage {
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
            .ignoresSafeArea()
        case .texture:
            ZStack {
                Color(red: 0.965, green: 0.957, blue: 0.941)
                if store.readerTextureTarget == .both || store.readerTextureTarget == .backgroundOnly {
                    PaperTextureOverlayView(
                        texture: store.readerTextureType,
                        opacity: store.readerTextureOpacity
                    )
                }
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var readerContent: some View {
        if store.readerLayoutMode == .verticalWebtoon && !isCompareMode {
            GeometryReader { geo in
                let contentWidth = geo.size.width
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(pages) { page in
                            VerticalMangaPageCell(
                                page: page,
                                contentWidth: contentWidth,
                                config: store.upscalerConfig,
                                isEnabled: store.enableImageUpscaler,
                                transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                                background: store.preferredReaderBackground,
                                texture: store.readerTextureType,
                                textureOpacity: store.readerTextureOpacity,
                                textureTarget: store.readerTextureTarget,
                                onStatusUpdate: { text in
                                    if page.index == currentPageIndex {
                                        currentHUDText = text
                                    }
                                },
                                onImageLoaded: { img in
                                    if page.index == currentPageIndex {
                                        capturedPreviewImage = img
                                    }
                                }
                            )
                            .onAppear {
                                currentPageIndex = page.index
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChrome.toggle()
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
                isCompareMode: isCompareMode,
                isRightToLeft: store.readerLayoutMode == .pagedRTL,
                soundEnabled: store.pageTurnSoundEnabled,
                showSpineShadow: store.showSpineShadowInCurl,
                background: store.preferredReaderBackground,
                texture: store.readerTextureType,
                textureOpacity: store.readerTextureOpacity,
                textureTarget: store.readerTextureTarget,
                showDividingLine: store.showSpineDividingLine,
                currentPageIndex: $currentPageIndex,
                onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChrome.toggle()
                    }
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
                }
            )
        } else {
            // 阻尼磁吸滑动 (SnapPage) 与 零延迟模式 (Instant)
            SnapPageReaderView(
                pages: pages,
                upscalerConfig: store.upscalerConfig,
                enableUpscaler: store.enableImageUpscaler,
                transitionAfterUpscaled: store.transitionAfterImageUpscaled,
                isCompareMode: isCompareMode,
                isRightToLeft: store.readerLayoutMode == .pagedRTL,
                turningEffect: store.pageTurningEffect,
                soundEnabled: store.pageTurnSoundEnabled,
                background: store.preferredReaderBackground,
                texture: store.readerTextureType,
                textureOpacity: store.readerTextureOpacity,
                textureTarget: store.readerTextureTarget,
                currentPageIndex: $currentPageIndex,
                onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showChrome.toggle()
                    }
                },
                onStatusUpdate: { text in
                    currentHUDText = text
                },
                onImageLoaded: { img in
                    capturedPreviewImage = img
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
                    withAnimation {
                        isCompareMode.toggle()
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
                .disabled(!store.enableImageUpscaler)
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
                                set: { currentPageIndex = Int($0.rounded()) }
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
                        .padding(.horizontal, 12)
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
                        .padding(.horizontal, 14)
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
        }
        .transition(.opacity)
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
        currentPageIndex = 0

        guard let adapter = store.adapter(for: manga.sourceID) else {
            chapterError = "未找到图源适配器 [\(manga.sourceID)]"
            isLoadingChapter = false
            return
        }

        do {
            let loadedPages = try await adapter.fetchPages(for: currentChapter)
            self.pages = loadedPages
            if let saved = store.progress(for: manga), saved.chapterID == currentChapter.id {
                self.currentPageIndex = min(saved.pageIndex, max(0, loadedPages.count - 1))
            }
        } catch {
            self.chapterError = error.localizedDescription
        }

        isLoadingChapter = false
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
    var background: ReaderBackground = .followSystem
    var texture: ReaderTextureType = .classic
    var textureOpacity: Double = 0.4
    var textureTarget: ReaderTextureTarget = .both
    let onStatusUpdate: (String) -> Void
    var onImageLoaded: ((UIImage) -> Void)? = nil

    @StateObject private var slot = ReaderPageSlot()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let displayImage = slot.displayImage {
                if contentWidth > 0, displayImage.size.width > 0 {
                    let scale = UIScreen.main.scale
                    let rawHeight = contentWidth * (displayImage.size.height / displayImage.size.width)
                    let alignedHeight = max(1, (rawHeight * scale).rounded(.down) / scale)
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: contentWidth, height: alignedHeight)
                        .clipped()
                } else {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }

                // 拟真纸质材质纹理正片叠底 (仅在目标包含画面本身时覆盖于图片上)
                if background == .texture && (textureTarget == .both || textureTarget == .imageOnly) {
                    PaperTextureOverlayView(texture: texture, opacity: textureOpacity)
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
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(Color.white.opacity(0.06))
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(textColorForBackground)
                    Text("加载第 \(page.index + 1) 页...")
                        .font(.caption)
                        .foregroundStyle(textColorForBackground.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .background(Color.white.opacity(0.05))
            }
        }
        .task(id: "\(page.id)::\(config.cacheKey)::\(isEnabled)") {
            await triggerLoad()
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
        case .texture:
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
            transitionAfterUpscaled: transitionAfterUpscaled
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
    @Binding var config: ImageUpscalerConfig
    @Binding var enableUpscaler: Bool
    @Binding var transitionAfterUpscaled: Bool
    @Binding var layoutMode: ReaderLayoutMode
    @Binding var turningEffect: PageTurningEffect
    @Binding var soundEnabled: Bool
    @Binding var showSpineShadow: Bool
    var onOpenAdvancedConfig: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读排版与翻页动画") {
                    Picker("排版方式", selection: $layoutMode) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
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
                }

                Section("画质超分选项") {
                    Toggle("启用 AI 画质增强", isOn: $enableUpscaler)
                    Toggle("增强后平滑淡入", isOn: $transitionAfterUpscaled)

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
    }
}
