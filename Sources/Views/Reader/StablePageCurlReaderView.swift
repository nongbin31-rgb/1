import AudioToolbox
import SwiftUI
import UIKit

/// 仿真书本卷页阅读容器（基于原生 UIPageViewController TransitionStyle.pageCurl）
/// 特性：
/// 1. 具备排队状态机，解决快速手势/点击导致的重入崩溃；
/// 2. 日漫 (RTL) 与美漫 (LTR) 数据源与转场方向双向映射；
/// 3. 支持书脊中缝立体阴影与纸张背面透光感；
/// 4. 翻页时伴随 Taptic Engine 微触觉与拟真翻书轻音。
public struct StablePageCurlReaderView: UIViewControllerRepresentable {
    public let pages: [MangaPage]
    public let upscalerConfig: ImageUpscalerConfig
    public let enableUpscaler: Bool
    public let transitionAfterUpscaled: Bool
    public let filterConfig: ImageFilterConfig
    public let isCompareMode: Bool
    public let isRightToLeft: Bool
    public let soundEnabled: Bool
    public let showSpineShadow: Bool
    public let background: ReaderBackground
    public let texture: ReaderTextureType
    public let textureOpacity: Double
    public let textureTintOpacity: Double
    public let textureGrainDensity: Double
    public let textureTarget: ReaderTextureTarget
    public let imageOnlyBackdrop: ReaderImageOnlyBackdrop
    public let showDividingLine: Bool
    @Binding public var currentPageIndex: Int
    public var externalJumpNonce: Int = 0
    public let onSingleTap: () -> Void
    public var onTapLocation: ((CGFloat, Bool) -> Void)? = nil
    public let onStatusUpdate: (String) -> Void
    public var onImageLoaded: ((UIImage) -> Void)? = nil
    public var onPageReady: ((Int) -> Void)? = nil

    public init(
        pages: [MangaPage],
        upscalerConfig: ImageUpscalerConfig,
        enableUpscaler: Bool = false,
        transitionAfterUpscaled: Bool = true,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool,
        isRightToLeft: Bool,
        soundEnabled: Bool,
        showSpineShadow: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget = .both,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        showDividingLine: Bool = true,
        currentPageIndex: Binding<Int>,
        externalJumpNonce: Int = 0,
        onSingleTap: @escaping () -> Void,
        onTapLocation: ((CGFloat, Bool) -> Void)? = nil,
        onStatusUpdate: @escaping (String) -> Void,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onPageReady: ((Int) -> Void)? = nil
    ) {
        self.pages = pages
        self.upscalerConfig = upscalerConfig
        self.enableUpscaler = enableUpscaler
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.filterConfig = filterConfig
        self.isCompareMode = isCompareMode
        self.isRightToLeft = isRightToLeft
        self.soundEnabled = soundEnabled
        self.showSpineShadow = showSpineShadow
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = textureTintOpacity
        self.textureGrainDensity = textureGrainDensity
        self.textureTarget = textureTarget
        self.imageOnlyBackdrop = imageOnlyBackdrop
        self.showDividingLine = showDividingLine
        self._currentPageIndex = currentPageIndex
        self.externalJumpNonce = externalJumpNonce
        self.onSingleTap = onSingleTap
        self.onTapLocation = onTapLocation
        self.onStatusUpdate = onStatusUpdate
        self.onImageLoaded = onImageLoaded
        self.onPageReady = onPageReady
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIViewController(context: Context) -> UIPageViewController {
        let options: [UIPageViewController.OptionsKey: Any] = [
            .spineLocation: UIPageViewController.SpineLocation.min.rawValue
        ]
        let pageVC = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: options
        )
        pageVC.view.backgroundColor = (background == .immersive || background == .texture) ? .clear : .black
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator

        // 禁用 UIPageViewController(.pageCurl) 内置的左右边缘点击翻页手势，
        // 保留 UIPanGestureRecognizer 拖拽卷页，将点击热区与方向翻转权统一收口到 ReaderView。
        for recognizer in pageVC.gestureRecognizers where recognizer is UITapGestureRecognizer {
            recognizer.isEnabled = false
        }

        context.coordinator.pageViewController = pageVC

        if let initialVC = context.coordinator.createViewController(for: currentPageIndex) {
            pageVC.setViewControllers([initialVC], direction: .forward, animated: false)
        }

        return pageVC
    }

    public func updateUIViewController(_ uiViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self

        // 更新背景底色
        switch background {
        case .followSystem:
            uiViewController.view.backgroundColor = .systemBackground
        case .light:
            uiViewController.view.backgroundColor = .white
        case .dark:
            uiViewController.view.backgroundColor = .black
        case .immersive, .texture:
            uiViewController.view.backgroundColor = .clear
        }

        // 立即更新当前可见子页面的超分状态、滤镜配置、对比模式、背景与纸质纹理，无需等待翻页
        if let currentVCs = uiViewController.viewControllers as? [ComicPageHostingController] {
            for vc in currentVCs {
                vc.updateConfiguration(
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
                    textureGrainDensity: textureGrainDensity,
                    textureTarget: textureTarget,
                    imageOnlyBackdrop: imageOnlyBackdrop,
                    showSpineShadow: showSpineShadow,
                    showDividingLine: showDividingLine
                )
            }
        }

        // 当外部（例如进度条跳转、返回锚点或上一话/下一话按钮）修改了页码时，按需即时直达或平滑驱动底层翻页
        let isExternalJump = (context.coordinator.lastExternalJumpNonce != externalJumpNonce)
        if isExternalJump {
            context.coordinator.lastExternalJumpNonce = externalJumpNonce
        }

        let activeIndex = context.coordinator.currentDisplayIndex
        if (uiViewController.viewControllers?.isEmpty ?? true) && pages.indices.contains(currentPageIndex) {
            if let initialVC = context.coordinator.createViewController(for: currentPageIndex) {
                context.coordinator.currentDisplayIndex = currentPageIndex
                uiViewController.setViewControllers([initialVC], direction: .forward, animated: false)
            }
        } else if activeIndex != currentPageIndex && pages.indices.contains(currentPageIndex) {
            context.coordinator.requestNavigation(to: currentPageIndex, animated: !isExternalJump)
        }
    }

    public final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: StablePageCurlReaderView
        weak var pageViewController: UIPageViewController?

        var currentDisplayIndex: Int = 0
        var lastExternalJumpNonce: Int = 0
        private var isTransitioning = false
        private var pendingTargetIndex: Int?
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

        init(parent: StablePageCurlReaderView) {
            self.parent = parent
            self.currentDisplayIndex = parent.currentPageIndex
            super.init()
            self.feedbackGenerator.prepare()
        }

        // MARK: - 安全状态机导航（消除原生 PageCurl 重入崩溃）

        func requestNavigation(to targetIndex: Int, animated: Bool) {
            guard parent.pages.indices.contains(targetIndex), targetIndex != currentDisplayIndex else {
                return
            }

            if isTransitioning {
                pendingTargetIndex = targetIndex
                return
            }

            guard let targetVC = createViewController(for: targetIndex) else { return }
            isTransitioning = true

            // 日漫与常规漫方向映射：日漫向右翻回旧页（reverse），向左翻看新页（forward）
            let movingForward = parent.isRightToLeft ? (targetIndex < currentDisplayIndex) : (targetIndex > currentDisplayIndex)
            let direction: UIPageViewController.NavigationDirection = movingForward ? .forward : .reverse

            if animated {
                playPageFeedback()
            }

            pageViewController?.setViewControllers([targetVC], direction: direction, animated: animated) { [weak self] _ in
                guard let self = self else { return }
                self.isTransitioning = false
                self.currentDisplayIndex = targetIndex
                self.parent.currentPageIndex = targetIndex

                // 消化排队的跳转请求
                if let next = self.pendingTargetIndex, next != targetIndex {
                    self.pendingTargetIndex = nil
                    self.requestNavigation(to: next, animated: false)
                }
            }
        }

        // MARK: - UIPageViewControllerDataSource (日漫/常规反向映射)

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? ComicPageHostingController else { return nil }
            // 日漫：向左滑动取下一页；常规：向左滑动取上一页
            let targetIndex = parent.isRightToLeft ? (current.pageIndex + 1) : (current.pageIndex - 1)
            return createViewController(for: targetIndex)
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let current = viewController as? ComicPageHostingController else { return nil }
            // 日漫：向右滑动取上一页；常规：向右滑动取下一页
            let targetIndex = parent.isRightToLeft ? (current.pageIndex - 1) : (current.pageIndex + 1)
            return createViewController(for: targetIndex)
        }

        // MARK: - UIPageViewControllerDelegate

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            willTransitionTo pendingViewControllers: [UIViewController]
        ) {
            isTransitioning = true
        }

        public func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            isTransitioning = false
            if completed, let currentVC = pageViewController.viewControllers?.first as? ComicPageHostingController {
                currentDisplayIndex = currentVC.pageIndex
                parent.currentPageIndex = currentVC.pageIndex
                playPageFeedback()
            }

            if let next = pendingTargetIndex {
                pendingTargetIndex = nil
                requestNavigation(to: next, animated: false)
            }
        }

        func createViewController(for index: Int) -> ComicPageHostingController? {
            guard parent.pages.indices.contains(index) else { return nil }
            let page = parent.pages[index]
            return ComicPageHostingController(
                pageIndex: index,
                page: page,
                config: parent.upscalerConfig,
                isEnabled: parent.enableUpscaler,
                transitionAfterUpscaled: parent.transitionAfterUpscaled,
                filterConfig: parent.filterConfig,
                isCompareMode: parent.isCompareMode,
                showSpineShadow: parent.showSpineShadow,
                isRightToLeft: parent.isRightToLeft,
                background: parent.background,
                texture: parent.texture,
                textureOpacity: parent.textureOpacity,
                textureTintOpacity: parent.textureTintOpacity,
                textureGrainDensity: parent.textureGrainDensity,
                textureTarget: parent.textureTarget,
                imageOnlyBackdrop: parent.imageOnlyBackdrop,
                showDividingLine: parent.showDividingLine,
                onSingleTap: { [weak self] in
                    self?.parent.onSingleTap()
                },
                onTapLocation: { [weak self] normalizedX, isZoomed in
                    if let handler = self?.parent.onTapLocation {
                        handler(normalizedX, isZoomed)
                    } else {
                        self?.parent.onSingleTap()
                    }
                },
                onStatusUpdate: parent.onStatusUpdate,
                onImageLoaded: { [weak self] img in
                    if index == self?.parent.currentPageIndex {
                        self?.parent.onImageLoaded?(img)
                    }
                },
                onPageReady: { [weak self] readyIndex in
                    self?.parent.onPageReady?(readyIndex)
                }
            )
        }

        private func playPageFeedback() {
            feedbackGenerator.impactOccurred()
            if parent.soundEnabled {
                // 系统轻触翻书音
                AudioServicesPlaySystemSound(1104)
            }
        }
    }
}
