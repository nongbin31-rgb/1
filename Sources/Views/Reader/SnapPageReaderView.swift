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
    public let isCompareMode: Bool
    public let isRightToLeft: Bool
    public let turningEffect: PageTurningEffect
    public let soundEnabled: Bool
    public let background: ReaderBackground
    public let texture: ReaderTextureType
    public let textureOpacity: Double
    @Binding public var currentPageIndex: Int
    public let onSingleTap: () -> Void
    public let onStatusUpdate: (String) -> Void
    public var onImageLoaded: ((UIImage) -> Void)? = nil

    public init(
        pages: [MangaPage],
        upscalerConfig: ImageUpscalerConfig,
        enableUpscaler: Bool = false,
        transitionAfterUpscaled: Bool = true,
        isCompareMode: Bool,
        isRightToLeft: Bool,
        turningEffect: PageTurningEffect,
        soundEnabled: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        currentPageIndex: Binding<Int>,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.pages = pages
        self.upscalerConfig = upscalerConfig
        self.enableUpscaler = enableUpscaler
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.isCompareMode = isCompareMode
        self.isRightToLeft = isRightToLeft
        self.turningEffect = turningEffect
        self.soundEnabled = soundEnabled
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self._currentPageIndex = currentPageIndex
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onImageLoaded = onImageLoaded
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

        // 2. 立即更新当前可见 Cell 的背景与纸质纹理，无需等待下一页
        uiViewController.updateVisibleCellsBackground(
            background: background,
            texture: texture,
            textureOpacity: textureOpacity
        )

        uiViewController.applyConfiguration(
            pages: pages,
            isRightToLeft: isRightToLeft,
            targetIndex: currentPageIndex,
            animated: turningEffect == .snapPage
        )
    }

    public final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: SnapPageReaderView
        weak var viewController: SnapPageViewController?
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
                isCompareMode: parent.isCompareMode,
                isRightToLeft: parent.isRightToLeft,
                background: parent.background,
                texture: parent.texture,
                textureOpacity: parent.textureOpacity,
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

    func updateVisibleCellsBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double
    ) {
        guard isViewLoaded, let cv = collectionView else { return }
        for cell in cv.visibleCells {
            if let hostingCell = cell as? SnapPageHostingCell {
                hostingCell.updateBackground(
                    background: background,
                    texture: texture,
                    textureOpacity: textureOpacity
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

    func applyConfiguration(pages: [MangaPage], isRightToLeft: Bool, targetIndex: Int, animated: Bool) {
        guard isViewLoaded else { return }

        let oldPagesCount = self.pages.count
        self.pages = pages

        let semantic: UISemanticContentAttribute = isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        if collectionView.semanticContentAttribute != semantic {
            collectionView.semanticContentAttribute = semantic
            collectionView.reloadData()
            currentDisplayIndex = targetIndex
            scrollToPage(at: targetIndex, animated: false)
            return
        }

        let isFirstDataLoad = (oldPagesCount == 0 && !pages.isEmpty)
        if oldPagesCount != pages.count {
            collectionView.reloadData()
        }

        guard pages.indices.contains(targetIndex) else { return }

        if isFirstDataLoad || !hasInitiallyPositioned {
            hasInitiallyPositioned = true
            currentDisplayIndex = targetIndex
            scrollToPage(at: targetIndex, animated: false)
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

    func scrollToPage(at index: Int, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        guard collectionView.bounds.width > 0, collectionView.bounds.height > 0 else {
            pendingTargetIndex = index
            return
        }

        let indexPath = IndexPath(item: index, section: 0)

        if let current = determineCurrentPageIndex(), current == index {
            isProgrammaticScrolling = false
            return
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

/// 承载 ComicPageCellView 的 UICollectionViewCell
final class SnapPageHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "SnapPageHostingCell"

    private var hostingController: UIHostingController<ComicPageCellView>?
    private var currentPage: MangaPage?
    private var currentConfig: ImageUpscalerConfig?
    private var currentIsEnabled: Bool = false
    private var currentTransitionAfterUpscaled: Bool = true
    private var currentIsCompareMode: Bool = false
    private var currentIsRightToLeft: Bool = false
    private var currentBackground: ReaderBackground = .followSystem
    private var currentTexture: ReaderTextureType = .classic
    private var currentTextureOpacity: Double = 0.4
    private var currentOnSingleTap: (() -> Void)?
    private var currentOnStatusUpdate: ((String) -> Void)?
    private var currentOnZoomChanged: ((CGFloat) -> Void)?
    private var currentOnImageLoaded: ((UIImage) -> Void)?

    func configure(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        isCompareMode: Bool,
        isRightToLeft: Bool,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: @escaping (CGFloat) -> Void,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.currentPage = page
        self.currentConfig = config
        self.currentIsEnabled = isEnabled
        self.currentTransitionAfterUpscaled = transitionAfterUpscaled
        self.currentIsCompareMode = isCompareMode
        self.currentIsRightToLeft = isRightToLeft
        self.currentBackground = background
        self.currentTexture = texture
        self.currentTextureOpacity = textureOpacity
        self.currentOnSingleTap = onSingleTap
        self.currentOnStatusUpdate = onStatusUpdate
        self.currentOnZoomChanged = onZoomChanged
        self.currentOnImageLoaded = onImageLoaded

        let pageView = buildPageView()

        if let existing = hostingController {
            existing.rootView = pageView
        } else {
            let hc = UIHostingController(rootView: pageView)
            hc.view.backgroundColor = .clear
            hc.view.frame = contentView.bounds
            hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            contentView.addSubview(hc.view)
            hostingController = hc
        }
    }

    func updateBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double
    ) {
        guard currentBackground != background || currentTexture != texture || currentTextureOpacity != textureOpacity else {
            return
        }
        self.currentBackground = background
        self.currentTexture = texture
        self.currentTextureOpacity = textureOpacity
        if let existing = hostingController {
            existing.rootView = buildPageView()
        }
    }

    private func buildPageView() -> ComicPageCellView {
        guard let page = currentPage, let config = currentConfig else {
            return ComicPageCellView(
                page: MangaPage(index: 0, imageURL: ""),
                config: ImageUpscalerConfig(),
                background: currentBackground,
                texture: currentTexture,
                textureOpacity: currentTextureOpacity,
                onSingleTap: {},
                onStatusUpdate: { _ in }
            )
        }
        return ComicPageCellView(
            page: page,
            config: config,
            isEnabled: currentIsEnabled,
            transitionAfterUpscaled: currentTransitionAfterUpscaled,
            isCompareMode: currentIsCompareMode,
            showSpineShadow: false,
            isRightToLeft: currentIsRightToLeft,
            background: currentBackground,
            texture: currentTexture,
            textureOpacity: currentTextureOpacity,
            onSingleTap: currentOnSingleTap ?? {},
            onStatusUpdate: currentOnStatusUpdate ?? { _ in },
            onZoomChanged: currentOnZoomChanged,
            onImageLoaded: currentOnImageLoaded
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
    }
}
