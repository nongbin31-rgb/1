import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 右向左滑动退出交互实时状态
public struct ReaderSwipeDismissState: Equatable {
    /// 内容层已向左平移的视觉距离（>= 0）
    public var offset: CGFloat = 0
    /// 退出圆环进度（0.0 ~ 1.0）
    public var progress: CGFloat = 0
    /// 是否正在手势拖拽中
    public var isDragging: Bool = false
    /// 是否已达到松手退出阈值
    public var isReadyToDismiss: Bool = false

    public var isActive: Bool {
        offset > 0.5 || isDragging
    }
}

/// 阅读器「右向左滑动退出」跟手交互容器（兼容 iOS 15 ~ iOS 26）
///
/// 交互与手势策略：
/// 1. 去除旧版左右双侧边缘滑动两次退出的繁琐流程，统一为单次从右向左跟手拖拽退出；
/// 2. 漫画画面与纸张背景整体随手指向左平滑移动，右侧露出纯净底布与居中「圆形进度环 + 红色叉号」指示器；
/// 3. 所有翻页模式下采用原生 UIScreenEdgePanGestureRecognizer(.right) 挂载到宿主根视图，屏幕中部左右翻页 100% 零干扰；
/// 4. 条漫模式且未缩放、未展开工具栏时，额外支持全屏单指水平左滑拖拽退出，同时严格过滤垂直滚动与双指缩放；
/// 5. 拖拽状态局部隔离在容器内，手指移动时不触发外层 ReaderView 重建，保证 iOS 15 机型满帧跟手。
public struct ReaderSwipeBackContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    public let isEnabled: Bool
    public let isBlocked: Bool
    public let allowFullScreenPan: Bool
    public let readerBackground: ReaderBackground
    public let onDismiss: () -> Void
    private let content: Content

    @State private var swipeState = ReaderSwipeDismissState()
    @State private var isCommittingDismiss = false

    public init(
        isEnabled: Bool,
        isBlocked: Bool,
        allowFullScreenPan: Bool,
        readerBackground: ReaderBackground,
        onDismiss: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isEnabled = isEnabled
        self.isBlocked = isBlocked
        self.allowFullScreenPan = allowFullScreenPan
        self.readerBackground = readerBackground
        self.onDismiss = onDismiss
        self.content = content()
    }

    private var isDarkRevealCanvas: Bool {
        switch readerBackground {
        case .dark, .immersive:
            return true
        case .light, .texture:
            return false
        case .followSystem:
            return colorScheme == .dark
        }
    }

    private var revealBackgroundColor: Color {
        isDarkRevealCanvas ? Color.black : Color.white
    }

    private var ringTrackColor: Color {
        isDarkRevealCanvas ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    private var ringStrokeColor: Color {
        isDarkRevealCanvas ? Color.white : Color.black
    }

    private var closeMarkColor: Color {
        Color(red: 0.90, green: 0.24, blue: 0.27)
    }

    public var body: some View {
        GeometryReader { geo in
            let containerSize = geo.size
            let dragOffset = max(swipeState.offset, 0)

            ZStack {
                // 仅在跟手拖拽期间渲染右侧窄条底布与圆环进度指示器；触发关闭后立刻撤去，绝不闪现整屏白页与居中圆叉
                if !isCommittingDismiss && (dragOffset > 0.5 || swipeState.isDragging) {
                    revealBackgroundColor
                        .frame(width: containerSize.width, height: containerSize.height)
                        .allowsHitTesting(false)

                    dismissProgressIndicator(
                        containerSize: containerSize,
                        revealedWidth: dragOffset
                    )
                    .allowsHitTesting(false)
                }

                // 漫画内容与背景整体随手指向左平移（仅在拖拽揭示阶段偏移，松手关闭立即恢复整页直接退场）
                let activeOffset = isCommittingDismiss ? 0 : dragOffset
                content
                    .frame(width: containerSize.width, height: containerSize.height)
                    .clipped()
                    .shadow(
                        color: activeOffset > 0.5
                            ? Color.black.opacity(isDarkRevealCanvas ? 0.36 : 0.08)
                            : Color.clear,
                        radius: activeOffset > 0.5 ? 10 : 0,
                        x: activeOffset > 0.5 ? 3 : 0,
                        y: 0
                    )
                    .offset(x: -activeOffset)

                #if canImport(UIKit)
                ReaderRightToLeftSwipeInstaller(
                    isEnabled: isEnabled && !isCommittingDismiss,
                    isBlocked: isBlocked || isCommittingDismiss,
                    allowFullScreenPan: allowFullScreenPan,
                    onStateChanged: { newState, animated in
                        guard !isCommittingDismiss else { return }
                        if animated {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                swipeState = newState
                            }
                        } else {
                            swipeState = newState
                        }
                    },
                    onCommitDismiss: {
                        commitDismiss()
                    }
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                #endif
            }
            .frame(width: containerSize.width, height: containerSize.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    private func dismissProgressIndicator(containerSize: CGSize, revealedWidth: CGFloat) -> some View {
        let clampedProgress = min(max(swipeState.progress, 0), 1)
        let ringSize: CGFloat = 38
        let centerX = containerSize.width - revealedWidth * 0.5
        let centerY = containerSize.height * 0.5
        let isReady = swipeState.isReadyToDismiss
        let indicatorScale: CGFloat = isReady ? 1.06 : (0.86 + clampedProgress * 0.14)
        let indicatorOpacity: Double = Double(min(max(revealedWidth / 28.0, 0), 1.0))

        return ZStack {
            Circle()
                .stroke(ringTrackColor, lineWidth: 2.8)
                .frame(width: ringSize, height: ringSize)

            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(
                    ringStrokeColor,
                    style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: ringSize, height: ringSize)

            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(closeMarkColor.opacity(isReady ? 1.0 : (0.42 + Double(clampedProgress) * 0.58)))
        }
        .scaleEffect(indicatorScale)
        .opacity(indicatorOpacity)
        .position(x: centerX, y: centerY)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.80), value: isReady)
    }

    private func commitDismiss() {
        guard !isCommittingDismiss else { return }
        isCommittingDismiss = true
        swipeState = ReaderSwipeDismissState()
        onDismiss()
    }
}

#if canImport(UIKit)
private struct ReaderRightToLeftSwipeInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let isBlocked: Bool
    let allowFullScreenPan: Bool
    let onStateChanged: (ReaderSwipeDismissState, Bool) -> Void
    let onCommitDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            isBlocked: isBlocked,
            allowFullScreenPan: allowFullScreenPan,
            onStateChanged: onStateChanged,
            onCommitDismiss: onCommitDismiss
        )
    }

    func makeUIView(context: Context) -> AnchorView {
        let view = AnchorView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onMovedToWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let coordinator, let view else { return }
            coordinator.attachIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isBlocked = isBlocked
        context.coordinator.allowFullScreenPan = allowFullScreenPan
        context.coordinator.onStateChanged = onStateChanged
        context.coordinator.onCommitDismiss = onCommitDismiss
        context.coordinator.attachIfNeeded(from: uiView)
        context.coordinator.syncRecognizerEnabledState()
    }

    static func dismantleUIView(_ uiView: AnchorView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AnchorView: UIView {
        var onMovedToWindow: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                onMovedToWindow?()
            }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var isBlocked: Bool
        var allowFullScreenPan: Bool
        var onStateChanged: (ReaderSwipeDismissState, Bool) -> Void
        var onCommitDismiss: () -> Void

        private weak var attachedHostView: UIView?
        private var rightEdgePan: UIScreenEdgePanGestureRecognizer?
        private var webtoonLeftPan: UIPanGestureRecognizer?
        private var hasTriggeredReadyHaptic = false
        private var isTrackingSwipe = false
        private let readyHaptic = UIImpactFeedbackGenerator(style: .medium)

        private let quickSwipeMinDistance: CGFloat = 52
        private let quickSwipeVelocityThreshold: CGFloat = 780

        init(
            isEnabled: Bool,
            isBlocked: Bool,
            allowFullScreenPan: Bool,
            onStateChanged: @escaping (ReaderSwipeDismissState, Bool) -> Void,
            onCommitDismiss: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.isBlocked = isBlocked
            self.allowFullScreenPan = allowFullScreenPan
            self.onStateChanged = onStateChanged
            self.onCommitDismiss = onCommitDismiss
            super.init()
            self.readyHaptic.prepare()
        }

        func attachIfNeeded(from anchorView: UIView) {
            guard let targetView = resolveHostView(from: anchorView) else { return }
            if attachedHostView === targetView, rightEdgePan != nil, webtoonLeftPan != nil {
                syncRecognizerEnabledState()
                return
            }

            detach()

            let rightPan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
            rightPan.edges = .right
            rightPan.delegate = self
            rightPan.cancelsTouchesInView = true

            let fullPan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipePan(_:)))
            fullPan.maximumNumberOfTouches = 1
            fullPan.delegate = self
            fullPan.cancelsTouchesInView = true

            targetView.addGestureRecognizer(rightPan)
            targetView.addGestureRecognizer(fullPan)

            self.attachedHostView = targetView
            self.rightEdgePan = rightPan
            self.webtoonLeftPan = fullPan
            syncRecognizerEnabledState()
        }

        func syncRecognizerEnabledState() {
            let active = isEnabled && !isBlocked
            rightEdgePan?.isEnabled = active
            webtoonLeftPan?.isEnabled = active && allowFullScreenPan
            if !active && isTrackingSwipe {
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                DispatchQueue.main.async { [weak self] in
                    self?.onStateChanged(ReaderSwipeDismissState(), true)
                }
            }
        }

        func detach() {
            if let host = attachedHostView {
                if let right = rightEdgePan { host.removeGestureRecognizer(right) }
                if let full = webtoonLeftPan { host.removeGestureRecognizer(full) }
            }
            rightEdgePan = nil
            webtoonLeftPan = nil
            attachedHostView = nil
            hasTriggeredReadyHaptic = false
            isTrackingSwipe = false
        }

        private func resolveHostView(from view: UIView) -> UIView? {
            var responder: UIResponder? = view
            while let current = responder {
                if let vc = current as? UIViewController {
                    return vc.view
                }
                responder = current.next
            }
            return view.window
        }

        private func dismissThreshold(for containerWidth: CGFloat) -> CGFloat {
            // 刚好容纳 38pt 进度圆环并留出舒适边距，拉到此处圆环即满
            min(max(containerWidth * 0.24, 86), 104)
        }

        private func mappedVisualOffset(rawDistance: CGFloat, containerWidth: CGFloat) -> CGFloat {
            let clampedRaw = max(rawDistance, 0)
            let threshold = dismissThreshold(for: containerWidth)
            if clampedRaw <= threshold {
                return clampedRaw
            }
            // 拉满圆环后施加强阻尼限位（最多微弹 12pt），绝不再拖出大片空白底布
            let excess = clampedRaw - threshold
            return threshold + min(12, excess * 0.10)
        }

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard isEnabled, !isBlocked else { return false }
            // 避免拦截工具栏按钮、进度滑块等原生控件交互
            var view = touch.view
            while let current = view {
                if current is UIControl {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, !isBlocked,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let hostView = attachedHostView else {
                return false
            }

            let velocity = pan.velocity(in: hostView)
            // 仅响应从右向左的水平拖动
            guard velocity.x < 0 else {
                return false
            }

            if pan === rightEdgePan {
                // 右边缘起手：水平分量明显大于垂直分量，放行右侧隐形进度纵轨的上下滑动
                return abs(velocity.x) > abs(velocity.y) * 1.30
            }

            if pan === webtoonLeftPan {
                guard allowFullScreenPan, pan.numberOfTouches == 1 else {
                    return false
                }
                // 条漫全屏左滑：要求更严格的水平角度，避免单手竖滑看条漫时误触发，同时支持慢速细腻跟手拉出
                return abs(velocity.x) > abs(velocity.y) * 1.75
            }

            return false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if gestureRecognizer === rightEdgePan {
                if otherGestureRecognizer === webtoonLeftPan {
                    return true
                }
                // 右边缘左滑优先于底层翻页/滚动 pan，杜绝同时翻页与退出
                return otherGestureRecognizer is UIPanGestureRecognizer
            }

            if gestureRecognizer === webtoonLeftPan {
                if otherGestureRecognizer === rightEdgePan {
                    return false
                }
                return otherGestureRecognizer is UIPanGestureRecognizer
            }

            return false
        }

        // MARK: - Gesture Handling

        @objc private func handleSwipePan(_ gesture: UIPanGestureRecognizer) {
            guard let hostView = attachedHostView else { return }
            let containerWidth = max(hostView.bounds.width, 320)
            let translation = gesture.translation(in: hostView)
            let velocity = gesture.velocity(in: hostView)

            let rawDistance = max(0, -translation.x)
            let leftwardVelocity = -velocity.x
            let threshold = dismissThreshold(for: containerWidth)
            let visualOffset = mappedVisualOffset(rawDistance: rawDistance, containerWidth: containerWidth)
            let progress = min(max(rawDistance / threshold, 0), 1.0)
            let isReady = (rawDistance >= threshold)
                || (rawDistance >= quickSwipeMinDistance && leftwardVelocity >= quickSwipeVelocityThreshold)

            switch gesture.state {
            case .began:
                isTrackingSwipe = true
                hasTriggeredReadyHaptic = false
                readyHaptic.prepare()
                onStateChanged(
                    ReaderSwipeDismissState(
                        offset: visualOffset,
                        progress: progress,
                        isDragging: true,
                        isReadyToDismiss: isReady
                    ),
                    false
                )

            case .changed:
                isTrackingSwipe = true
                if isReady && !hasTriggeredReadyHaptic {
                    hasTriggeredReadyHaptic = true
                    readyHaptic.impactOccurred()
                } else if !isReady {
                    hasTriggeredReadyHaptic = false
                }
                onStateChanged(
                    ReaderSwipeDismissState(
                        offset: visualOffset,
                        progress: progress,
                        isDragging: true,
                        isReadyToDismiss: isReady
                    ),
                    false
                )

            case .ended:
                let shouldDismiss = isReady
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                if shouldDismiss {
                    onCommitDismiss()
                } else {
                    onStateChanged(ReaderSwipeDismissState(), true)
                }

            case .cancelled, .failed:
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                onStateChanged(ReaderSwipeDismissState(), true)

            default:
                break
            }
        }
    }
}
#endif
