//
//  ReaderBackgroundPickerSheet.swift
//  KedaOnlineReader
//
//  复刻自：可达阅读器 (Kedamanga) 阅读背景与纸质纹理高级调控面板
//  支持 5 大背景模式、6 种真实物理纸张材质选择、透明度无级调节与中缝阴影控制
//

import SwiftUI

public struct ReaderBackgroundPickerSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    // 1. 顶部模式选择器 (5 大模式)
                    backgroundModeSection

                    // 2. 纸张纹理专属配置卡片 (仅在纹理模式下呈现)
                    if store.preferredReaderBackground == .texture {
                        texturePickerSection
                        textureScopeSection
                        textureOpacitySection
                    }

                    // 3. 沉浸式模式说明卡片 (仅在沉浸模式下呈现)
                    if store.preferredReaderBackground == .immersive {
                        immersiveInfoSection
                    }

                    // 4. 书脊中缝立体光影控制
                    spineShadowSection

                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .navigationTitle("阅读背景与纸质")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .compatPresentationDetentsFractions([0.68, 0.92])
        .compatPresentationDragIndicatorVisible()
    }

    // MARK: - 1. 背景模式分段网格
    private var backgroundModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("背景模式")
                .font(.headline)
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                ForEach(ReaderBackground.allCases) { mode in
                    let isSelected = store.preferredReaderBackground == mode
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.preferredReaderBackground = mode
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: mode.systemIcon)
                                .font(.system(size: 18, weight: isSelected ? .bold : .regular))
                            Text(mode.title)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 2. 真实物理纸张材质选择网格 (严格等宽对齐网格)
    private var texturePickerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("真实材质纹理")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("6 款真实纸张与材质")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 12
            ) {
                ForEach(ReaderTextureType.allCases) { item in
                    textureCardView(for: item)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func textureCardView(for item: ReaderTextureType) -> some View {
        let isSelected = store.readerTextureType == item
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                store.readerTextureType = item
            }
        } label: {
            VStack(spacing: 6) {
                // 材质缩略图展示区域：严格定高定宽，底层铺专属原生物理纸浆底色，图片通过 ZStack 载入并双重裁切
                ZStack {
                    Color.white
                    if store.readerTextureTintOpacity > 0.001 {
                        item.basePaperSwiftUIColor
                            .opacity(store.readerTextureTintOpacity)
                    }

                    if let img = ReaderTextureCache.shared.textureImage(for: item) {
                        Image(uiImage: img)
                            .resizable(resizingMode: .stretch)
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .frame(height: 72)
                            .clipped()
                            .blendMode(.multiply)
                    } else {
                        Color(uiColor: .secondarySystemBackground)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .frame(height: 72)
                    }

                    // 选中状态浅蓝高亮蒙层
                    if isSelected {
                        Color.accentColor.opacity(0.12)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // 选中右下角角标
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .background(Circle().fill(Color.white).padding(2))
                            .padding(6)
                    }
                }
                // 描边（使用 strokeBorder 向内描边，杜绝向外溢出干扰相邻单元）
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                            lineWidth: isSelected ? 2.5 : 1
                        )
                }

                Text(item.displayName)
                    .font(.caption.weight(isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 3. 纹理作用目标范围 (全屏覆盖 / 仅图片本身 / 仅阅读器背景)
    private var textureScopeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("纹理作用目标")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Text("控制材质渗透范围")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ForEach(ReaderTextureTarget.allCases) { target in
                    let isSelected = store.readerTextureTarget == target
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.readerTextureTarget = target
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: target.systemIcon)
                                .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                            Text(target.displayName)
                                .font(.caption.weight(isSelected ? .bold : .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(store.readerTextureTarget.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            if store.readerTextureTarget == .imageOnly {
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("四周拼接背景")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("画面纹理 + 自定义周围背景")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        ForEach(ReaderImageOnlyBackdrop.allCases) { backdrop in
                            let isSelected = store.readerImageOnlyBackdrop == backdrop
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    store.readerImageOnlyBackdrop = backdrop
                                }
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: backdrop.systemIcon)
                                        .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                                    Text(backdrop.title)
                                        .font(.caption2.weight(isSelected ? .bold : .medium))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color(uiColor: .secondarySystemBackground))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.8)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 4. 纹理浓度与纸张着色滑块
    private var textureOpacitySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("纸质透光与纤维浓度")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int(store.readerTextureOpacity * 100))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { store.readerTextureOpacity },
                        set: { store.readerTextureOpacity = $0 }
                    ),
                    in: 0.1...1.0,
                    step: 0.05
                )
                .tint(.accentColor)

                Text("控制纸张纤维颗粒在背景与画面上的显现深度。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("纸张着色浓度")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((store.readerTextureTintOpacity * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: Binding(
                        get: { store.readerTextureTintOpacity },
                        set: { store.readerTextureTintOpacity = $0 }
                    ),
                    in: 0.0...1.0,
                    step: 0.05
                )
                .tint(.accentColor)

                Text("控制材质原生纸浆底色对背景与画面的着色深浅；调至 0% 可保持纯白原貌并仅保留纸张微粒。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 4. 沉浸式动态光晕提示
    private var immersiveInfoSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.purple)

            VStack(alignment: .leading, spacing: 4) {
                Text("动态氛围沉浸模式")
                    .font(.subheadline.weight(.semibold))
                Text("后台实时提取当前页边缘色系并执行 GPU 高斯模糊，在全屏营造弥散流动光晕，翻页平滑淡入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - 5. 书脊立体光影开关
    private var spineShadowSection: some View {
        VStack(spacing: 12) {
            Toggle(isOn: $store.showSpineShadowInCurl) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("书脊立体中缝阴影")
                        .font(.subheadline.weight(.medium))
                    Text("模拟实体书装订装订处的凹陷柔光阴影，增强翻折开本的立体纵深")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle(isOn: $store.showSpineDividingLine) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("书脊中缝细分割线")
                        .font(.subheadline.weight(.medium))
                    Text("在双面开本中央渲染一条极细的书缝分割线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
