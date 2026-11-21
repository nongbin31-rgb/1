import AudioToolbox
import SwiftUI
import UIKit

/// 自定义水平阻尼磁吸分页流式布局（基于全屏尺寸与系统原生分页引擎联动）
public final class SnapPageFlowLayout: UICollectionViewFlowLayout {
    public override init() {
        super.init()
        scrollDirection = .horizontal
        minimumLineSpacing = 0
        minimumInteritemSpacing = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// 磁吸吸附滑动与零延迟即时阅读容器（基于 UICollectionView + 原生整页吸附）
/// 特性：
/// 1. 消除手势冲突：单页放大缩放时动态锁死外层横向滑动，恢复 1.0 时释放；
/// 2. 磁吸对齐：滑行减速时自动整页吸附，无半页停靠，彻底解决 RTL 与 LTR 下的反向跳页震荡；
/// 3. 单向状态驱动：精准区分手势滚动与代码导航，彻底杜绝“来回翻”死循环；
/// 4. 零延迟模式：关闭动画时以毫秒级即时跳转；
/// 5. RTL/LTR 原生感知与触觉联动。
public struct SnapPageReaderView: UIViewControllerRepresentable {
    public let pages: [MangaPage]
    public let upscalerConfig: ImageUpscalerConfig
    public let enableUpscaler: Bool
    public let transitionAfterUpscaled: Bool
    public let filterConfig: ImageFilterConfig
    public let isCompareMode: Bool
    public let isRightToLeft: Bool
    public let turningEffect: PageTurningEffect
    public let soundEnabled: Bool
    public let background: ReaderBackground
    public let texture: ReaderTextureType
    public let textureOpacity: Double
    public let textureTintOpacity: Double
    public let textureGrainDensity: Double
    public let textureTarget: ReaderTextureTarget
    public let imageOnlyBackdrop: ReaderImageOnlyBackdrop
    @Binding public var currentPageIndex: Int
    public var externalJumpNonce: Int = 0
    public let onSingleTap: () -> Void
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
        turningEffect: PageTurningEffect,
        soundEnabled: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget = .both,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        currentPageIndex: Binding<Int>,
        externalJumpNonce: Int = 0,
        onSingleTap: @escaping () -> Void,
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
        self.turningEffect = turningEffect
        self.soundEnabled = soundEnabled
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = textureTintOpacity
        self.textureGrainDensity = textureGrainDensity
        self.textureTarget = textureTarget
        self.imageOnlyBackdrop = imageOnlyBackdrop
        self._currentPageIndex = currentPageIndex
        self.externalJumpNonce = externalJumpNonce
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onImageLoaded = onImageLoaded
        self.onPageReady = onPageReady
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIViewController(context: Context) -> SnapPageViewController {
        let vc = SnapPageViewController(coordinator: context.coordinator)
        context.coordinator.viewController = vc
        return vc
    }

    public func updateUIViewController(_ uiViewController: SnapPageViewController, context: Context) {
        context.coordinator.parent = self

        // 1. 更新背景颜色
        uiViewController.updateBackgroundStyle(background)

        // 2. 立即更新当前可见 Cell 的超分状态、滤镜配置、对比模式、背景与纸质纹理，无需等待翻页
        uiViewController.updateVisibleCellsConfiguration(
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
            imageOnlyBackdrop: imageOnlyBackdrop
        )

        let isExternalJump = (context.coordinator.lastExternalJumpNonce != externalJumpNonce)
        if isExternalJump {
            context.coordinator.lastExternalJumpNonce = externalJumpNonce
        }

        uiViewController.applyConfiguration(
            pages: pages,
            isRightToLeft: isRightToLeft,
            targetIndex: currentPageIndex,
            animated: isExternalJump ? false : (turningEffect == .snapPage),
            forceImmediate: isExternalJump
        )
    }

    public final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: SnapPageReaderView
        weak var viewController: SnapPageViewController?
        var lastExternalJumpNonce: Int = 0
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

        init(parent: SnapPageReaderView) {
            self.parent = parent
            super.init()
            self.feedbackGenerator.prepare()
        }

        public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.pages.count
        }

        public func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SnapPageHostingCell.reuseIdentifier,
                for: indexPath
            ) as? SnapPageHostingCell else {
                return UICollectionViewCell()
            }

            let page = parent.pages[indexPath.item]
            cell.configure(
                page: page,
                config: parent.upscalerConfig,
                isEnabled: parent.enableUpscaler,
                transitionAfterUpscaled: parent.transitionAfterUpscaled,
                filterConfig: parent.filterConfig,
                isCompareMode: parent.isCompareMode,
                isRightToLeft: parent.isRightToLeft,
                background: parent.background,
                texture: parent.texture,
                textureOpacity: parent.textureOpacity,
                textureTintOpacity: parent.textureTintOpacity,
                textureGrainDensity: parent.textureGrainDensity,
                textureTarget: parent.textureTarget,
                imageOnlyBackdrop: parent.imageOnlyBackdrop,
                onSingleTap: parent.onSingleTap,
                onStatusUpdate: parent.onStatusUpdate,
                onZoomChanged: { [weak collectionView] scale in
                    // 核心手势隔离：当单页处于放大状态时，锁死外层水平翻页手势，杜绝冲突！
                    let shouldEnableScroll = scale <= 1.01
                    if collectionView?.isScrollEnabled != shouldEnableScroll {
                        collectionView?.isScrollEnabled = shouldEnableScroll
                    }
                },
                onImageLoaded: { [weak self] img in
                    if indexPath.item == self?.parent.currentPageIndex {
                        self?.parent.onImageLoaded?(img)
                    }
                },
                onPageReady: { [weak self] readyIndex in
                    self?.parent.onPageReady?(readyIndex)
                }
            )
            return cell
        }

        public func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            collectionView.bounds.size
        }

        // 手势开始拖拽：解除可能遗留的代码滚动状态
        public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            viewController?.isProgrammaticScrolling = false
        }

        // 惯性减速停止
        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            viewController?.handlePageSettled()
        }

        // 慢速拖拽释放（未触发惯性减速）
        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                viewController?.handlePageSettled()
            }
        }

        // 代码动画滚动完成
        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            viewController?.isProgrammaticScrolling = false
            viewController?.handlePageSettled()
        }

        func playPageFeedback() {
            feedbackGenerator.impactOccurred()
            if parent.soundEnabled {
                AudioServicesPlaySystemSound(1104)
            }
        }
    }
}

public final class SnapPageViewController: UIViewController {
    fileprivate let coordinator: SnapPageReaderView.Coordinator
    var collectionView: UICollectionView!
    fileprivate var layout: SnapPageFlowLayout!

    fileprivate var currentDisplayIndex: Int
    fileprivate var pages: [MangaPage] = []
    fileprivate var pendingTargetIndex: Int?
    fileprivate var isProgrammaticScrolling = false
    fileprivate var hasInitiallyPositioned = false

    init(coordinator: SnapPageReaderView.Coordinator) {
        self.coordinator = coordinator
        self.currentDisplayIndex = coordinator.parent.currentPageIndex
        self.pages = coordinator.parent.pages
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateBackgroundStyle(_ background: ReaderBackground) {
        let color: UIColor
        switch background {
        case .followSystem:
            color = .systemBackground
        case .light:
            color = .white
        case .dark:
            color = .black
        case .immersive, .texture:
            color = .clear
        }
        view.backgroundColor = color
        if isViewLoaded {
            collectionView?.backgroundColor = color
        }
    }

    /// 立即同步所有可见 Cell 的超分状态、排版方向与背景材质（关键修复：开启超分/切换模式时当前页即时生效）
    func updateVisibleCellsConfiguration(
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
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    ) {
        guard isViewLoaded, let cv = collectionView else { return }
        for cell in cv.visibleCells {
            if let hostingCell = cell as? SnapPageHostingCell {
                hostingCell.updateConfiguration(
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
                    textureGrainDensity: textureGrainDensity,
                    textureTarget: textureTarget,
                    imageOnlyBackdrop: imageOnlyBackdrop
                )
            }
        }
        let currentIndexPath = IndexPath(item: currentDisplayIndex, section: 0)
        if let currentCell = cv.cellForItem(at: currentIndexPath) as? SnapPageHostingCell {
            currentCell.updateConfiguration(
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
                textureGrainDensity: textureGrainDensity,
                textureTarget: textureTarget,
                imageOnlyBackdrop: imageOnlyBackdrop
            )
        }
    }

    func updateVisibleCellsCompareMode(_ isCompareMode: Bool) {
        guard isViewLoaded, let cv = collectionView else { return }
        for cell in cv.visibleCells {
            if let hostingCell = cell as? SnapPageHostingCell {
                hostingCell.updateCompareMode(isCompareMode)
            }
        }
    }

    func updateVisibleCellsBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    ) {
        guard isViewLoaded, let cv = collectionView else { return }
        for cell in cv.visibleCells {
            if let hostingCell = cell as? SnapPageHostingCell {
                hostingCell.updateBackground(
                    background: background,
                    texture: texture,
                    textureOpacity: textureOpacity,
                    textureTintOpacity: textureTintOpacity,
                    textureGrainDensity: textureGrainDensity,
                    textureTarget: textureTarget,
                    imageOnlyBackdrop: imageOnlyBackdrop
                )
            }
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        updateBackgroundStyle(coordinator.parent.background)

        layout = SnapPageFlowLayout()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = view.backgroundColor
        collectionView.isPagingEnabled = true
        collectionView.decelerationRate = .fast
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        collectionView.register(
            SnapPageHostingCell.self,
            forCellWithReuseIdentifier: SnapPageHostingCell.reuseIdentifier
        )

        view.addSubview(collectionView)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        if layout.itemSize != size {
            layout.itemSize = size
            layout.invalidateLayout()
        }

        if let pending = pendingTargetIndex {
            pendingTargetIndex = nil
            scrollToPage(at: pending, animated: false)
        } else if !hasInitiallyPositioned && pages.indices.contains(currentDisplayIndex) {
            hasInitiallyPositioned = true
            scrollToPage(at: currentDisplayIndex, animated: false)
        }
    }

    func applyConfiguration(
        pages: [MangaPage],
        isRightToLeft: Bool,
        targetIndex: Int,
        animated: Bool,
        forceImmediate: Bool = false
    ) {
        guard isViewLoaded else { return }

        let oldPages = self.pages
        self.pages = pages

        let semantic: UISemanticContentAttribute = isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        if collectionView.semanticContentAttribute != semantic {
            collectionView.semanticContentAttribute = semantic
            collectionView.reloadData()
            currentDisplayIndex = targetIndex
            scrollToPage(at: targetIndex, animated: false, forceReposition: true)
            return
        }

        let isFirstDataLoad = (oldPages.isEmpty && !pages.isEmpty)
        if oldPages != pages {
            collectionView.reloadData()
        }

        guard pages.indices.contains(targetIndex) else { return }

        if isFirstDataLoad || !hasInitiallyPositioned {
            hasInitiallyPositioned = true
            currentDisplayIndex = targetIndex
            collectionView.layoutIfNeeded()
            scrollToPage(at: targetIndex, animated: false, forceReposition: true)
            DispatchQueue.main.async { [weak self] in
                self?.scrollToPage(at: targetIndex, animated: false, forceReposition: true)
            }
            return
        }

        // 外部进度条或锚点显式指令直接定位：强制清掉在途滚动状态无动画直达
        if forceImmediate {
            isProgrammaticScrolling = false
            currentDisplayIndex = targetIndex
            scrollToPage(at: targetIndex, animated: false, forceReposition: true)
            return
        }

        // 如果展示的当前页与 targetIndex 一致，则无需额外滚动
        if currentDisplayIndex == targetIndex {
            return
        }

        // 如果用户正在拖拽交互中，避免外部状态更新打断手势
        if collectionView.isTracking || collectionView.isDragging {
            return
        }

        currentDisplayIndex = targetIndex
        scrollToPage(at: targetIndex, animated: animated)
    }

    func scrollToPage(at index: Int, animated: Bool, forceReposition: Bool = false) {
        guard pages.indices.contains(index) else { return }
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
            pendingTargetIndex = index
            return
        }

        let indexPath = IndexPath(item: index, section: 0)

        if !forceReposition, let current = determineCurrentPageIndex(), current == index {
            isProgrammaticScrolling = false
            return
        }

        if !collectionView.isScrollEnabled {
            collectionView.isScrollEnabled = true
        }

        if animated {
            isProgrammaticScrolling = true
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: true)
        } else {
            isProgrammaticScrolling = false
            collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: false)
        }
    }

    func determineCurrentPageIndex() -> Int? {
        guard let cv = collectionView, cv.bounds.width > 0, cv.bounds.height > 0 else { return nil }
        let centerPoint = CGPoint(x: cv.bounds.midX, y: cv.bounds.midY)
        if let indexPath = cv.indexPathForItem(at: centerPoint) {
            return indexPath.item
        }
        let visibleIndexPaths = cv.indexPathsForVisibleItems
        guard !visibleIndexPaths.isEmpty else { return nil }
        let closest = visibleIndexPaths.min(by: { a, b in
            let centerA = cv.layoutAttributesForItem(at: a)?.center.x ?? .greatestFiniteMagnitude
            let centerB = cv.layoutAttributesForItem(at: b)?.center.x ?? .greatestFiniteMagnitude
            return abs(centerA - centerPoint.x) < abs(centerB - centerPoint.x)
        })
        return closest?.item
    }

    func handlePageSettled() {
        guard !isProgrammaticScrolling else { return }
        guard let newIndex = determineCurrentPageIndex() else { return }
        guard pages.indices.contains(newIndex) else { return }

        if currentDisplayIndex != newIndex {
            currentDisplayIndex = newIndex
            if coordinator.parent.currentPageIndex != newIndex {
                coordinator.parent.currentPageIndex = newIndex
                coordinator.playPageFeedback()
            }
        }
    }
}

/// 通过显式绑定 page.id 保证 UICollectionViewCell 复用时 SwiftUI 正确重建单页状态与缩放视图；
/// 同一页面更新超分/对比/背景配置时 page.id 不变，保留已加载原图并原地刷新
private struct SnapPageRootView: View {
    let pageView: ComicPageCellView

    var body: some View {
        pageView.id(pageView.page.id)
    }
}

/// 承载 ComicPageCellView 的 UICollectionViewCell
final class SnapPageHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "SnapPageHostingCell"

    private var hostingController: UIHostingController<SnapPageRootView>?
    private var currentPage: MangaPage?
    private var currentConfig: ImageUpscalerConfig?
    private var currentIsEnabled: Bool = false
    private var currentTransitionAfterUpscaled: Bool = true
    private var currentFilterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    private var currentIsCompareMode: Bool = false
    private var currentIsRightToLeft: Bool = false
    private var currentBackground: ReaderBackground = .followSystem
    private var currentTexture: ReaderTextureType = .classic
    private var currentTextureOpacity: Double = 0.4
    private var currentTextureTintOpacity: Double = 1.0
    private var currentTextureGrainDensity: Double = 1.0
    private var currentTextureTarget: ReaderTextureTarget = .both
    private var currentImageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    private var currentOnSingleTap: (() -> Void)?
    private var currentOnStatusUpdate: ((String) -> Void)?
    private var currentOnZoomChanged: ((CGFloat) -> Void)?
    private var currentOnImageLoaded: ((UIImage) -> Void)?
    private var currentOnPageReady: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    func configure(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool,
        isRightToLeft: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget = .both,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: @escaping (CGFloat) -> Void,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onPageReady: ((Int) -> Void)? = nil
    ) {
        self.currentPage = page
        self.currentConfig = config
        self.currentIsEnabled = isEnabled
        self.currentTransitionAfterUpscaled = transitionAfterUpscaled
        self.currentFilterConfig = filterConfig
        self.currentIsCompareMode = isCompareMode
        self.currentIsRightToLeft = isRightToLeft
        self.currentBackground = background
        self.currentTexture = texture
        self.currentTextureOpacity = textureOpacity
        self.currentTextureTintOpacity = textureTintOpacity
        self.currentTextureGrainDensity = textureGrainDensity
        self.currentTextureTarget = textureTarget
        self.currentImageOnlyBackdrop = imageOnlyBackdrop
        self.currentOnSingleTap = onSingleTap
        self.currentOnStatusUpdate = onStatusUpdate
        self.currentOnZoomChanged = onZoomChanged
        self.currentOnImageLoaded = onImageLoaded
        self.currentOnPageReady = onPageReady

        let rootView = SnapPageRootView(pageView: buildPageView())
        let hostBgColor = ReaderTextureCache.resolvedHostUIColor(
            background: background,
            texture: texture,
            tintOpacity: textureTintOpacity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop
        )

        if let existing = hostingController {
            existing.view.backgroundColor = hostBgColor
            existing.rootView = rootView
        } else {
            let hc = UIHostingController(rootView: rootView)
            hc.view.backgroundColor = hostBgColor
            if #available(iOS 16.4, *) {
                hc.safeAreaRegions = []
            }
            hc.view.frame = contentView.bounds
            hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(hc.view)
            hostingController = hc
        }
    }

    /// 全面动态同步页面超分配置、排版方向与背景材质（关键修复：开启超分/切换模式时当前页即时生效）
    func updateConfiguration(
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
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    ) {
        guard currentPage != nil else { return }

        let upscalerChanged = currentConfig != config
            || currentIsEnabled != isEnabled
            || currentTransitionAfterUpscaled != transitionAfterUpscaled
            || currentFilterConfig != filterConfig
            || currentIsCompareMode != isCompareMode

        let layoutChanged = currentIsRightToLeft != isRightToLeft

        let backgroundChanged = currentBackground != background
            || currentTexture != texture
            || currentTextureOpacity != textureOpacity
            || currentTextureTintOpacity != textureTintOpacity
            || currentTextureGrainDensity != textureGrainDensity
            || currentTextureTarget != textureTarget
            || currentImageOnlyBackdrop != imageOnlyBackdrop

        guard upscalerChanged || layoutChanged || backgroundChanged else {
            return
        }

        self.currentConfig = config
        self.currentIsEnabled = isEnabled
        self.currentTransitionAfterUpscaled = transitionAfterUpscaled
        self.currentFilterConfig = filterConfig
        self.currentIsCompareMode = isCompareMode
        self.currentIsRightToLeft = isRightToLeft
        self.currentBackground = background
        self.currentTexture = texture
        self.currentTextureOpacity = textureOpacity
        self.currentTextureTintOpacity = textureTintOpacity
        self.currentTextureGrainDensity = textureGrainDensity
        self.currentTextureTarget = textureTarget
        self.currentImageOnlyBackdrop = imageOnlyBackdrop

        if let existing = hostingController {
            existing.view.backgroundColor = ReaderTextureCache.resolvedHostUIColor(
                background: background,
                texture: texture,
                tintOpacity: textureTintOpacity,
                textureTarget: textureTarget,
                imageOnlyBackdrop: imageOnlyBackdrop
            )
            existing.rootView = SnapPageRootView(pageView: buildPageView())
        }
    }

    func updateCompareMode(_ isCompareMode: Bool) {
        guard currentPage != nil, currentIsCompareMode != isCompareMode else { return }
        self.currentIsCompareMode = isCompareMode
        if let existing = hostingController {
            existing.rootView = SnapPageRootView(pageView: buildPageView())
        }
    }

    func updateBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint
    ) {
        updateConfiguration(
            config: currentConfig ?? ImageUpscalerConfig(),
            isEnabled: currentIsEnabled,
            transitionAfterUpscaled: currentTransitionAfterUpscaled,
            isCompareMode: currentIsCompareMode,
            isRightToLeft: currentIsRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureGrainDensity: textureGrainDensity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop
        )
    }

    private func buildPageView() -> ComicPageCellView {
        guard let page = currentPage, let config = currentConfig else {
            return ComicPageCellView(
                page: MangaPage(index: 0, imageURL: ""),
                config: ImageUpscalerConfig(),
                background: currentBackground,
                texture: currentTexture,
                textureOpacity: currentTextureOpacity,
                textureTintOpacity: currentTextureTintOpacity,
                textureGrainDensity: currentTextureGrainDensity,
                textureTarget: currentTextureTarget,
                imageOnlyBackdrop: currentImageOnlyBackdrop,
                onSingleTap: {},
                onStatusUpdate: { _ in }
            )
        }
        return ComicPageCellView(
            page: page,
            config: config,
            isEnabled: currentIsEnabled,
            transitionAfterUpscaled: currentTransitionAfterUpscaled,
            filterConfig: currentFilterConfig,
            isCompareMode: currentIsCompareMode,
            showSpineShadow: false,
            isRightToLeft: currentIsRightToLeft,
            background: currentBackground,
            texture: currentTexture,
            textureOpacity: currentTextureOpacity,
            textureTintOpacity: currentTextureTintOpacity,
            textureGrainDensity: currentTextureGrainDensity,
            textureTarget: currentTextureTarget,
            imageOnlyBackdrop: currentImageOnlyBackdrop,
            onSingleTap: currentOnSingleTap ?? {},
            onStatusUpdate: currentOnStatusUpdate ?? { _ in },
            onZoomChanged: currentOnZoomChanged,
            onImageLoaded: currentOnImageLoaded,
            onPageReady: currentOnPageReady
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let hcView = hostingController?.view, hcView.frame != contentView.bounds {
            hcView.frame = contentView.bounds
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentPage = nil
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }
}
