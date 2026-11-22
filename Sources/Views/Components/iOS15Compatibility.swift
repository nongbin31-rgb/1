import SwiftUI

// MARK: - iOS 15 兼容性 UI 组件与修饰符套件

/// 替代 iOS 16+ 的 LabeledContent，在 iOS 15 呈现标准左标签右内容布局
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

// MARK: - View 扩展兼容修饰符

extension View {
    /// 兼容 iOS 16+ 的 presentationDetents（高度预设）
    @ViewBuilder
    public func compatPresentationDetentsHeight(_ height: CGFloat) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.height(height)])
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 presentationDetents（比例预设）
    @ViewBuilder
    public func compatPresentationDetentsFractions(_ fractions: [CGFloat]) -> some View {
        if #available(iOS 16.0, *) {
            let detents = Set(fractions.map { PresentationDetent.fraction($0) })
            self.presentationDetents(detents)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 presentationDetents（标准 medium, large）
    @ViewBuilder
    public func compatPresentationDetentsMediumLarge() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents([.medium, .large])
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 presentationDragIndicator
    @ViewBuilder
    public func compatPresentationDragIndicatorVisible() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 scrollDismissesKeyboard
    @ViewBuilder
    public func compatScrollDismissesKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// 兼容 iOS 16+ 的 scrollIndicators（iOS 15 配合 ScrollView(showsIndicators:) 使用）
    @ViewBuilder
    public func compatScrollIndicatorsHidden(_ hidden: Bool) -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(hidden ? .hidden : .automatic)
        } else {
            self.id(hidden)
        }
    }

    /// 兼容 iOS 16+ 的 toolbar(.hidden, for: .navigationBar)
    @ViewBuilder
    public func compatNavigationBarHidden(_ hidden: Bool) -> some View {
        self.navigationBarHidden(hidden)
    }

    /// 兼容 iOS 16+ 的 toolbarBackground
    @ViewBuilder
    public func compatToolbarBackgroundDark() -> some View {
        if #available(iOS 16.0, *) {
            self
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarBackground(Color.black.opacity(0.85), for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        } else {
            self
        }
    }

    // MARK: - iOS 15 系统原生毛玻璃（.ultraThinMaterial）兼容修饰符

    /// 胶囊形系统原生毛玻璃背景（iOS 15 原生基于 .ultraThinMaterial）
    public func liquidGlassCapsule(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
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

    /// 圆形系统原生毛玻璃背景
    public func liquidGlassCircle(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
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

    /// 连续圆角矩形系统原生毛玻璃背景
    public func liquidGlassRoundedRect(
        cornerRadius: CGFloat = 18,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint?.opacity(0.35) ?? Color.clear)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 8, y: 3)
    }
}
