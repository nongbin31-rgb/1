import SwiftUI
import UIKit

/// 画面滤镜全屏配置视图（1:1 像素级还原漫画阅读器滤镜列表与实时渲染面板）
public struct ReaderImageFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var store: AppStore

    /// 外部传入的当前漫画页面预览原图
    let previewSourceImage: UIImage

    /// 本地编辑中的滤镜配置（支持完成时提交或实时同步）
    @State private var localConfig: ImageFilterConfig
    /// 渲染后的预览图片
    @State private var filteredPreviewImage: UIImage?
    /// 是否正在渲染中
    @State private var isProcessing = false
    /// 渲染期间到达的最新待补渲配置（避免拖动滑块松手后预览停留在旧帧）
    @State private var pendingRenderConfig: ImageFilterConfig?
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
                            .padding(.top, safeAreaTop)
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
                            .padding(.top, safeAreaTop + 10)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                }

                // 长按对比原图提示悬浮胶囊
                if isPressingToCompare {
                    VStack {
                        Spacer().frame(height: max(safeAreaTop + 60, 80))
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
            // 返回按钮（自适应浅/深色卡片底）
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                    .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 4, x: 0, y: 2)
            }

            Spacer()

            // 标题
            Text("画面滤镜")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()

            // 完成按钮
            Button {
                store.imageFilterConfig = localConfig
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 4, x: 0, y: 2)
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
                            filterSectionGroup(title: "已启用") {
                                ForEach(Array(localConfig.activeFilterTypes.enumerated()), id: \.element) { index, type in
                                    if index > 0 {
                                        Divider()
                                            .padding(.leading, 56)
                                    }
                                    activeFilterRow(for: type)
                                }
                            }
                        }

                        // 2. 未启用分区
                        if !localConfig.inactiveFilterTypes.isEmpty {
                            filterSectionGroup(title: "未启用") {
                                ForEach(Array(localConfig.inactiveFilterTypes.enumerated()), id: \.element) { index, type in
                                    if index > 0 {
                                        Divider()
                                            .padding(.leading, 56)
                                    }
                                    inactiveFilterRow(for: type)
                                }
                            }
                        }

                        Spacer().frame(height: max(safeAreaBottom, 20) + 12)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }
                .frame(maxHeight: windowHeight * 0.44)
            }
        }
        .padding(.bottom, isSheetCollapsed ? safeAreaBottom : 0)
        .background(
            (colorScheme == .dark ? Color(red: 0.075, green: 0.075, blue: 0.09) : Color(uiColor: .systemGroupedBackground))
                .clipShape(RoundedCornerShape(radius: 22, corners: [.topLeft, .topRight]))
                .overlay(
                    RoundedCornerShape(radius: 22, corners: [.topLeft, .topRight])
                        .stroke(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.08), radius: 10, y: -3)
        )
    }

    /// 抽屉分组卡片容器（自动适配浅/深色卡片背景与描边）
    @ViewBuilder
    private func filterSectionGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            VStack(spacing: 0) {
                content()
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.04), radius: 6, y: 3)
        }
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
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 32, height: 32)
            }

            Spacer()

            Text("滤镜列表")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)

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
                        .foregroundStyle(.primary)

                    if !type.subtitle.isEmpty {
                        Text(type.subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
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
                    .foregroundStyle(.primary)

                Spacer()

                // 重置当前项参数为默认值
                Button {
                    var current = localConfig.config(for: type)
                    let def = ImageFilterItemConfig.default(for: type)
                    current.grayscaleIntensity = def.grayscaleIntensity
                    current.grayscaleContrast = def.grayscaleContrast
                    current.gammaValue = def.gammaValue
                    current.sharpnessValue = def.sharpnessValue
                    current.toneTemperature = def.toneTemperature
                    current.toneSaturation = def.toneSaturation
                    current.toneTintEnabled = def.toneTintEnabled
                    current.toneTintColor = def.toneTintColor
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
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("强度")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    Slider(value: binding.grayscaleIntensity, in: 0.0...1.0, step: 0.01)
                        .tint(.primary)

                    Text("\(Int(round(binding.grayscaleIntensity.wrappedValue * 100)))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("对比度")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    Slider(value: binding.grayscaleContrast, in: 0.5...2.0, step: 0.05)
                        .tint(.primary)

                    Text(String(format: "%.2f", binding.grayscaleContrast.wrappedValue))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }

        case .gamma:
            HStack(spacing: 12) {
                Text("伽马")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Slider(value: binding.gammaValue, in: 0.2...3.0, step: 0.05)
                    .tint(.primary)

                Text(String(format: "%.2f", binding.gammaValue.wrappedValue))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

        case .sharpen:
            HStack(spacing: 12) {
                Text("锐度")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Slider(value: binding.sharpnessValue, in: 0.0...2.0, step: 0.05)
                    .tint(.primary)

                Text(String(format: "%.2f", binding.sharpnessValue.wrappedValue))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }

        case .tone:
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    Text("冷暖")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    Slider(value: binding.toneTemperature, in: -1.0...1.0, step: 0.05)
                        .tint(.primary)

                    let val = binding.toneTemperature.wrappedValue
                    Text(val > 0.05 ? "暖 \(Int(round(val * 100)))" : (val < -0.05 ? "冷 \(Int(round(-val * 100)))" : "中性"))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 12) {
                    Text("饱和度")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    Slider(value: binding.toneSaturation, in: 0.0...2.0, step: 0.05)
                        .tint(.primary)

                    Text("\(Int(round(binding.toneSaturation.wrappedValue * 100)))%")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                HStack(spacing: 10) {
                    Text("染纸色")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .leading)

                    // 原色（关闭染纸）
                    Button {
                        var updated = binding.wrappedValue
                        updated.toneTintEnabled = false
                        binding.wrappedValue = updated
                        impactFeedback.impactOccurred()
                    } label: {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 22, height: 22)
                            .overlay(
                                Image(systemName: "line.diagonal")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.secondary)
                            )
                            .overlay(
                                Circle()
                                    .stroke(!binding.wrappedValue.toneTintEnabled ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: !binding.wrappedValue.toneTintEnabled ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)

                    // 护眼预设色圆点
                    ForEach(FilterRGBColor.presets, id: \.name) { preset in
                        let isSelected = binding.wrappedValue.toneTintEnabled && binding.wrappedValue.toneTintColor == preset.color
                        Button {
                            var updated = binding.wrappedValue
                            updated.toneTintEnabled = true
                            updated.toneTintColor = preset.color
                            binding.wrappedValue = updated
                            impactFeedback.impactOccurred()
                        } label: {
                            Circle()
                                .fill(preset.color.swiftUIColor)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }

                    Spacer()

                    // 自定义任意护眼染纸色
                    ColorPicker(
                        "",
                        selection: Binding<Color>(
                            get: { binding.wrappedValue.toneTintColor.swiftUIColor },
                            set: { newColor in
                                var updated = binding.wrappedValue
                                updated.toneTintEnabled = true
                                updated.toneTintColor = FilterRGBColor(swiftUIColor: newColor)
                                binding.wrappedValue = updated
                            }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
            }

        case .shadow:
            HStack(spacing: 12) {
                Text("暗部")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .leading)

                Slider(value: binding.shadowAmount, in: -1.0...1.0, step: 0.05)
                    .tint(.primary)

                let val = binding.shadowAmount.wrappedValue
                Text(val < -0.05 ? "加深 \(Int(round(-val * 100)))" : (val > 0.05 ? "提亮 \(Int(round(val * 100)))" : "标准"))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
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

    // MARK: - 实时渲染预览图（带末尾帧补渲，确保快速拖动滑块松手后必渲染最新参数）

    private func renderFilteredPreview(for overrideConfig: ImageFilterConfig? = nil) {
        let configToRender = overrideConfig ?? localConfig
        if isProcessing {
            pendingRenderConfig = configToRender
            return
        }
        isProcessing = true
        pendingRenderConfig = nil

        let sourceImage = previewSourceImage
        Task.detached(priority: .userInteractive) {
            let result = ImageFilterPipeline.shared.process(
                image: sourceImage,
                cacheKey: "filter_preview",
                config: configToRender
            )
            await MainActor.run {
                self.filteredPreviewImage = result
                self.isProcessing = false
                if let nextConfig = self.pendingRenderConfig {
                    self.pendingRenderConfig = nil
                    self.renderFilteredPreview(for: nextConfig)
                }
            }
        }
    }

    // MARK: - 安全区域安全边距解析（物理硬件级基线兜底）

    private var safeAreaTop: CGFloat {
        max(safeAreaInsetsResolved.top, hardwareBaselineSafeAreaTop)
    }

    private var safeAreaBottom: CGFloat {
        max(safeAreaInsetsResolved.bottom, hardwareBaselineSafeAreaBottom)
    }

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

        let screenBounds = UIScreen.main.bounds
        let isPortrait = screenBounds.height >= screenBounds.width
        if isPortrait {
            return UIEdgeInsets(top: hardwareBaselineSafeAreaTop, left: 0, bottom: hardwareBaselineSafeAreaBottom, right: 0)
        } else {
            return UIEdgeInsets(top: 0, left: hardwareBaselineSafeAreaTop, bottom: 21, right: hardwareBaselineSafeAreaTop)
        }
    }

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

    private var hardwareBaselineSafeAreaBottom: CGFloat {
        let maxDimension = max(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
        return maxDimension >= 812 ? 34 : 12
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
