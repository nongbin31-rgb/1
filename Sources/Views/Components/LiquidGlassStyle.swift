import SwiftUI

// MARK: - iOS 26 原生液态玻璃 (Liquid Glass) 统一样式封装

public extension View {
    /// 胶囊形原生液态玻璃背景（适用于悬浮按钮、提示胶囊、对比切换等）
    func liquidGlassCapsule(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        let glass = interactive ? base.interactive() : base
        return self.glassEffect(glass, in: Capsule())
    }

    /// 圆形原生液态玻璃背景（适用于圆形图标按钮）
    func liquidGlassCircle(
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        let glass = interactive ? base.interactive() : base
        return self.glassEffect(glass, in: Circle())
    }

    /// 连续圆角矩形原生液态玻璃背景（适用于浮窗、操作栏、预览卡片等）
    func liquidGlassRoundedRect(
        cornerRadius: CGFloat = 18,
        interactive: Bool = false,
        tint: Color? = nil
    ) -> some View {
        let base = tint.map { Glass.regular.tint($0) } ?? Glass.regular
        let glass = interactive ? base.interactive() : base
        return self.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// iOS 26 原生液态玻璃弹窗修饰符
    /// 注意：在 iOS 26 SDK 下不覆写 `.presentationBackground(.ultraThinMaterial)`，
    /// 从而让系统原生 Sheet 自动呈现完整的 Liquid Glass 动态折射材质。
    @ViewBuilder
    func readerLiquidGlassSheet(
        fractions: [CGFloat]? = nil,
        cornerRadius: CGFloat = 32
    ) -> some View {
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
    }
}
