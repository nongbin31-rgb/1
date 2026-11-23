import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 边缘滑动退出的起手侧边
public enum ReaderEdgeSwipeSide: Equatable {
    case left
    case right
}

/// 边缘滑动退出交互实时状态
public struct ReaderEdgeSwipeState: Equatable {
    public var side: ReaderEdgeSwipeSide? = nil
    public var progress: CGFloat = 0
    public var anchorY: CGFloat = 0
    public var isReadyToDismiss: Bool = false

    public var isActive: Bool {
        side != nil && progress > 0.02
    }
}

/// 阅读器两侧边缘快滑退出手势层与跟手视觉指示器
/// 采用原生 UIScreenEdgePanGestureRecognizer（.left / .right）挂载到宿主根视图：
/// 1. 屏幕中部滑动翻页、双击缩放、点击翻页 100% 零遮挡零干扰；
/// 2. 极边缘横向向内快速滑动时优先于底层翻页 pan 识别，避免翻页与退出同时触发；
/// 3. 要求水平分量明显大于垂直分量，不与条漫上下滚动或右侧隐形进度纵轨冲突。
public struct ReaderEdgeSwipeDismissOverlay: View {
    public let isEnabled: Bool
    public let isBlocked: Bool
    public let onDismiss: () -> Void

    @State private var swipeState = ReaderEdgeSwipeState()

    public init(
        isEnabled: Bool,
        isBlocked: Bool,
        onDismiss: @escaping () -> Void
    ) {
        self.isEnabled = isEnabled
        self.isBlocked = isBlocked
        self.onDismiss = onDismiss
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                #if canImport(UIKit)
                ReaderEdgeSwipeGestureInstaller(
                    isEnabled: isEnabled,
                    isBlocked: isBlocked,
                    onStateChanged: { newState in
                        swipeState = newState
                    },
                    onDismiss: onDismiss
                )
                .frame(width: 0, height: 0)
                #endif

                if let side = swipeState.side, swipeState.isActive {
                    edgeIndicator(side: side, containerSize: geo.size)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func edgeIndicator(side: ReaderEdgeSwipeSide, containerSize: CGSize) -> some View {
        let clampedY: CGFloat = min(max(swipeState.anchorY, 110), max(containerSize.height - 110, 110))
        let clampedProgress: CGFloat = min(max(swipeState.progress, 0), 1)
        let pullOffset: CGFloat = clampedProgress * 26
        let isLeft: Bool = (side == .left)
        let isReady: Bool = swipeState.isReadyToDismiss

        let fgColor: Color = isReady ? .white : Color.white.opacity(0.92)
        let fillColor: Color = isReady ? Color.accentColor.opacity(0.92) : Color.black.opacity(0.62)
        let borderColor: Color = Color.white.opacity(isReady ? 0.35 : 0.18)
        let hPadding: CGFloat = isReady ? 12 : 10
        let posX: CGFloat = isLeft ? (18 + pullOffset) : (containerSize.width - 18 - pullOffset)
        let scaleVal: CGFloat = 0.86 + clampedProgress * 0.14
        let opacityVal: Double = Double(min(clampedProgress * 1.4, 1.0))

        return edgeIndicatorLabel(isLeft: isLeft, isReady: isReady)
            .foregroundColor(fgColor)
            .padding(.horizontal, hPadding)
            .padding(.vertical, 10)
            .background(Capsule().fill(fillColor))
            .overlay(Capsule().strokeBorder(borderColor, lineWidth: 0.75))
            .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 3)
            .scaleEffect(scaleVal)
            .opacity(opacityVal)
            .position(x: posX, y: clampedY)
            .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.85), value: isReady)
    }

    @ViewBuilder
    private func edgeIndicatorLabel(isLeft: Bool, isReady: Bool) -> some View {
        HStack(spacing: 4) {
            if isLeft {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                if isReady {
                    Text("松手退出")
                        .font(.system(size: 11, weight: .semibold))
                }
            } else {
                if isReady {
                    Text("松手退出")
                        .font(.system(size: 11, weight: .semibold))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
            }
        }
    }
}

#if canImport(UIKit)
private struct ReaderEdgeSwipeGestureInstaller: UIViewRepresentable {
    let isEnabled: Bool
    let isBlocked: Bool
    let onStateChanged: (ReaderEdgeSwipeState) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            isBlocked: isBlocked,
            onStateChanged: onStateChanged,
            onDismiss: onDismiss
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
        context.coordinator.onStateChanged = onStateChanged
        context.coordinator.onDismiss = onDismiss
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
        var onStateChanged: (ReaderEdgeSwipeState) -> Void
        var onDismiss: () -> Void

        private weak var attachedHostView: UIView?
        private var leftEdgePan: UIScreenEdgePanGestureRecognizer?
        private var rightEdgePan: UIScreenEdgePanGestureRecognizer?
        private var hasTriggeredReadyHaptic = false
        private var isTrackingSwipe = false
        private let readyHaptic = UIImpactFeedbackGenerator(style: .medium)

        private let distanceThreshold: CGFloat = 72
        private let quickSwipeMinDistance: CGFloat = 28
        private let quickSwipeVelocityThreshold: CGFloat = 500

        init(
            isEnabled: Bool,
            isBlocked: Bool,
            onStateChanged: @escaping (ReaderEdgeSwipeState) -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.isBlocked = isBlocked
            self.onStateChanged = onStateChanged
            self.onDismiss = onDismiss
            super.init()
            self.readyHaptic.prepare()
        }

        func attachIfNeeded(from anchorView: UIView) {
            guard let targetView = resolveHostView(from: anchorView) else { return }
            if attachedHostView === targetView, leftEdgePan != nil, rightEdgePan != nil {
                syncRecognizerEnabledState()
                return
            }

            detach()

            let leftPan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            leftPan.edges = .left
            leftPan.delegate = self
            leftPan.cancelsTouchesInView = true

            let rightPan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
            rightPan.edges = .right
            rightPan.delegate = self
            rightPan.cancelsTouchesInView = true

            targetView.addGestureRecognizer(leftPan)
            targetView.addGestureRecognizer(rightPan)

            self.attachedHostView = targetView
            self.leftEdgePan = leftPan
            self.rightEdgePan = rightPan
            syncRecognizerEnabledState()
        }

        func syncRecognizerEnabledState() {
            let active = isEnabled && !isBlocked
            leftEdgePan?.isEnabled = active
            rightEdgePan?.isEnabled = active
            if !active && isTrackingSwipe {
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                DispatchQueue.main.async { [weak self] in
                    self?.onStateChanged(ReaderEdgeSwipeState())
                }
            }
        }

        func detach() {
            if let host = attachedHostView {
                if let left = leftEdgePan { host.removeGestureRecognizer(left) }
                if let right = rightEdgePan { host.removeGestureRecognizer(right) }
            }
            leftEdgePan = nil
            rightEdgePan = nil
            attachedHostView = nil
            hasTriggeredReadyHaptic = false
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

        // MARK: - UIGestureRecognizerDelegate

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled, !isBlocked,
                  let pan = gestureRecognizer as? UIScreenEdgePanGestureRecognizer,
                  let hostView = attachedHostView else {
                return false
            }

            let velocity = pan.velocity(in: hostView)
            // 仅在明显水平向内滑动时激活，放行条漫上下滚动与右侧进度纵轨上下拖动
            guard abs(velocity.x) > abs(velocity.y) * 1.25 else {
                return false
            }

            if pan === leftEdgePan {
                return velocity.x > 0
            } else if pan === rightEdgePan {
                return velocity.x < 0
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
            guard gestureRecognizer === leftEdgePan || gestureRecognizer === rightEdgePan else {
                return false
            }
            if otherGestureRecognizer === leftEdgePan || otherGestureRecognizer === rightEdgePan {
                return false
            }
            // 让底层翻页/滚动 pan 在极边缘横向快滑时等待边缘退出手势判定，杜绝同时翻页与退出
            return otherGestureRecognizer is UIPanGestureRecognizer
        }

        // MARK: - Gesture Handling

        @objc private func handleEdgePan(_ gesture: UIScreenEdgePanGestureRecognizer) {
            guard let hostView = attachedHostView else { return }
            let side: ReaderEdgeSwipeSide = (gesture === leftEdgePan) ? .left : .right
            let translation = gesture.translation(in: hostView)
            let velocity = gesture.velocity(in: hostView)
            let location = gesture.location(in: hostView)

            let inwardDistance: CGFloat = (side == .left) ? max(0, translation.x) : max(0, -translation.x)
            let inwardVelocity: CGFloat = (side == .left) ? velocity.x : -velocity.x
            let progress = min(max(inwardDistance / distanceThreshold, 0), 1.0)
            let isReady = (inwardDistance >= distanceThreshold)
                || (inwardDistance >= quickSwipeMinDistance && inwardVelocity >= quickSwipeVelocityThreshold)

            switch gesture.state {
            case .began:
                isTrackingSwipe = true
                hasTriggeredReadyHaptic = false
                readyHaptic.prepare()
                onStateChanged(
                    ReaderEdgeSwipeState(
                        side: side,
                        progress: progress,
                        anchorY: location.y,
                        isReadyToDismiss: isReady
                    )
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
                    ReaderEdgeSwipeState(
                        side: side,
                        progress: progress,
                        anchorY: location.y,
                        isReadyToDismiss: isReady
                    )
                )

            case .ended:
                let shouldDismiss = isReady
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                onStateChanged(ReaderEdgeSwipeState())
                if shouldDismiss {
                    onDismiss()
                }

            case .cancelled, .failed:
                isTrackingSwipe = false
                hasTriggeredReadyHaptic = false
                onStateChanged(ReaderEdgeSwipeState())

            default:
                break
            }
        }
    }
}
#endif
