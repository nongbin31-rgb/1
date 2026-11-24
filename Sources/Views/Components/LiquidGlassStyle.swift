import SwiftUI

// MARK: - 跨版本导航与兼容组件（iOS 15 ~ iOS 26 统一单分支构建）

/// 跨版本导航栈容器：iOS 16+ / iOS 26 使用原生 NavigationStack，iOS 15 自动降级为 NavigationView(.stack)
public struct CompatNavigationContainer<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

/// 跨版本 Liquid Glass 分组容器：Xcode 26 + iOS 26 使用原生 GlassEffectContainer，旧系统直接透传
public struct CompatGlassEffectContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: () -> Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

/// 替代 iOS 16+ 的 LabeledContent，在 iOS 15+ 统一呈现标准左标签右内容布局
public struct CompatLabeledContent<Content: View>: View {
    private let title: String
    private let content: () -> Content

    public init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    public init(_ title: String, value: String) where Content == Text {
        self.title = title
        self.content = {
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            content()
        }
    }
}

// MARK: - iOS 26 原生液态玻璃 (Liquid Glass) + iOS 15~18 毛玻璃优雅降级

public extension View {
    /// 胶囊形原生液态玻璃背景（iOS 26 原生 Liquid Glass；旧系统降级为 .ultraThinMaterial）
    @ViewBuilder
    func liquidGlassCapsule(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            let glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: Capsule())
        } else {
            self
                .background(
                    Capsule()
                        .fill(tint?.opacity(0.35) ?? Color.clear)
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        }
        #else
        self
            .background(
                Capsule()
                    .fill(tint?.opacity(0.35) ?? Color.clear)
                    .background(.ultraThinMaterial, in: Capsule())
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        #endif
    }

    /// 圆形原生液态玻璃背景（iOS 26 原生 Liquid Glass；旧系统降级为 .ultraThinMaterial）
    @ViewBuilder
    func liquidGlassCircle(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            let glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: Circle())
        } else {
            self
                .background(
                    Circle()
                        .fill(tint?.opacity(0.35) ?? Color.clear)
                        .background(.ultraThinMaterial, in: Circle())
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        }
        #else
        self
            .background(
                Circle()
                    .fill(tint?.opacity(0.35) ?? Color.clear)
                    .background(.ultraThinMaterial, in: Circle())
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        #endif
    }

    /// 连续圆角矩形原生液态玻璃背景（iOS 26 原生 Liquid Glass；旧系统降级为 .ultraThinMaterial）
    @ViewBuilder
    func liquidGlassRoundedRect(
        cornerRadius: CGFloat = 18,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            let glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint?.opacity(0.35) ?? Color.clear)
                        .background(
                            .ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        }
        #else
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint?.opacity(0.35) ?? Color.clear)
                    .background(
                        .ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
        #endif
    }

    /// 跨版本半屏 Sheet 修饰符：iOS 26 原生 Liquid Glass 弹窗；iOS 16.4+ 带圆角与 detents；iOS 16.0 带 detents；iOS 15 原生全屏弹窗
    @ViewBuilder
    func readerLiquidGlassSheet(
        fractions: [CGFloat]? = nil,
        cornerRadius: CGFloat = 32
    ) -> some View {
        if #available(iOS 16.4, *) {
            if let fractions {
                let detents = Set(fractions.map { PresentationDetent.fraction($0) })
                self
                    .presentationDetents(detents)
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(cornerRadius)
            } else {
                self
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(cornerRadius)
            }
        } else if #available(iOS 16.0, *) {
            if let fractions {
                let detents = Set(fractions.map { PresentationDetent.fraction($0) })
                self
                    .presentationDetents(detents)
                    .presentationDragIndicator(.visible)
            } else {
                self
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        } else {
            self
        }
    }

    // MARK: - iOS 15 通用兼容修饰符

    /// 兼容 iOS 16+ 的 presentationDetents（固定高度）
    @ViewBuilder
    func compatPresentationDetentsHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 presentationDragIndicator(.visible)
    @ViewBuilder
    func compatPresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 scrollDismissesKeyboard(.interactively)
    @ViewBuilder
    func compatScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 scrollIndicators
    @ViewBuilder
    func compatScrollIndicatorsHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(hidden ? .hidden : .automatic)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 scrollContentBackground(.hidden)
    @ViewBuilder
    func compatScrollContentBackgroundHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 toolbar(.hidden/.visible, for: .navigationBar)
    @ViewBuilder
    func compatNavigationBarHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        } else {
            self.navigationBarHidden(hidden)
        }
    }

    /// 兼容 iOS 16+ 的深色导航栏背景
    @ViewBuilder
    func compatToolbarBackgroundDark() -> some View {
        if #available(iOS 16.0, *) {
            self
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 lineLimit(_:reservesSpace:)
    @ViewBuilder
    func compatLineLimitReservesSpace(_ limit: Int, fallbackHeight: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.lineLimit(limit, reservesSpace: true)
        } else {
            self
                .lineLimit(limit)
                .frame(height: fallbackHeight, alignment: .topLeading)
        }
    }
}
