import SwiftUI
import UIKit

/// 画面滤镜全屏配置视图（1:1 像素级还原漫画阅读器滤镜列表与实时渲染面板）
public struct ReaderImageFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore

    /// 外部传入的当前漫画页面预览原图
    let previewSourceImage: UIImage

    /// 本地编辑中的滤镜配置（支持完成时提交或实时同步）
    @State private var localConfig: ImageFilterConfig
    /// 渲染后的预览图片
    @State private var filteredPreviewImage: UIImage?
    /// 是否正在渲染中
    @State private var isProcessing = false
    /// 当前是否处于全屏大图模式（折叠底部抽屉）
    @State private var isFullScreenPreview = false
    /// 是否正在按住屏幕临时对比原图
    @State private var isPressingToCompare = false
    /// 滤镜列表抽屉是否完全折叠
    @State private var isSheetCollapsed = false

    /// 触觉反馈发生器
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    public init(previewImage: UIImage, initialConfig: ImageFilterConfig? = nil) {
        self.previewSourceImage = previewImage
        // 若外部未显式传 initialConfig，则在 onAppear 时绑定 store.imageFilterConfig
        _localConfig = State(initialValue: initialConfig ?? ImageFilterConfig.defaultConfig())
    }

    public var body: some View {
        GeometryReader { windowGeo in
            ZStack(alignment: .top) {
                // 背景：标准浅灰沉浸背景
                Color(uiColor: .systemGroupedBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // 顶部导航栏（全屏预览时自动淡出）
                    if !isFullScreenPreview {
                        topNavigationBar
                            .padding(.top, windowGeo.safeAreaInsets.top)
                            .background(Color(uiColor: .systemGroupedBackground))
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // 中间画面预览展示区域
                    previewArea(windowSize: windowGeo.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // 底部滤镜列表半屏抽屉面板
                    if !isFullScreenPreview {
                        bottomFilterDrawer(windowHeight: windowGeo.size.height)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }

                // 全屏沉浸预览模式下，右上角浮动恢复按钮
                if isFullScreenPreview {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                    isFullScreenPreview = false
                                }
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 40, height: 40)
                                    .background(Color.black.opacity(0.65), in: Circle())
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                            }
                            .padding(.trailing, 20)
                            .padding(.top, windowGeo.safeAreaInsets.top + 10)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // 长按对比原图提示悬浮胶囊
                if isPressingToCompare {
                    VStack {
                        Spacer().frame(height: max(windowGeo.safeAreaInsets.top + 60, 80))
                        HStack(spacing: 6) {
                            Image(systemName: "eye.fill")
                                .font(.caption.bold())
                            Text("已显示原始画面 (松开恢复滤镜)")
                                .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.75), in: Capsule())
                        .shadow(radius: 6)
                        .transition(.scale.combined(with: .opacity))
                        Spacer()
                    }
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            localConfig = store.imageFilterConfig
            renderFilteredPreview()
        }
        .onChange(of: localConfig) { newConfig in
            renderFilteredPreview()
            // 实时同步至全局 store，使外部阅读器即刻感知
            store.imageFilterConfig = newConfig
        }
    }

    // MARK: - 顶部导航栏

    private var topNavigationBar: some View {
        HStack {
            // 返回按钮（圆角半透明白底）
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 36, height: 36)
                    .background(Color.white, in: Circle())
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }

            Spacer()

            // 标题
            Text("画面滤镜")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black)

            Spacer()

            // 完成按钮
            Button {
                store.imageFilterConfig = localConfig
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
                    .shadow(color: .black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 漫画预览区域

    @ViewBuilder
    private func previewArea(windowSize: CGSize) -> some View {
        ZStack(alignment: .bottomTrailing) {
            // 显示图片（处理后滤镜图 或 原图）
            let displayImg = isPressingToCompare ? previewSourceImage : (filteredPreviewImage ?? previewSourceImage)

            GeometryReader { geo in
                ZStack {
                    Color.clear
                    Image(uiImage: displayImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .clipped()
                }
            }
            .contentShape(Rectangle())
            // 长按对比手势
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressingToCompare {
                            isPressingToCompare = true
                            impactFeedback.impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        isPressingToCompare = false
                    }
            )

            // 右下角全屏预览展开/折叠对角箭头按钮
            if !isFullScreenPreview {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isFullScreenPreview = true
                    }
                    impactFeedback.impactOccurred()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .padding(14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部“滤镜列表”抽屉面板

    @ViewBuilder
    private func bottomFilterDrawer(windowHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 抽屉把手 / 标题栏
            drawerHeader

            if !isSheetCollapsed {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 1. 已启用分区（若有启用的滤镜则展示）
                        if !localConfig.activeFilterTypes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("已启用")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)

                                VStack(spacing: 0) {
                                    ForEach(Array(localConfig.activeFilterTypes.enumerated()), id: \.element) { index, type in
                                        if index > 0 {
                                            Divider()
                                                .padding(.leading, 56)
                                        }
                                        activeFilterRow(for: type)
                                    }
                                }
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
                            }
                        }

                        // 2. 未启用分区（严格还原用户上传截图！）
                        if !localConfig.inactiveFilterTypes.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("未启用")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 16)

                                VStack(spacing: 0) {
                                    ForEach(Array(localConfig.inactiveFilterTypes.enumerated()), id: \.element) { index, type in
                                        if index > 0 {
                                            Divider()
                                                .padding(.leading, 56)
                                        }
                                        inactiveFilterRow(for: type)
                                    }
                                }
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.04), radius: 6, y: 3)
                            }
                        }

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                .frame(maxHeight: windowHeight * 0.44)
            }
        }
        .background(
            Color(uiColor: .systemGroupedBackground)
                .clipShape(RoundedCornerShape(radius: 22, corners: [.topLeft, .topRight]))
                .shadow(color: .black.opacity(0.08), radius: 10, y: -3)
        )
    }

    /// 抽屉标题栏
    private var drawerHeader: some View {
        HStack {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSheetCollapsed.toggle()
                }
                impactFeedback.impactOccurred()
            } label: {
                Image(systemName: isSheetCollapsed ? "chevron.up" : "chevron.down")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black.opacity(0.8))
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Text("滤镜列表")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.black)

            Spacer()

            // 占位对称
            Color.clear.frame(width: 32, height: 32)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSheetCollapsed.toggle()
            }
        }
    }

    // MARK: - 未启用行项（完全还原截图视觉）

    @ViewBuilder
    private func inactiveFilterRow(for type: ImageFilterType) -> some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                localConfig.enableFilter(type)
            }
            impactFeedback.impactOccurred()
        } label: {
            HStack(spacing: 14) {
                // 绿色加号图标
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(red: 0.22, green: 0.78, blue: 0.35)) // iOS 纯正系统绿

                // 滤镜专属图标
                filterTypeIcon(for: type)
                    .frame(width: 26, height: 26)

                // 标题与说明文本
                HStack(spacing: 4) {
                    Text(type.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.black)

                    if !type.subtitle.isEmpty {
                        Text(type.subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(.black.opacity(0.85))
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 已启用行项（带减号停用与参数滑动调节）

    @ViewBuilder
    private func activeFilterRow(for type: ImageFilterType) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                // 红色减号图标（点击停用）
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        localConfig.disableFilter(type)
                    }
                    impactFeedback.impactOccurred()
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)

                // 滤镜专属图标
                filterTypeIcon(for: type)
                    .frame(width: 26, height: 26)

                // 标题
                Text(type.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)

                Spacer()

                // 重置当前项参数为默认值
                Button {
                    var current = localConfig.config(for: type)
                    let def = ImageFilterItemConfig.default(for: type)
                    current.grayscaleIntensity = def.grayscaleIntensity
                    current.gammaValue = def.gammaValue
                    current.sharpnessValue = def.sharpnessValue
                    current.toneTemperature = def.toneTemperature
                    current.shadowAmount = def.shadowAmount
                    localConfig.updateConfig(current)
                    impactFeedback.impactOccurred()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }

            // 参数滑块控制器
            filterParameterSlider(for: type)
                .padding(.leading, 38)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 滤镜参数调节滑块

    @ViewBuilder
    private func filterParameterSlider(for type: ImageFilterType) -> some View {
        let binding = Binding<ImageFilterItemConfig>(
            get: { localConfig.config(for: type) },
            set: { localConfig.updateConfig($0) }
        )

        switch type {
        case .grayscale:
            HStack(spacing: 12) {
                Text("强度")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: binding.grayscaleIntensity, in: 0.0...1.0, step: 0.05)
                    .tint(.black)

                Text("\(Int(binding.grayscaleIntensity.wrappedValue * 100))%")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

        case .gamma:
            HStack(spacing: 12) {
                Text("伽马")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: binding.gammaValue, in: 0.4...2.4, step: 0.05)
                    .tint(.black)

                Text(String(format: "%.2f", binding.gammaValue.wrappedValue))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

        case .sharpen:
            HStack(spacing: 12) {
                Text("锐度")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: binding.sharpnessValue, in: 0.1...2.0, step: 0.05)
                    .tint(.black)

                Text(String(format: "%.2f", binding.sharpnessValue.wrappedValue))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

        case .tone:
            HStack(spacing: 12) {
                Text("冷暖")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: binding.toneTemperature, in: -1.0...1.0, step: 0.05)
                    .tint(.black)

                let val = binding.toneTemperature.wrappedValue
                Text(val > 0.05 ? "暖 \(Int(val * 100))" : (val < -0.05 ? "冷 \(Int(-val * 100))" : "中性"))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

        case .shadow:
            HStack(spacing: 12) {
                Text("暗部")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .leading)

                Slider(value: binding.shadowAmount, in: -1.0...1.0, step: 0.05)
                    .tint(.black)

                let val = binding.shadowAmount.wrappedValue
                Text(val < -0.05 ? "加深 \(Int(-val * 100))" : (val > 0.05 ? "提亮 \(Int(val * 100))" : "标准"))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    // MARK: - 滤镜图标渲染（完全匹配截图的造型）

    @ViewBuilder
    private func filterTypeIcon(for type: ImageFilterType) -> some View {
        switch type {
        case .grayscale:
            // 三环相扣图标（截图里的品字形三圆相交）
            VennRingsIcon()
                .foregroundStyle(.secondary)

        case .gamma:
            // 仪表刻度/光圈图标
            Image(systemName: "gauge.with.needle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)

        case .sharpen:
            // 上下折线箭头
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)

        case .tone:
            // 三滑块
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 19))
                .foregroundStyle(.secondary)

        case .shadow:
            // 双山峦
            Image(systemName: "mountain.2")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 实时渲染预览图

    private func renderFilteredPreview() {
        guard !isProcessing else { return }
        isProcessing = true
        let configToRender = localConfig

        Task.detached(priority: .userInteractive) {
            let result = ImageFilterPipeline.shared.process(
                image: self.previewSourceImage,
                cacheKey: "filter_preview",
                config: configToRender
            )
            await MainActor.run {
                self.filteredPreviewImage = result
                self.isProcessing = false
            }
        }
    }
}

// MARK: - 三环相扣矢量绘制图标（1:1 还原截图中黑白滤镜的三圈交叠造型）
private struct VennRingsIcon: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let r = w * 0.32
            let centerTop = CGPoint(x: w * 0.5, y: w * 0.36)
            let centerLeft = CGPoint(x: w * 0.34, y: w * 0.64)
            let centerRight = CGPoint(x: w * 0.66, y: w * 0.64)

            ZStack {
                Circle()
                    .stroke(lineWidth: 1.5)
                    .frame(width: r * 2, height: r * 2)
                    .position(centerTop)

                Circle()
                    .stroke(lineWidth: 1.5)
                    .frame(width: r * 2, height: r * 2)
                    .position(centerLeft)

                Circle()
                    .stroke(lineWidth: 1.5)
                    .frame(width: r * 2, height: r * 2)
                    .position(centerRight)
            }
        }
    }
}

// MARK: - 针对特定角的圆角辅助 Shape
private struct RoundedCornerShape: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}
