import SwiftUI

/// 单页加载与超分状态模型
@MainActor
private final class ReaderPageSlot: ObservableObject {
    @Published var originalImage: UIImage?
    @Published var processed: ProcessedPageImage?
    @Published var isLoading = true
    @Published var isUpscaling = false
    @Published var errorMessage: String?

    func loadAndProcess(page: MangaPage, config: ImageUpscalerConfig) async {
        errorMessage = nil
        if originalImage == nil {
            isLoading = true
            do {
                originalImage = try await OnlineImageLoader.shared.loadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
            isLoading = false
            // 先让出一次主线程帧，确保原图立刻上屏显示，再进入超分计算
            await Task.yield()
        }

        guard let original = originalImage else { return }

        if config.engine == .off {
            let size = CGSize(
                width: original.cgImage?.width ?? Int(original.size.width),
                height: original.cgImage?.height ?? Int(original.size.height)
            )
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedEngine: .off
            )
            return
        }

        isUpscaling = true
        defer { isUpscaling = false }
        processed = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config
        )
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

    @State private var showChrome = true
    @State private var showUpscalerSheet = false
    @State private var isCompareMode = false
    @State private var currentHUDText = ""

    public init(manga: Manga, chapters: [MangaChapter], initialChapter: MangaChapter) {
        self.manga = manga
        self.chapters = chapters
        _currentChapter = State(initialValue: initialChapter)
    }

    private var currentChapterArrayIndex: Int? {
        chapters.firstIndex(where: { $0.id == currentChapter.id })
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoadingChapter {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("正在加载章节页面...")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                }
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
            } else {
                readerContent
            }

            if showChrome {
                chromeOverlay
            }
        }
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
                layoutMode: $store.readerLayoutMode
            )
            .presentationDetents([.medium, .large])
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
                                onStatusUpdate: { text in
                                    if page.index == currentPageIndex {
                                        currentHUDText = text
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
        } else {
            TabView(selection: $currentPageIndex) {
                ForEach(pages) { page in
                    PagedMangaPageCell(
                        page: page,
                        config: store.upscalerConfig,
                        isCompareMode: isCompareMode,
                        onSingleTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showChrome.toggle()
                            }
                        },
                        onStatusUpdate: { text in
                            if page.index == currentPageIndex {
                                currentHUDText = text
                            }
                        }
                    )
                    .tag(page.index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .environment(
                \.layoutDirection,
                store.readerLayoutMode == .pagedRTL ? .rightToLeft : .leftToRight
            )
        }
    }

    private var chromeOverlay: some View {
        VStack(spacing: 0) {
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
                    Text(currentHUDText.isEmpty ? store.upscalerConfig.summaryText : currentHUDText)
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
                .disabled(store.upscalerConfig.engine == .off)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.82), .black.opacity(0.0)],
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
                        showUpscalerSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(store.upscalerConfig.engine.shortName)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: Capsule())
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
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 22)
            .background(
                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.88)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .transition(.opacity)
    }

    private func switchChapter(delta: Int) {
        guard let idx = currentChapterArrayIndex else { return }
        let nextIdx = idx + delta
        guard chapters.indices.contains(nextIdx) else { return }
        store.updateProgress(manga: manga, chapter: currentChapter, pageIndex: currentPageIndex)
        currentChapter = chapters[nextIdx]
        currentPageIndex = 0
    }

    private func loadChapterPages() async {
        guard let adapter = store.adapter(for: manga.sourceID) else {
            chapterError = "找不到所属在线图源"
            isLoadingChapter = false
            return
        }
        isLoadingChapter = true
        chapterError = nil
        defer { isLoadingChapter = false }

        do {
            pages = try await adapter.fetchPages(for: currentChapter)
            if let saved = store.progress(for: manga),
               saved.chapterID == currentChapter.id,
               saved.pageIndex < pages.count {
                currentPageIndex = saved.pageIndex
            } else {
                currentPageIndex = 0
            }
        } catch {
            chapterError = error.localizedDescription
            pages = []
        }
    }
}

private struct PagedMangaPageCell: View {
    let page: MangaPage
    let config: ImageUpscalerConfig
    let isCompareMode: Bool
    let onSingleTap: () -> Void
    let onStatusUpdate: (String) -> Void

    @StateObject private var slot = ReaderPageSlot()

    var body: some View {
        ZStack {
            if let orig = slot.originalImage {
                let displayImage = slot.processed?.image ?? orig
                if isCompareMode, config.engine != .off, let processed = slot.processed {
                    SplitCompareView(
                        originalImage: orig,
                        enhancedImage: processed.image,
                        engineLabel: config.engine.shortName
                    )
                } else {
                    ZoomableImageView(image: displayImage, onSingleTap: onSingleTap)
                }

                if slot.isUpscaling {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("正在执行 \(config.engine.shortName) 2x 超分...")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 78)
                }
            } else if let err = slot.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Button("重试") {
                        Task { await triggerLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("加载第 \(page.index + 1) 页...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(page.id)::\(config.cacheKey)") {
            await triggerLoad()
        }
    }

    private func triggerLoad() async {
        await slot.loadAndProcess(page: page, config: config)
        if let p = slot.processed {
            let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
            let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
            if let notice = p.notice {
                onStatusUpdate("\(orig) → \(out) · \(notice)")
            } else if p.appliedEngine == .off {
                onStatusUpdate("原图 \(orig)")
            } else {
                onStatusUpdate("\(p.appliedEngine.shortName) · \(orig) → \(out) · \(p.elapsedMs)ms")
            }
        }
    }
}

private struct VerticalMangaPageCell: View {
    let page: MangaPage
    let contentWidth: CGFloat
    let config: ImageUpscalerConfig
    let onStatusUpdate: (String) -> Void

    @StateObject private var slot = ReaderPageSlot()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let orig = slot.originalImage {
                let displayImage = slot.processed?.image ?? orig
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

                if slot.isUpscaling {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75).tint(.white)
                        Text("\(config.engine.shortName) 超分中")
                            .font(.caption2)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(10)
                }
            } else if let err = slot.errorMessage {
                VStack(spacing: 8) {
                    Text("第 \(page.index + 1) 页加载失败：\(err)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                    Button("重试") {
                        Task { await triggerLoad() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .background(Color.white.opacity(0.06))
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("加载第 \(page.index + 1) 页...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 380)
                .background(Color.white.opacity(0.05))
            }
        }
        .task(id: "\(page.id)::\(config.cacheKey)") {
            await triggerLoad()
        }
    }

    private func triggerLoad() async {
        await slot.loadAndProcess(page: page, config: config)
        if let p = slot.processed {
            let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
            let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
            if let notice = p.notice {
                onStatusUpdate("\(orig) → \(out) · \(notice)")
            } else if p.appliedEngine == .off {
                onStatusUpdate("原图 \(orig)")
            } else {
                onStatusUpdate("\(p.appliedEngine.shortName) · \(orig) → \(out) · \(p.elapsedMs)ms")
            }
        }
    }
}

/// 阅读器底部弹出的实时超分 & 排版配置面板
private struct ReaderUpscalerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var config: ImageUpscalerConfig
    @Binding var layoutMode: ReaderLayoutMode

    var body: some View {
        NavigationStack {
            Form {
                Section("阅读模式") {
                    Picker("排版方式", selection: $layoutMode) {
                        ForEach(ReaderLayoutMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("超分引擎") {
                    Picker("引擎选择", selection: $config.engine) {
                        ForEach(UpscalerEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if config.engine == .anime4k {
                    Section("Anime4K v4 多 Pass 管线预设") {
                        Picker("画质预设", selection: $config.anime4k.preset) {
                            ForEach(Anime4kPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        Toggle("细化线稿 (Anime4K_Thin_HQ)", isOn: $config.anime4k.thinLines)
                        Toggle("加深线稿 (Anime4K_Darken_HQ)", isOn: $config.anime4k.darkenLines)
                    }
                } else if config.engine == .waifu2x {
                    Section("Waifu2x CoreML 2x 模型预设") {
                        Picker("模型档位", selection: $config.waifu2x) {
                            ForEach(Waifu2xModelPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                    }
                }
            }
            .navigationTitle("画质超分与阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { dismiss() }
                }
            }
        }
    }
}
