import AudioToolbox
import SwiftUI
import UIKit

/// 层叠覆盖翻页阅读容器（Cover Page Transition）
///
/// 特性与物理模型：
/// 1. 纸页抽离与覆盖：
///    - 翻下一页时：下层页面静止在底层，当前页（顶层）随手势平移抽离移出屏幕，边缘投射自然落影；
///    - 翻上一页时：当前页静止在底层，上一页（顶层）从屏幕外侧平移滑入覆盖当前页，边缘投射自然落影；
/// 2. 日漫 (RTL) 与美漫 (LTR) 手势与极性精准双向映射；
/// 3. 动态手势隔离：单页放大缩放时动态锁死外层平移手势，杜绝冲突；
/// 4. 纯矢量 2D 渐变落影（CAGradientLayer），零离屏渲染开销，在所有设备上保持 60/120fps 满帧；
/// 5. 翻页时伴随 Taptic Engine 微触觉与拟真翻书轻音；
/// 6. 完备的外部跳页（Slider / 上下话）平滑转场队列。
public struct CoverPageReaderView: UIViewControllerRepresentable {
    public let pages: [MangaPage]
    public let upscalerConfig: ImageUpscalerConfig
    public let enableUpscaler: Bool
    public let transitionAfterUpscaled: Bool
    public let filterConfig: ImageFilterConfig
    public let isCompareMode: Bool
    public let isRightToLeft: Bool
    public let soundEnabled: Bool
    public let background: ReaderBackground
    public let texture: ReaderTextureType
    public let textureOpacity: Double
    public let textureTintOpacity: Double
    public let textureTarget: ReaderTextureTarget
    public let imageOnlyBackdrop: ReaderImageOnlyBackdrop
    public let showDividingLine: Bool
    @Binding public var currentPageIndex: Int
    public let onSingleTap: () -> Void
    public let onStatusUpdate: (String) -> Void
    public var onImageLoaded: ((UIImage) -> Void)? = nil

    public init(
        pages: [MangaPage],
        upscalerConfig: ImageUpscalerConfig,
        enableUpscaler: Bool = false,
        transitionAfterUpscaled: Bool = true,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool,
        isRightToLeft: Bool,
        soundEnabled: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        textureTarget: ReaderTextureTarget = .both,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        showDividingLine: Bool = true,
        currentPageIndex: Binding<Int>,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.pages = pages
        self.upscalerConfig = upscalerConfig
        self.enableUpscaler = enableUpscaler
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.filterConfig = filterConfig
        self.isCompareMode = isCompareMode
        self.isRightToLeft = isRightToLeft
        self.soundEnabled = soundEnabled
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = textureTintOpacity
        self.textureTarget = textureTarget
        self.imageOnlyBackdrop = imageOnlyBackdrop
        self.showDividingLine = showDividingLine
        self._currentPageIndex = currentPageIndex
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onImageLoaded = onImageLoaded
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIViewController(context: Context) -> CoverPageViewController {
        let vc = CoverPageViewController(coordinator: context.coordinator)
        context.coordinator.viewController = vc
        return vc
    }

    public func updateUIViewController(_ uiViewController: CoverPageViewController, context: Context) {
        context.coordinator.parent = self

        // 1. 同步背景风格
        uiViewController.updateBackgroundStyle(background)

        // 2. 动态更新当前可见子页面的超分状态、滤镜配置、对比模式、背景与纸质纹理
        uiViewController.updateVisibleControllersConfiguration(
            config: upscalerConfig,
            isEnabled: enableUpscaler,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isCompareMode: isCompareMode,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            showDividingLine: showDividingLine
        )

        // 3. 初始装载或当外部修改了页码（例如 Slider 拖拽）时，请求平滑或即时转场
        uiViewController.ensureInitialPageOrNavigate(to: currentPageIndex)
    }

    // MARK: - Coordinator

    public final class Coordinator: NSObject {
        var parent: CoverPageReaderView
        weak var viewController: CoverPageViewController?

        init(parent: CoverPageReaderView) {
            self.parent = parent
            super.init()
        }
    }
}

// MARK: - CoverPageViewController

public final class CoverPageViewController: UIViewController, UIGestureRecognizerDelegate {
    private let coordinator: CoverPageReaderView.Coordinator
    private var parentConfig: CoverPageReaderView { coordinator.parent }

    public private(set) var currentDisplayIndex: Int = 0

    // 视图图层结构：
    // containerView (裁剪边界)
    // ├── bottomSlotView (下层固定页容器)
    // └── topSlotView    (上层滑动页容器，带右侧/左侧落影)
    //     └── shadowGradientLayer (纸页边缘投影)
    private let containerView = UIView()
    private let bottomSlotView = UIView()
    private let topSlotView = UIView()
    private let shadowGradientLayer = CAGradientLayer()
    private let shadowWidth: CGFloat = 24.0

    private var activeVC: ComicPageHostingController?
    private var incomingVC: ComicPageHostingController?

    private var panGesture: UIPanGestureRecognizer!
    private var isTransitioning = false
    private var isZoomed = false
    private var pendingTargetIndex: Int?

    // 手势拖拽会话状态
    private enum TransitionIntent {
        case none
        case toNext
        case toPrev
    }
    private var activeIntent: TransitionIntent = .none
    private var targetIndex: Int = -1
    private var isAtBoundary: Bool = false
    private var initialTopOffset: CGFloat = 0

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    public init(coordinator: CoverPageReaderView.Coordinator) {
        self.coordinator = coordinator
        self.currentDisplayIndex = coordinator.parent.currentPageIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        setupGestures()
        feedbackGenerator.prepare()

        // 初始化加载首屏
        if parentConfig.pages.indices.contains(currentDisplayIndex) {
            displayPage(at: currentDisplayIndex)
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        containerView.frame = view.bounds
        bottomSlotView.frame = containerView.bounds
        // 如果不在手势或动画中，确保 topSlotView 紧贴容器
        if !isTransitioning {
            topSlotView.frame = containerView.bounds
            activeVC?.view.frame = topSlotView.bounds
        }
        updateShadowFrame()
    }

    private func setupViews() {
        view.backgroundColor = .black

        containerView.clipsToBounds = true
        containerView.backgroundColor = .clear
        view.addSubview(containerView)

        bottomSlotView.clipsToBounds = true
        bottomSlotView.backgroundColor = .clear
        containerView.addSubview(bottomSlotView)

        // topSlotView 不能 clipsToBounds，以使外延的落影层能够投射到 bottomSlotView 上
        topSlotView.clipsToBounds = false
        topSlotView.backgroundColor = .clear
        containerView.addSubview(topSlotView)

        // 纸页边缘柔和落影渐变层
        shadowGradientLayer.opacity = 0.0
        topSlotView.layer.addSublayer(shadowGradientLayer)
    }

    private func setupGestures() {
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.delegate = self
        panGesture.maximumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)
    }

    // MARK: - 背景风格更新

    public func updateBackgroundStyle(_ background: ReaderBackground) {
        switch background {
        case .followSystem:
            view.backgroundColor = .systemBackground
        case .light:
            view.backgroundColor = .white
        case .dark:
            view.backgroundColor = .black
        case .immersive, .texture:
            view.backgroundColor = .clear
        }
    }

    // MARK: - 动态配置更新

    public func updateVisibleControllersConfiguration(
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool,
        isRightToLeft: Bool,
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double = 1.0,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        showDividingLine: Bool
    ) {
        activeVC?.updateConfiguration(
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isCompareMode: isCompareMode,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            showDividingLine: showDividingLine
        )
        incomingVC?.updateConfiguration(
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isCompareMode: isCompareMode,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            showDividingLine: showDividingLine
        )
    }

    // MARK: - 页面装载与展示

    private func displayPage(at index: Int) {
        guard parentConfig.pages.indices.contains(index) else { return }

        // 移除原有控制器
        activeVC?.willMove(toParent: nil)
        activeVC?.view.removeFromSuperview()
        activeVC?.removeFromParent()

        guard let newVC = createViewController(for: index) else { return }
        addChild(newVC)
        newVC.view.frame = topSlotView.bounds
        newVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        topSlotView.addSubview(newVC.view)
        newVC.didMove(toParent: self)

        activeVC = newVC
        currentDisplayIndex = index
        topSlotView.transform = .identity
        shadowGradientLayer.opacity = 0.0
    }

    private func createViewController(for index: Int) -> ComicPageHostingController? {
        guard parentConfig.pages.indices.contains(index) else { return nil }
        let page = parentConfig.pages[index]

        return ComicPageHostingController(
            pageIndex: index,
            page: page,
            config: parentConfig.upscalerConfig,
            isEnabled: parentConfig.enableUpscaler,
            transitionAfterUpscaled: parentConfig.transitionAfterUpscaled,
            filterConfig: parentConfig.filterConfig,
            isCompareMode: parentConfig.isCompareMode,
            showSpineShadow: false,
            isRightToLeft: parentConfig.isRightToLeft,
            background: parentConfig.background,
            texture: parentConfig.texture,
            textureOpacity: parentConfig.textureOpacity,
            textureTintOpacity: parentConfig.textureTintOpacity,
            textureTarget: parentConfig.textureTarget,
            imageOnlyBackdrop: parentConfig.imageOnlyBackdrop,
            showDividingLine: parentConfig.showDividingLine,
            onSingleTap: parentConfig.onSingleTap,
            onStatusUpdate: parentConfig.onStatusUpdate,
            onZoomChanged: { [weak self] scale in
                // 核心手势隔离：单页处于放大模式时禁用翻页手势，防止手势抢占
                self?.isZoomed = (scale > 1.01)
            },
            onImageLoaded: { [weak self] img in
                if index == self?.currentDisplayIndex {
                    self?.parentConfig.onImageLoaded?(img)
                }
            }
        )
    }

    // MARK: - 手势代理 (UIGestureRecognizerDelegate)

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGesture {
            // 放大状态或正在程序化动画时禁止手势介入
            if isZoomed || isTransitioning { return false }

            let v = panGesture.velocity(in: view)
            // 垂直意图强于水平意图时不响应（避免打扰系统控制中心或上下滑动）
            if abs(v.y) > abs(v.x) { return false }
            return true
        }
        return true
    }

    // MARK: - 交互式平移手势处理 (Interactive Pan)

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let width = view.bounds.width
        guard width > 0 else { return }

        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            activeIntent = .none
            isAtBoundary = false

        case .changed:
            if activeIntent == .none {
                // 根据初次移动位移方向确定本次翻页意图
                let isRTL = parentConfig.isRightToLeft
                if abs(translation.x) > 6.0 {
                    // LTR: 向左拖 (x < 0) 读下一页，向右拖 (x > 0) 读上一页
                    // RTL: 向右拖 (x > 0) 读下一页，向左拖 (x < 0) 读上一页
                    let wantsNext = isRTL ? (translation.x > 0) : (translation.x < 0)
                    activeIntent = wantsNext ? .toNext : .toPrev
                    targetIndex = wantsNext ? (currentDisplayIndex + 1) : (currentDisplayIndex - 1)

                    if !parentConfig.pages.indices.contains(targetIndex) {
                        isAtBoundary = true
                    } else {
                        isAtBoundary = false
                        beginInteractiveTransition(wantsNext: wantsNext, targetIndex: targetIndex)
                    }
                }
            }

            if activeIntent != .none {
                if isAtBoundary {
                    // 处于图书首尾边界：施加 0.2 阻尼橡皮筋弹性拉伸
                    let dampedX = translation.x * 0.2
                    topSlotView.transform = CGAffineTransform(translationX: dampedX, y: 0)
                } else {
                    updateInteractiveTransition(translationX: translation.x, totalWidth: width)
                }
            }

        case .ended, .cancelled:
            if activeIntent != .none {
                if isAtBoundary {
                    // 边界弹性复位
                    UIView.animate(
                        withDuration: 0.25,
                        delay: 0,
                        options: [.curveEaseOut],
                        animations: {
                            self.topSlotView.transform = .identity
                        },
                        completion: { _ in
                            self.activeIntent = .none
                        }
                    )
                } else {
                    finishInteractiveTransition(
                        translationX: translation.x,
                        velocityX: velocity.x,
                        totalWidth: width
                    )
                }
            }

        default:
            break
        }
    }

    // MARK: - 交互式翻页生命周期

    private func beginInteractiveTransition(wantsNext: Bool, targetIndex: Int) {
        guard let nextVC = createViewController(for: targetIndex), let current = activeVC else { return }

        incomingVC = nextVC
        addChild(nextVC)
        nextVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let isRTL = parentConfig.isRightToLeft

        if wantsNext {
            // 【翻下一页】：
            // 当前页 (activeVC) 位于上层 (topSlotView)，跟随手指滑出
            // 下一页 (incomingVC) 预置于底层 (bottomSlotView)，静止不动
            nextVC.view.frame = bottomSlotView.bounds
            bottomSlotView.addSubview(nextVC.view)
            nextVC.didMove(toParent: self)

            // 设置边缘投影：
            // LTR: 当前页向左滑出，右边缘投射落影到下一页
            // RTL: 当前页向右滑出，左边缘投射落影到下一页
            configureShadow(edgeIsRight: !isRTL)
            initialTopOffset = 0
            topSlotView.transform = .identity
        } else {
            // 【翻上一页】：
            // 当前页 (activeVC) 位于底层 (bottomSlotView)，静止不动
            // 上一页 (incomingVC) 位于上层 (topSlotView)，从屏幕外侧滑入覆盖当前页
            current.view.removeFromSuperview()
            current.view.frame = bottomSlotView.bounds
            bottomSlotView.addSubview(current.view)

            nextVC.view.frame = topSlotView.bounds
            topSlotView.addSubview(nextVC.view)
            nextVC.didMove(toParent: self)

            // 设置边缘投影：
            // LTR: 上一页从左侧滑入，其右边缘投射落影到当前页
            // RTL: 上一页从右侧滑入，其左边缘投射落影到当前页
            configureShadow(edgeIsRight: !isRTL)

            // 上一页初始放置在屏幕外侧
            let startOffset = isRTL ? view.bounds.width : -view.bounds.width
            initialTopOffset = startOffset
            topSlotView.transform = CGAffineTransform(translationX: startOffset, y: 0)
        }

        shadowGradientLayer.opacity = 1.0
        updateShadowFrame()
    }

    private func updateInteractiveTransition(translationX: CGFloat, totalWidth: CGFloat) {
        let isRTL = parentConfig.isRightToLeft

        if activeIntent == .toNext {
            // 翻下一页：限制滑出方向
            let offset: CGFloat
            if isRTL {
                // RTL 向右滑出 (x >= 0)
                offset = max(0, min(totalWidth, translationX))
            } else {
                // LTR 向左滑出 (x <= 0)
                offset = min(0, max(-totalWidth, translationX))
            }
            topSlotView.transform = CGAffineTransform(translationX: offset, y: 0)

            // 越接近滑出完毕，阴影稍微变淡
            let progress = abs(offset) / totalWidth
            shadowGradientLayer.opacity = Float(1.0 - progress * 0.3)
        } else if activeIntent == .toPrev {
            // 翻上一页：从屏幕外滑入 (initialTopOffset + translation)
            let offset: CGFloat
            if isRTL {
                // RTL: 从 +width 往左滑向 0
                offset = max(0, min(totalWidth, initialTopOffset + translationX))
            } else {
                // LTR: 从 -width 往右滑向 0
                offset = min(0, max(-totalWidth, initialTopOffset + translationX))
            }
            topSlotView.transform = CGAffineTransform(translationX: offset, y: 0)

            let progress = 1.0 - (abs(offset) / totalWidth)
            shadowGradientLayer.opacity = Float(0.5 + progress * 0.5)
        }
    }

    private func finishInteractiveTransition(
        translationX: CGFloat,
        velocityX: CGFloat,
        totalWidth: CGFloat
    ) {
        let isRTL = parentConfig.isRightToLeft
        let committed: Bool

        if activeIntent == .toNext {
            let moved = isRTL ? translationX : -translationX
            let vel = isRTL ? velocityX : -velocityX
            committed = (moved > totalWidth * 0.22) || (vel > 350)
        } else {
            let moved = isRTL ? -translationX : translationX
            let vel = isRTL ? -velocityX : velocityX
            committed = (moved > totalWidth * 0.22) || (vel > 350)
        }

        isTransitioning = true

        let targetOffset: CGFloat
        if activeIntent == .toNext {
            // Commit: 移出屏幕；Cancel: 弹回 0
            if committed {
                targetOffset = isRTL ? totalWidth : -totalWidth
            } else {
                targetOffset = 0
            }
        } else {
            // Commit: 完全覆盖到 0；Cancel: 弹回屏幕外
            if committed {
                targetOffset = 0
            } else {
                targetOffset = initialTopOffset
            }
        }

        let duration: TimeInterval = 0.26
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseOut],
            animations: {
                self.topSlotView.transform = CGAffineTransform(translationX: targetOffset, y: 0)
                if !committed && self.activeIntent == .toPrev {
                    self.shadowGradientLayer.opacity = 0.0
                }
            },
            completion: { _ in
                self.completeTransition(committed: committed)
            }
        )
    }

    private func completeTransition(committed: Bool) {
        isTransitioning = false

        if committed {
            playPageFeedback()

            if activeIntent == .toNext {
                // activeVC 已经滑出，将 incomingVC 确立为 activeVC
                activeVC?.willMove(toParent: nil)
                activeVC?.view.removeFromSuperview()
                activeVC?.removeFromParent()

                if let newActive = incomingVC {
                    newActive.view.removeFromSuperview()
                    newActive.view.frame = topSlotView.bounds
                    topSlotView.addSubview(newActive.view)
                    activeVC = newActive
                }
            } else {
                // activeVC 已被 incomingVC 覆盖，将 incomingVC 确立为 activeVC
                activeVC?.willMove(toParent: nil)
                activeVC?.view.removeFromSuperview()
                activeVC?.removeFromParent()
                activeVC = incomingVC
            }

            currentDisplayIndex = targetIndex
            coordinator.parent.currentPageIndex = targetIndex
        } else {
            // 取消翻页：还原层级并销毁 incomingVC
            if activeIntent == .toPrev {
                incomingVC?.willMove(toParent: nil)
                incomingVC?.view.removeFromSuperview()
                incomingVC?.removeFromParent()

                if let current = activeVC {
                    current.view.removeFromSuperview()
                    current.view.frame = topSlotView.bounds
                    topSlotView.addSubview(current.view)
                }
            } else {
                incomingVC?.willMove(toParent: nil)
                incomingVC?.view.removeFromSuperview()
                incomingVC?.removeFromParent()
            }
        }

        incomingVC = nil
        activeIntent = .none
        topSlotView.transform = .identity
        shadowGradientLayer.opacity = 0.0

        // 消化排队的程序化导航
        if let nextTarget = pendingTargetIndex, nextTarget != currentDisplayIndex {
            pendingTargetIndex = nil
            requestNavigation(to: nextTarget, animated: false)
        }
    }

    // MARK: - 阴影配置 (CAGradientLayer)

    private func configureShadow(edgeIsRight: Bool) {
        let darkColor = UIColor.black.withAlphaComponent(0.36).cgColor
        let lightColor = UIColor.black.withAlphaComponent(0.0).cgColor

        if edgeIsRight {
            shadowGradientLayer.colors = [darkColor, lightColor]
            shadowGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
            shadowGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        } else {
            shadowGradientLayer.colors = [lightColor, darkColor]
            shadowGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
            shadowGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        }
    }

    private func updateShadowFrame() {
        let isRTL = parentConfig.isRightToLeft
        let edgeIsRight = (activeIntent == .toNext) ? !isRTL : !isRTL
        let h = topSlotView.bounds.height

        if edgeIsRight {
            shadowGradientLayer.frame = CGRect(
                x: topSlotView.bounds.width,
                y: 0,
                width: shadowWidth,
                height: h
            )
        } else {
            shadowGradientLayer.frame = CGRect(
                x: -shadowWidth,
                y: 0,
                width: shadowWidth,
                height: h
            )
        }
    }

    // MARK: - 程序化页面导航 (外部 Slider/按钮跳转)

    public func requestNavigation(to newIndex: Int, animated: Bool) {
        guard parentConfig.pages.indices.contains(newIndex), newIndex != currentDisplayIndex else {
            return
        }

        if isTransitioning {
            pendingTargetIndex = newIndex
            return
        }

        guard animated else {
            displayPage(at: newIndex)
            return
        }

        isTransitioning = true
        let wantsNext = newIndex > currentDisplayIndex
        targetIndex = newIndex
        activeIntent = wantsNext ? .toNext : .toPrev

        beginInteractiveTransition(wantsNext: wantsNext, targetIndex: newIndex)

        let totalWidth = view.bounds.width
        let isRTL = parentConfig.isRightToLeft
        let endOffset: CGFloat
        if wantsNext {
            endOffset = isRTL ? totalWidth : -totalWidth
        } else {
            endOffset = 0
        }

        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut],
            animations: {
                self.topSlotView.transform = CGAffineTransform(translationX: endOffset, y: 0)
            },
            completion: { _ in
                self.completeTransition(committed: true)
            }
        )
    }

    // MARK: - 触觉与音效反馈

    public func ensureInitialPageOrNavigate(to targetIndex: Int) {
        guard parentConfig.pages.indices.contains(targetIndex) else { return }
        if activeVC == nil {
            displayPage(at: targetIndex)
        } else if currentDisplayIndex != targetIndex {
            requestNavigation(to: targetIndex, animated: true)
        }
    }

    private func playPageFeedback() {
        feedbackGenerator.impactOccurred()
        if parentConfig.soundEnabled {
            // 系统轻触翻书轻音
            AudioServicesPlaySystemSound(1104)
        }
    }
}
