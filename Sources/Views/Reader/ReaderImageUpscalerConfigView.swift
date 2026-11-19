import SwiftUI

/// 画质增强配置与实时对比交互视图（100% 复刻可达阅读器 ReaderImageUpscalerConfigView）
public struct ReaderImageUpscalerConfigView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    /// 用于实时预览的原始参考图像
    public let imageForPreview: UIImage

    // MARK: - 内部状态（完全对齐原版字段）

    @State private var isEnhancing: Bool = false
    @State private var isConfigPanelHided: Bool = false
    @State private var upscaledImage: UIImage? = nil
    @State private var upscaleError: String? = nil
    @State private var performanceResult: String? = nil
    @State private var revealPercent: CGFloat = 0.5 // 0.0 ~ 1.0 分屏对比滑块位置
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var showingAnime4KFAQ: Bool = false
    @State private var showingUpscalerFAQ: Bool = false

    public init(imageForPreview: UIImage) {
        self.imageForPreview = imageForPreview
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // 1. 核心画面区：支持缩放、拖拽、点击隐藏与原图/超分分屏滑动对比
                GeometryReader { geo in
                    let size = geo.size
                    ZStack {
                        // 底层：原图
                        Image(uiImage: imageForPreview)
                            .resizable()
                            .scaledToFit()
                            .frame(width: size.width, height: size.height)

                        // 顶层：超分后图像（根据 revealPercent 裁剪遮罩）
                        if let upscaled = upscaledImage {
                            Image(uiImage: upscaled)
                                .resizable()
                                .scaledToFit()
                                .frame(width: size.width, height: size.height)
                                .clipShape(SplitRevealShape(percent: revealPercent))

                            // 分屏分割线与拖动手柄
                            SplitDividerView(
                                percent: $revealPercent,
                                containerWidth: size.width,
                                containerHeight: size.height
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
                                    Text("AI 超分渲染中...")
                                        .font(.subheadline)
                                        .foregroundColor(.white)
                                }
                                .padding(24)
                                .background(.ultraThinMaterial)
                                .cornerRadius(14)
                            }
                        }
                    }
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in
                                scale = max(0.8, min(4.0, val))
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { val in
                                if scale > 1.05 {
                                    offset = val.translation
                                }
                            }
                            .onEnded { _ in
                                if scale <= 1.05 {
                                    withAnimation(.spring()) {
                                        offset = .zero
                                        scale = 1.0
                                    }
                                }
                            }
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isConfigPanelHided.toggle()
                        }
                    }
                }

                // 2. 顶部/底部悬浮提示与配置面板
                VStack(spacing: 0) {
                    // 性能耗时浮层
                    if let perf = performanceResult, !isConfigPanelHided {
                        HStack {
                            Image(systemName: "timer")
                            Text(perf)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75))
                        .cornerRadius(20)
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

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
            .sheet(isPresented: $showingUpscalerFAQ) {
                upscalerFAQSheet
            }
            .sheet(isPresented: $showingAnime4KFAQ) {
                anime4kFAQSheet
            }
            .task {
                // 首次进入时自动运行一次预览
                await runPreviewEnhance()
            }
        }
    }

    // MARK: - 底部控制卡片

    private var configSheetPanel: some View {
        VStack(spacing: 14) {
            // 全局开启开关
            Toggle("启用 AI 画质增强（会有额外功耗）", isOn: $store.enableImageUpscaler)
                .font(.headline)
                .foregroundColor(.white)
                .tint(.blue)

            Text("目前仅会增强宽高均在 2500px 内的图像，超过该大小画质增强的意义不大。")
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

            // 重新预览效果按钮
            Button {
                Task { await runPreviewEnhance() }
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text("预览效果")
                        .fontWeight(.semibold)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.blue)
                .cornerRadius(10)
            }
            .disabled(isEnhancing)
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

    private func runPreviewEnhance() async {
        guard !isEnhancing else { return }
        isEnhancing = true
        upscaleError = nil

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let result: UIImage
            switch store.upscalerConfig.model {
            case .anime4k:
                result = try await Anime4kService.shared.enhance(
                    image: imageForPreview,
                    config: store.upscalerConfig.anime4k
                )
            case .waifu2x:
                result = try await Waifu2xService.shared.enhance(
                    image: imageForPreview,
                    model: store.upscalerConfig.waifu2x
                )
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            await MainActor.run {
                self.upscaledImage = result
                self.isEnhancing = false
                let secStr = String(format: "%.3f", elapsed)
                self.performanceResult = "运行时长：\(secStr)s，可放大查看细节，单击图像隐藏面板"
            }
        } catch {
            await MainActor.run {
                self.isEnhancing = false
                self.upscaleError = error.localizedDescription
                self.performanceResult = "超分失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - FAQ 弹窗

    private var upscalerFAQSheet: some View {
        NavigationStack {
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
                        Text("3. 2500px 尺寸保护机制")
                            .font(.headline)
                        Text("由于高倍率超分会成倍放大像素显存，当单张原图单边超过 2500px 时，系统会自动旁路跳过超分，杜绝 iOS 系统 Jetsam 强杀应用后台。")
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
    }

    private var anime4kFAQSheet: some View {
        NavigationStack {
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
    }
}

// MARK: - 分屏滑动对比辅助形状与手柄组件

private struct SplitRevealShape: Shape {
    var percent: CGFloat // 0.0 ~ 1.0

    var animatableData: CGFloat {
        get { percent }
        set { percent = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let splitX = rect.width * percent
        p.addRect(CGRect(x: splitX, y: 0, width: rect.width - splitX, height: rect.height))
        return p
    }
}

private struct SplitDividerView: View {
    @Binding var percent: CGFloat
    let containerWidth: CGFloat
    let containerHeight: CGFloat

    var body: some View {
        let xPos = containerWidth * percent
        ZStack {
            // 垂直分割白线
            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: containerHeight)
                .shadow(color: .black.opacity(0.6), radius: 2)

            // 圆形拖拽手柄
            Circle()
                .fill(Color.white)
                .frame(width: 32, height: 32)
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
        .gesture(
            DragGesture()
                .onChanged { val in
                    let newPercent = val.location.x / containerWidth
                    percent = max(0.02, min(0.98, newPercent))
                }
        )
    }
}
