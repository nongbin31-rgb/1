import AudioToolbox
import SwiftUI
import UIKit

/// 自定义水平阻尼磁吸分页流式布局（重写 targetContentOffset 确保手指离开时弹簧对齐整页）
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

    public override func targetContentOffset(
        forProposedContentOffset proposedOffset: CGPoint,
        withScrollingVelocity velocity: CGPoint
    ) -> CGPoint {
        guard let cv = collectionView else { return proposedOffset }
        let pageWidth = cv.bounds.width
        guard pageWidth > 0 else { return proposedOffset }

        let currentOffset = cv.contentOffset.x
        var targetIndex: CGFloat

        if abs(velocity.x) > 0.25 {
            targetIndex = velocity.x > 0 ? ceil(currentOffset / pageWidth) : floor(currentOffset / pageWidth)
        } else {
            targetIndex = round(proposedOffset.x / pageWidth)
        }

        let maxIndex = CGFloat(max(0, cv.numberOfItems(inSection: 0) - 1))
        let clampedIndex = max(0, min(maxIndex, targetIndex))
        return CGPoint(x: clampedIndex * pageWidth, y: proposedOffset.y)
    }
}

/// 磁吸吸附滑动与零延迟即时阅读容器（基于 UICollectionView + 自定义阻尼吸附布局）
/// 特性：
/// 1. 消除手势冲突：单页放大缩放时动态锁死外层横向滑动，恢复 1.0 时释放；
/// 2. 磁吸对齐：滑行减速时自动阻尼吸附整页，无半页停靠尴尬；
/// 3. 零延迟模式：关闭动画时以毫秒级即时跳转；
/// 4. RTL/LTR 原生感知与触觉联动。
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

        // 更新背景颜色
        uiViewController.updateBackgroundStyle(background)

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
                onZoomChanged: { [weak self, weak collectionView] scale in
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

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateCurrentPageFromScroll(scrollView)
        }

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            updateCurrentPageFromScroll(scrollView)
        }

        private func updateCurrentPageFromScroll(_ scrollView: UIScrollView) {
            let pageWidth = scrollView.bounds.width
            guard pageWidth > 0 else { return }
            let index = Int(round(scrollView.contentOffset.x / pageWidth))
            if parent.pages.indices.contains(index), parent.currentPageIndex != index {
                parent.currentPageIndex = index
                playPageFeedback()
            }
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
    private let coordinator: SnapPageReaderView.Coordinator
    var collectionView: UICollectionView!
    private var layout: SnapPageFlowLayout!
    private var lastRecordedIndex: Int = -1

    init(coordinator: SnapPageReaderView.Coordinator) {
        self.coordinator = coordinator
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
        case .dark, .immersive:
            color = .black
        case .texture:
            color = UIColor(red: 0.965, green: 0.957, blue: 0.941, alpha: 1.0)
        }
        view.backgroundColor = color
        if isViewLoaded {
            collectionView?.backgroundColor = color
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        layout = SnapPageFlowLayout()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = false // 使用 SnapPageFlowLayout 实现自然磁吸阻尼
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
        layout.itemSize = collectionView.bounds.size
        layout.invalidateLayout()
    }

    func applyConfiguration(pages: [MangaPage], isRightToLeft: Bool, targetIndex: Int, animated: Bool) {
        guard isViewLoaded else { return }

        let semantic: UISemanticContentAttribute = isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        if collectionView.semanticContentAttribute != semantic {
            collectionView.semanticContentAttribute = semantic
            collectionView.reloadData()
        }

        if lastRecordedIndex != targetIndex && pages.indices.contains(targetIndex) {
            lastRecordedIndex = targetIndex
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let indexPath = IndexPath(item: targetIndex, section: 0)
                self.collectionView.scrollToItem(at: indexPath, at: .centeredHorizontally, animated: animated)
            }
        }
    }
}

/// 承载 ComicPageCellView 的 UICollectionViewCell
final class SnapPageHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "SnapPageHostingCell"

    private var hostingController: UIHostingController<ComicPageCellView>?

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
        let pageView = ComicPageCellView(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            isCompareMode: isCompareMode,
            showSpineShadow: false,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged,
            onImageLoaded: onImageLoaded
        )

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

    override func prepareForReuse() {
        super.prepareForReuse()
        // 复用时重置
    }
}
