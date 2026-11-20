import SwiftUI
import UIKit

/// 条漫模式交互式缩放与平移漫游容器（完美对齐左右翻页双指缩放体验）
///
/// 特性：
/// 1. 原生级双指捏合缩放（Pinch-to-zoom，支持 1.0x ~ 5.0x 动态无级缩放）；
/// 2. 原生级双击手势（Double-tap to zoom）：
///    - 未放大时：以双击触点为中心自动聚焦平滑放大至 2.6x；
///    - 放大状态下：双击立即以弹簧动画平滑复原至 1.0x；
/// 3. 单击（Single-tap）与双击互斥隔离，双击绝不误触控制栏；
/// 4. 放大状态下支持全向自由平移漫游（Pan）与视野边界阻尼约束；
/// 5. 1.0x 常规状态下平移手势零开销，条漫垂直长图滚屏 100% 原生丝滑；
/// 6. 附带贴心的浮动倍率指示胶囊（如「🔍 2.6x」），轻触一键快速复位。
public struct ZoomableWebtoonContainer<Content: View>: View {
    public let onSingleTap: () -> Void
    public let content: () -> Content

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    public init(
        onSingleTap: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.onSingleTap = onSingleTap
        self.content = content
    }

    public var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size

            ZStack(alignment: .topTrailing) {
                // 条漫内容展示层
                content()
                    .environment(\.readerZoomScale, scale)
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .scaleEffect(scale, anchor: .center)
                    .offset(offset)
                    // 双指捏合缩放手势（任何状态下均可双指实时捏合）
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                let rawScale = lastScale * value
                                // 允许捏合缩放范围：0.85x（轻微弹性）~ 5.2x
                                let newScale = min(max(rawScale, 0.85), 5.2)
                                scale = newScale
                                offset = clampOffset(offset, scale: newScale, viewportSize: viewportSize, allowRubberBand: true)
                            }
                            .onEnded { _ in
                                if scale < 1.05 {
                                    // 缩放小于 1.05x 时弹簧弹性复原
                                    impactFeedback.impactOccurred()
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                        scale = 1.0
                                        offset = .zero
                                    }
                                    lastScale = 1.0
                                    lastOffset = .zero
                                } else {
                                    let finalScale = min(scale, 5.0)
                                    let clamped = clampOffset(offset, scale: finalScale, viewportSize: viewportSize, allowRubberBand: false)
                                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                        scale = finalScale
                                        offset = clamped
                                    }
                                    lastScale = finalScale
                                    lastOffset = clamped
                                }
                            }
                    )
                    // 单指平移漫游手势：仅在放大状态 (scale > 1.05) 时激活！
                    // 未放大时为 nil，条漫原本的纵向长图滚动保持 100% 原始丝滑与完全零冲突！
                    .simultaneousGesture(
                        scale > 1.05 ?
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let targetOffset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                                offset = clampOffset(targetOffset, scale: scale, viewportSize: viewportSize, allowRubberBand: true)
                            }
                            .onEnded { value in
                                let finalOffset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                                let clamped = clampOffset(finalOffset, scale: scale, viewportSize: viewportSize, allowRubberBand: false)
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                                    offset = clamped
                                }
                                lastOffset = clamped
                            }
                        : nil
                    )
                    // 双击手势：优先匹配双击，双击成功绝不触发单击
                    .onTapGesture(count: 2) { location in
                        impactFeedback.impactOccurred()

                        if scale > 1.05 {
                            // 已经处于放大状态：双击平滑恢复 1.0x
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                scale = 1.0
                                offset = .zero
                            }
                            lastScale = 1.0
                            lastOffset = .zero
                        } else {
                            // 处于常规 1.0x 状态：以双击落点为焦点，平滑聚焦放大至 2.6x
                            let targetScale: CGFloat = 2.6
                            let center = CGPoint(x: viewportSize.width * 0.5, y: viewportSize.height * 0.5)
                            let targetOffsetX = (center.x - location.x) * (targetScale - 1.0)
                            let targetOffsetY = (center.y - location.y) * (targetScale - 1.0)

                            let clamped = clampOffset(
                                CGSize(width: targetOffsetX, height: targetOffsetY),
                                scale: targetScale,
                                viewportSize: viewportSize,
                                allowRubberBand: false
                            )

                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                scale = targetScale
                                offset = clamped
                            }
                            lastScale = targetScale
                            lastOffset = clamped
                        }
                    }
                    // 单击手势：唤起/隐藏阅读器控制栏
                    .onTapGesture(count: 1) {
                        onSingleTap()
                    }

                // 放大状态浮动倍率指示与一键复位药丸
                if scale > 1.05 {
                    Button {
                        impactFeedback.impactOccurred()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                            scale = 1.0
                            offset = .zero
                        }
                        lastScale = 1.0
                        lastOffset = .zero
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11, weight: .bold))
                            Text(String(format: "%.1fx", scale))
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.72), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 0.8))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    }
                    .padding(.top, proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top + 8 : 20)
                    .padding(.trailing, 16)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
    }

    // MARK: - 视野边界与橡皮筋阻尼计算

    private func clampOffset(
        _ target: CGSize,
        scale: CGFloat,
        viewportSize: CGSize,
        allowRubberBand: Bool = false
    ) -> CGSize {
        guard scale > 1.0 else { return .zero }

        let maxOffsetX = max((viewportSize.width * (scale - 1.0)) * 0.5, 0)
        let maxOffsetY = max((viewportSize.height * (scale - 1.0)) * 0.5, 0)

        var x = target.width
        var y = target.height

        if allowRubberBand {
            if x > maxOffsetX {
                x = maxOffsetX + (x - maxOffsetX) * 0.32
            } else if x < -maxOffsetX {
                x = -maxOffsetX + (x + maxOffsetX) * 0.32
            }

            if y > maxOffsetY {
                y = maxOffsetY + (y - maxOffsetY) * 0.32
            } else if y < -maxOffsetY {
                y = -maxOffsetY + (y + maxOffsetY) * 0.32
            }
        } else {
            x = min(max(x, -maxOffsetX), maxOffsetX)
            y = min(max(y, -maxOffsetY), maxOffsetY)
        }

        return CGSize(width: x, height: y)
    }
}
