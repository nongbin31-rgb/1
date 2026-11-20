import SwiftUI

/// 画质增强配置与实时对比交互视图（100% 复刻可达阅读器 ReaderImageUpscalerConfigView）
public struct ReaderImageUpscalerConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    /// 用于实时预览的原始参考图像
    public let imageForPreview: UIImage

    // MARK: - 内部状态（完全对齐原版字段）

    @State private var isEnhancing: Bool = false
    @State private var enhanceProgressText: String = ""
    @State private var previewTask: Task<Void, Never>? = nil
    @State private var previewGeneration: UInt64 = 0
    @State private var isConfigPanelHided: Bool = false
    @State private var upscaledImage: UIImage? = nil
    @State private var upscaleError: String? = nil
    @State private var performanceResult: String? = nil
    @State private var revealPercent: CGFloat = 0.5 // 0.0 ~ 1.0 分屏对比滑块位置
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0
    @State private var showingAnime4KFAQ: Bool = false
    @State private var showingUpscalerFAQ: Bool = false

    /// 真实有效的预览图像（具备自动兜底回退样张机制）
    private var activeImage: UIImage {
        if imageForPreview.size.width > 0 {
            return imageForPreview
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
        return imageForPreview
    }

    public init(imageForPreview: UIImage) {
        self.imageForPreview = imageForPreview
    }

    public var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. 核心画面区：仅缩放画面本身，分屏对比滑动条固定于屏幕视口，放大后依然全屏顺滑可拖
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let height = max(geo.size.height, 1)
                    let dividerX = max(16, min(width - 16, width * revealPercent))

                    ZStack {
                        // 底层：原图
                        if activeImage.size.width > 0 {
                            Image(uiImage: activeImage)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(zoomScale)
                                .frame(width: width, height: height)
                                .clipped()
                        } else {
                            VStack(spacing: 12) {
                                ProgressView().tint(.white)
                                Text("正在准备页面图像...")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }

                        // 顶层：超分后图像（根据 dividerX 裁剪右侧对比区域）
                        if let upscaled = upscaledImage {
                            Image(uiImage: upscaled)
                                .resizable()
                                .scaledToFit()
                                .scaleEffect(zoomScale)
                                .frame(width: width, height: height)
                                .clipped()
                                .clipShape(SplitRevealShape(splitX: dividerX))

                            // 分屏分割线与拖动手柄（独立于图片缩放层，始终贴合视口坐标）
                            SplitDividerView(
                                xPos: dividerX,
                                containerHeight: height
                            )
                        }

                        // 正在推理中的 HUD 遮罩
                        if isEnhancing {
                            ZStack {
                                Color.black.opacity(0.4)
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(1.4)
                                    Text(enhanceProgressText.isEmpty ? "AI 超分渲染中..." : "AI 超分渲染中... \(enhanceProgressText)")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                }
                                .padding(24)
                                .background(.ultraThinMaterial)
                                .cornerRadius(14)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isConfigPanelHided.toggle()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { val in
                                guard upscaledImage != nil else { return }
                                revealPercent = max(0.02, min(0.98, val.location.x / width))
                            }
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { val in
                                zoomScale = max(1.0, min(4.0, lastZoomScale * val))
                            }
                            .onEnded { _ in
                                lastZoomScale = zoomScale
                            }
                    )
                }

                // 2. 顶部/底部悬浮提示与配置面板
                VStack(spacing: 0) {
                    // 性能耗时 / 报错浮层（支持多行完整展示，避免底层报错被截断）
                    if let perf = performanceResult, !isConfigPanelHided {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: upscaleError == nil ? "timer" : "exclamationmark.triangle.fill")
                                .foregroundColor(upscaleError == nil ? .white.opacity(0.9) : .orange)
                            Text(perf)
                                .font(.caption)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                        .foregroundColor(.white.opacity(0.95))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(upscaleError == nil ? Color.black.opacity(0.75) : Color.red.opacity(0.78))
                        .cornerRadius(16)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Spacer()

                    // 底部控制面板（对齐原版 ReaderImageUpscalerConfigView）
                    if !isConfigPanelHided {
                        configSheetPanel
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .navigationTitle("画质增强 - 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        showingUpscalerFAQ = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.white)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("画质增强 - 配置")
                        .font(.headline)
                        .foregroundColor(.white)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .compatToolbarBackgroundDark()
            .sheet(isPresented: $showingUpscalerFAQ) {
                upscalerFAQSheet
            }
            .sheet(isPresented: $showingAnime4KFAQ) {
                anime4kFAQSheet
            }
            .task {
                // 首次进入时自动运行一次预览
                triggerPreviewEnhance()
            }
            .onDisappear {
                previewTask?.cancel()
                previewTask = nil
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 底部控制卡片

    private var configSheetPanel: some View {
        VStack(spacing: 14) {
            // 全局开启开关
            Toggle("启用 AI 画质增强（会有额外功耗）", isOn: $store.enableImageUpscaler)
                .font(.headline)
                .foregroundColor(.white)
                .tint(.blue)

            Text(
                store.upscalerConfig.bypassSizeLimit
                    ? "已解除 1200 万总像素限制，超巨图可能触发高内存占用或闪退（Anime4K 仍受 Metal 单边 8192px 硬件上限约束）。"
                    : "默认按总像素上限（1200 万像素）智能保护，支持 800×8000 等条漫长图超分；需要处理更巨幅原图可开启下方解除开关。"
            )
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().background(Color.white.opacity(0.2))

            // 引擎切换：Anime4K / Waifu2x
            Picker("超分引擎", selection: $store.upscalerConfig.model) {
                ForEach(ImageUpscalerModel.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)

            // 各引擎专属参数
            if store.upscalerConfig.model == .anime4k {
                anime4kSettingsSection
            } else {
                waifu2xSettingsSection
            }

            // 增强后平滑淡入
            Toggle("增强后平滑淡入", isOn: $store.transitionAfterImageUpscaled)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .tint(.blue)

            // 解除总像素尺寸限制开关
            Toggle("解除超分尺寸限制（慎用）", isOn: $store.upscalerConfig.bypassSizeLimit)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .tint(.orange)

            // 重新预览效果按钮（点击时自动取消上一次未完成的推理，立刻按新参数重算）
            Button {
                triggerPreviewEnhance()
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text(isEnhancing ? "重新预览" : "预览效果")
                        .font(.body.weight(.semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.blue)
                .cornerRadius(10)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    // MARK: - Anime4K 配置项

    private var anime4kSettingsSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("预设模式")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button {
                    showingAnime4KFAQ = true
                } label: {
                    HStack(spacing: 4) {
                        Text("模式区别")
                            .font(.caption)
                        Image(systemName: "info.circle")
                            .font(.caption)
                    }
                    .foregroundColor(.blue)
                }
            }

            Picker("Anime4K 预设", selection: $store.upscalerConfig.anime4k.preset) {
                ForEach(Anime4kPreset.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)

            HStack {
                Toggle("细化线条", isOn: $store.upscalerConfig.anime4k.thinLines)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .tint(.blue)
                Spacer(minLength: 20)
                Toggle("线条加黑", isOn: $store.upscalerConfig.anime4k.darkenLines)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                    .tint(.blue)
            }
        }
    }

    // MARK: - Waifu2x 配置项

    private var waifu2xSettingsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("预设模型")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
            }

            Picker("Waifu2x 模型", selection: $store.upscalerConfig.waifu2x) {
                ForEach(Waifu2xModel.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.1))
            .cornerRadius(8)
        }
    }

    // MARK: - 执行单次超分并更新状态

    private func triggerPreviewEnhance() {
        previewTask?.cancel()
        previewGeneration &+= 1
        let gen = previewGeneration
        previewTask = Task {
            await runPreviewEnhance(generation: gen)
        }
    }

    private func runPreviewEnhance(generation: UInt64) async {
        let target = activeImage
        guard target.size.width > 0, target.cgImage != nil || target.ciImage != nil else {
            await MainActor.run {
                guard self.previewGeneration == generation else { return }
                self.isEnhancing = false
                self.upscaleError = "当前页面图片尚未加载完成，请稍候再试"
                self.performanceResult = "超分等待中: 正在加载原图"
            }
            return
        }

        await MainActor.run {
            guard self.previewGeneration == generation else { return }
            self.isEnhancing = true
            self.enhanceProgressText = ""
            self.upscaleError = nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result: UIImage
            switch store.upscalerConfig.model {
            case .anime4k:
                result = try await Anime4kService.shared.enhance(
                    image: target,
                    config: store.upscalerConfig.anime4k,
                    bypassSizeLimit: store.upscalerConfig.bypassSizeLimit
                )
            case .waifu2x:
                result = try await Waifu2xService.shared.enhance(
                    image: target,
                    model: store.upscalerConfig.waifu2x,
                    bypassSizeLimit: store.upscalerConfig.bypassSizeLimit,
                    progress: { pct in
                        DispatchQueue.main.async {
                            guard self.previewGeneration == generation else { return }
                            self.enhanceProgressText = pct
                        }
                    }
                )
            }

            guard !Task.isCancelled else { return }
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            await MainActor.run {
                guard self.previewGeneration == generation else { return }
                self.upscaledImage = result
                self.isEnhancing = false
                self.enhanceProgressText = ""
                let secStr = String(format: "%.3f", elapsed)
                self.performanceResult = "运行时长：\(secStr)s，可放大查看细节，单击图像隐藏面板"
            }
        } catch is CancellationError {
            await MainActor.run {
                guard self.previewGeneration == generation else { return }
                self.isEnhancing = false
                self.enhanceProgressText = ""
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.previewGeneration == generation else { return }
                self.isEnhancing = false
                self.enhanceProgressText = ""
                self.upscaleError = error.localizedDescription
                self.performanceResult = "超分失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - FAQ 弹窗

    private var upscalerFAQSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("关于 AI 画质增强")
                        .font(.title2.bold())
                    Text("本阅读器内置了与《可达阅读器》完全一致的端侧双轨超分辨率管线：")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Anime4K (Metal 实时级)")
                            .font(.headline)
                        Text("基于 GPU 片元着色器管线，毫秒级即时放大，专门针对日漫二次元黑白与彩漫分镜进行了线条恢复与抗锯齿处理，功耗极低，推荐日常连续翻页使用。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("2. Waifu2x (CoreML 深度卷积级)")
                            .font(.headline)
                        Text("依托 Apple Neural Engine (ANE) 执行 7 层深度卷积网络，提供印刷级无损放大与颗粒降噪，适合大画幅插画与精细画集阅览。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("3. 智能总像素保护与解除限制开关")
                            .font(.headline)
                        Text("默认使用 1200 万总像素上限替代旧版单边 2500px 截断，既能放行 800×8000 等低清条漫长图，又能配合显存释放与零拷贝机制防爆内存。若需对更巨幅原图超分，可手动开启「解除超分尺寸限制」（Anime4K 仍受 Apple GPU Metal 单边 8192px 纹理硬件上限约束，超长单边可切换 Waifu2x）。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            .navigationTitle("画质增强说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("知道了") { showingUpscalerFAQ = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var anime4kFAQSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Anime4K 各个模式的区别")
                        .font(.title2.bold())

                    Group {
                        Text("• Mode A + A (超分 + 超分)")
                            .font(.headline)
                        Text("适用于高质量原图，线条锐化与细节放大两遍，轮廓最清晰。")
                            .font(.subheadline).foregroundColor(.secondary)

                        Text("• Mode B + B (软线条 + 超分)")
                            .font(.headline)
                        Text("适用于线条柔和的水彩漫、灰度分镜，有效抑制边缘振铃光晕效应。")
                            .font(.subheadline).foregroundColor(.secondary)

                        Text("• Mode C + A (降噪 + 超分)")
                            .font(.headline)
                        Text("适用于早期扫描版或带有严重 JPEG 压缩块效应的泛黄老漫画。")
                            .font(.subheadline).foregroundColor(.secondary)

                        Text("• HQ 旗舰后缀")
                            .font(.headline)
                        Text("启用全尺寸 UL/UUL 深层算子，计算量更大，呈现极高精细度。")
                            .font(.subheadline).foregroundColor(.secondary)
                    }

                    Link(destination: ImageUpscalerConfig.anime4kTipURL) {
                        HStack {
                            Image(systemName: "safari")
                            Text("查看 bloc97/Anime4K 官方进阶指南")
                        }
                        .foregroundColor(.blue)
                        .padding(.top, 8)
                    }
                }
                .padding()
            }
            .navigationTitle("Anime4K 模式区别")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { showingAnime4KFAQ = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 分屏滑动对比辅助形状与手柄组件

private struct SplitRevealShape: Shape {
    var splitX: CGFloat

    var animatableData: CGFloat {
        get { splitX }
        set { splitX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let clampedX = max(0, min(rect.width, splitX))
        p.addRect(CGRect(x: clampedX, y: 0, width: rect.width - clampedX, height: rect.height))
        return p
    }
}

private struct SplitDividerView: View {
    let xPos: CGFloat
    let containerHeight: CGFloat

    var body: some View {
        ZStack {
            // 垂直分割白线
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: containerHeight)
                .shadow(color: .black.opacity(0.6), radius: 2)

            // 圆形拖拽手柄
            Circle()
                .fill(Color.white)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.4), radius: 4)
                .overlay(
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 10, weight: .bold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.black)
                )
        }
        .position(x: xPos, y: containerHeight / 2)
        .allowsHitTesting(false)
    }
}
