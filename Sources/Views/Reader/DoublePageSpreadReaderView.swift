import AudioToolbox
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 双页对开逻辑单元（单页封面/跨页宽图/末页落单时 secondaryPage 为 nil）
public struct ReaderPageSpread: Identifiable, Equatable, Sendable {
    public let id: String
    public let primaryPage: MangaPage
    public let secondaryPage: MangaPage?

    public var isDoublePage: Bool {
        secondaryPage != nil
    }

    public var pageIndices: [Int] {
        if let secondaryPage {
            return [primaryPage.index, secondaryPage.index]
        }
        return [primaryPage.index]
    }

    public func contains(pageIndex: Int) -> Bool {
        if primaryPage.index == pageIndex { return true }
        if let secondaryPage, secondaryPage.index == pageIndex { return true }
        return false
    }
}

/// 双页对开拼页构建器（支持封面单独成页偏移与自带宽图跨页自动独占）
public enum ReaderSpreadBuilder {
    /// 宽图跨页判定阈值（aspect = height / width < 0.87 等价于 width / height > 1.15）
    private static let wideSpreadHeightOverWidthThreshold: CGFloat = 0.87

    public static func buildSpreads(
        pages: [MangaPage],
        isolateCover: Bool,
        aspectRatios: [String: CGFloat]
    ) -> [ReaderPageSpread] {
        guard !pages.isEmpty else { return [] }

        func isWideSpread(_ page: MangaPage) -> Bool {
            guard let ratio = aspectRatios[page.id], ratio > 0 else { return false }
            return ratio < wideSpreadHeightOverWidthThreshold
        }

        var spreads: [ReaderPageSpread] = []
        var idx = 0

        while idx < pages.count {
            let first = pages[idx]

            // 1. 封面单独成页（偏移校正）
            if isolateCover && idx == 0 {
                spreads.append(
                    ReaderPageSpread(
                        id: "single::\(first.id)",
                        primaryPage: first,
                        secondaryPage: nil
                    )
                )
                idx += 1
                continue
            }

            // 2. 当前页本身就是横版跨页宽图：独占整屏
            if isWideSpread(first) {
                spreads.append(
                    ReaderPageSpread(
                        id: "wide::\(first.id)",
                        primaryPage: first,
                        secondaryPage: nil
                    )
                )
                idx += 1
                continue
            }

            // 3. 尝试与下一页组成双页对开（若下一页是宽图跨页则不强行拼接）
            if idx + 1 < pages.count {
                let second = pages[idx + 1]
                if !isWideSpread(second) {
                    spreads.append(
                        ReaderPageSpread(
                            id: "double::\(first.id)::\(second.id)",
                            primaryPage: first,
                            secondaryPage: second
                        )
                    )
                    idx += 2
                    continue
                }
            }

            // 4. 落单末页或宽图前单页
            spreads.append(
                ReaderPageSpread(
                    id: "single::\(first.id)",
                    primaryPage: first,
                    secondaryPage: nil
                )
            )
            idx += 1
        }

        return spreads
    }

    public static func spreadIndex(containingPage pageIndex: Int, in spreads: [ReaderPageSpread]) -> Int {
        guard !spreads.isEmpty else { return 0 }
        if let exact = spreads.firstIndex(where: { $0.contains(pageIndex: pageIndex) }) {
            return exact
        }
        return min(max(0, pageIndex), spreads.count - 1)
    }
}

#if canImport(UIKit)

/// iPad / 横屏双页对开阅读容器（基于 UICollectionView 整页吸附 + 整张对开缩放 + 对称实体书脊阴影）
public struct DoublePageSpreadReaderView: UIViewControllerRepresentable {
    public let spreads: [ReaderPageSpread]
    public let upscalerConfig: ImageUpscalerConfig
    public let enableUpscaler: Bool
    public let transitionAfterUpscaled: Bool
    public let filterConfig: ImageFilterConfig
    public let isRightToLeft: Bool
    public let turningEffect: PageTurningEffect
    public let soundEnabled: Bool
    public let showSpineShadow: Bool
    public let showDividingLine: Bool
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
    public var onTapLocation: ((CGFloat, Bool) -> Void)? = nil
    public let onStatusUpdate: (String) -> Void
    public var onImageLoaded: ((MangaPage, UIImage) -> Void)? = nil
    public var onPageReady: ((Int) -> Void)? = nil

    public init(
        spreads: [ReaderPageSpread],
        upscalerConfig: ImageUpscalerConfig,
        enableUpscaler: Bool = false,
        transitionAfterUpscaled: Bool = true,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isRightToLeft: Bool,
        turningEffect: PageTurningEffect,
        soundEnabled: Bool,
        showSpineShadow: Bool,
        showDividingLine: Bool = true,
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
        onTapLocation: ((CGFloat, Bool) -> Void)? = nil,
        onStatusUpdate: @escaping (String) -> Void,
        onImageLoaded: ((MangaPage, UIImage) -> Void)? = nil,
        onPageReady: ((Int) -> Void)? = nil
    ) {
        self.spreads = spreads
        self.upscalerConfig = upscalerConfig
        self.enableUpscaler = enableUpscaler
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.filterConfig = filterConfig
        self.isRightToLeft = isRightToLeft
        self.turningEffect = turningEffect
        self.soundEnabled = soundEnabled
        self.showSpineShadow = showSpineShadow
        self.showDividingLine = showDividingLine
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
        self.onTapLocation = onTapLocation
        self.onStatusUpdate = onStatusUpdate
        self.onImageLoaded = onImageLoaded
        self.onPageReady = onPageReady
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeUIViewController(context: Context) -> DoublePageSpreadViewController {
        let vc = DoublePageSpreadViewController(coordinator: context.coordinator)
        context.coordinator.viewController = vc
        return vc
    }

    public func updateUIViewController(_ uiViewController: DoublePageSpreadViewController, context: Context) {
        context.coordinator.parent = self
        uiViewController.updateBackgroundStyle(background)

        let isExternalJump = (context.coordinator.lastExternalJumpNonce != externalJumpNonce)
        if isExternalJump {
            context.coordinator.lastExternalJumpNonce = externalJumpNonce
        }

        let targetSpreadIndex = ReaderSpreadBuilder.spreadIndex(containingPage: currentPageIndex, in: spreads)
        let shouldAnimate = isExternalJump ? false : (turningEffect != .instant)

        uiViewController.applyConfiguration(
            spreads: spreads,
            isRightToLeft: isRightToLeft,
            targetSpreadIndex: targetSpreadIndex,
            animated: shouldAnimate,
            forceImmediate: isExternalJump
        )
        uiViewController.refreshVisibleCells()
    }

    public final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: DoublePageSpreadReaderView
        weak var viewController: DoublePageSpreadViewController?
        var lastExternalJumpNonce: Int = 0
        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

        init(parent: DoublePageSpreadReaderView) {
            self.parent = parent
            super.init()
            self.feedbackGenerator.prepare()
        }

        public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.spreads.count
        }

        public func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DoublePageSpreadCollectionCell.reuseID,
                for: indexPath
            ) as! DoublePageSpreadCollectionCell

            guard parent.spreads.indices.contains(indexPath.item) else { return cell }
            configureCell(cell, spread: parent.spreads[indexPath.item], collectionView: collectionView)
            return cell
        }

        fileprivate func configureCell(
            _ cell: DoublePageSpreadCollectionCell,
            spread: ReaderPageSpread,
            collectionView: UICollectionView
        ) {
            cell.configure(
                spread: spread,
                config: parent.upscalerConfig,
                isEnabled: parent.enableUpscaler,
                transitionAfterUpscaled: parent.transitionAfterUpscaled,
                filterConfig: parent.filterConfig,
                isRightToLeft: parent.isRightToLeft,
                showSpineShadow: parent.showSpineShadow,
                showDividingLine: parent.showDividingLine,
                background: parent.background,
                texture: parent.texture,
                textureOpacity: parent.textureOpacity,
                textureTintOpacity: parent.textureTintOpacity,
                textureGrainDensity: parent.textureGrainDensity,
                textureTarget: parent.textureTarget,
                imageOnlyBackdrop: parent.imageOnlyBackdrop,
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
                onZoomChanged: { [weak collectionView] scale in
                    let shouldScroll = scale <= 1.01
                    if collectionView?.isScrollEnabled != shouldScroll {
                        collectionView?.isScrollEnabled = shouldScroll
                    }
                },
                onStatusUpdate: { [weak self] text in
                    self?.parent.onStatusUpdate(text)
                },
                onImageLoaded: { [weak self] page, img in
                    self?.parent.onImageLoaded?(page, img)
                },
                onPageReady: { [weak self] readyIdx in
                    self?.parent.onPageReady?(readyIdx)
                }
            )
        }

        public func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            collectionView.bounds.size
        }

        public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            syncSpreadIndexFromScroll(scrollView, playFeedback: true)
        }

        public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                syncSpreadIndexFromScroll(scrollView, playFeedback: true)
            }
        }

        public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            syncSpreadIndexFromScroll(scrollView, playFeedback: false)
        }

        private func syncSpreadIndexFromScroll(_ scrollView: UIScrollView, playFeedback: Bool) {
            guard let vc = viewController, !parent.spreads.isEmpty else { return }
            let resolved = vc.resolvedCurrentSpreadIndex()
            guard parent.spreads.indices.contains(resolved) else { return }

            let previousSpread = vc.currentSpreadIndex
            vc.currentSpreadIndex = resolved
            let spread = parent.spreads[resolved]

            if !spread.contains(pageIndex: parent.currentPageIndex) {
                parent.currentPageIndex = spread.primaryPage.index
            }

            if playFeedback && previousSpread != resolved {
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

// MARK: - DoublePageSpreadViewController

public final class DoublePageSpreadViewController: UIViewController {
    private let coordinator: DoublePageSpreadReaderView.Coordinator
    private let layout = UICollectionViewFlowLayout()
    private var collectionView: UICollectionView!

    private var currentSpreadIDs: [String] = []
    private var currentRTL: Bool = false
    private var lastLayoutSize: CGSize = .zero
    private var hasPerformedInitialScroll = false
    var currentSpreadIndex: Int = 0

    init(coordinator: DoublePageSpreadReaderView.Coordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.isPagingEnabled = true
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.bounces = true
        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.register(
            DoublePageSpreadCollectionCell.self,
            forCellWithReuseIdentifier: DoublePageSpreadCollectionCell.reuseID
        )
        view.addSubview(collectionView)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = collectionView.bounds.size
        guard size.width > 1, size.height > 1 else { return }

        if lastLayoutSize != size {
            lastLayoutSize = size
            layout.itemSize = size
            layout.invalidateLayout()
            collectionView.layoutIfNeeded()
            scrollToSpread(currentSpreadIndex, animated: false)
            hasPerformedInitialScroll = true
        }
    }

    func updateBackgroundStyle(_ background: ReaderBackground) {
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

    func applyConfiguration(
        spreads: [ReaderPageSpread],
        isRightToLeft: Bool,
        targetSpreadIndex: Int,
        animated: Bool,
        forceImmediate: Bool
    ) {
        let newIDs = spreads.map(\.id)
        let dataChanged = (newIDs != currentSpreadIDs)
        let rtlChanged = (isRightToLeft != currentRTL)

        if rtlChanged {
            currentRTL = isRightToLeft
            collectionView.semanticContentAttribute = isRightToLeft ? .forceRightToLeft : .forceLeftToRight
            layout.invalidateLayout()
        }

        if dataChanged || rtlChanged {
            currentSpreadIDs = newIDs
            currentSpreadIndex = min(max(0, targetSpreadIndex), max(spreads.count - 1, 0))
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            scrollToSpread(currentSpreadIndex, animated: false)
            hasPerformedInitialScroll = true
            return
        }

        guard !spreads.isEmpty else { return }
        let clampedTarget = min(max(0, targetSpreadIndex), spreads.count - 1)

        if !hasPerformedInitialScroll {
            currentSpreadIndex = clampedTarget
            scrollToSpread(clampedTarget, animated: false)
            hasPerformedInitialScroll = true
            return
        }

        if clampedTarget != currentSpreadIndex {
            let shouldAnimate = !forceImmediate && animated && !collectionView.isDragging && !collectionView.isDecelerating
            currentSpreadIndex = clampedTarget
            scrollToSpread(clampedTarget, animated: shouldAnimate)
            if shouldAnimate {
                coordinator.playPageFeedback()
            }
        }
    }

    func refreshVisibleCells() {
        for cell in collectionView.visibleCells {
            guard let spreadCell = cell as? DoublePageSpreadCollectionCell,
                  let indexPath = collectionView.indexPath(for: spreadCell),
                  coordinator.parent.spreads.indices.contains(indexPath.item) else {
                continue
            }
            coordinator.configureCell(
                spreadCell,
                spread: coordinator.parent.spreads[indexPath.item],
                collectionView: collectionView
            )
        }
    }

    func resolvedCurrentSpreadIndex() -> Int {
        let width = collectionView.bounds.width
        let count = currentSpreadIDs.count
        guard width > 1, count > 0 else { return 0 }
        let raw = Int((collectionView.contentOffset.x / width).rounded())
        let clamped = min(max(0, raw), count - 1)
        return currentRTL ? (count - 1 - clamped) : clamped
    }

    private func scrollToSpread(_ index: Int, animated: Bool) {
        let count = currentSpreadIDs.count
        guard count > 0, collectionView.bounds.width > 1 else { return }
        let clamped = min(max(0, index), count - 1)
        let visualIndex = currentRTL ? (count - 1 - clamped) : clamped
        let offsetX = CGFloat(visualIndex) * collectionView.bounds.width
        collectionView.setContentOffset(CGPoint(x: offsetX, y: 0), animated: animated)
    }
}

// MARK: - Collection Cell & Zoomable Spread Canvas

private final class DoublePageSpreadCollectionCell: UICollectionViewCell {
    static let reuseID = "DoublePageSpreadCollectionCell"

    private var hostingController: UIHostingController<DoublePageSpreadCellView>?

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
        spread: ReaderPageSpread,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig,
        isRightToLeft: Bool,
        showSpineShadow: Bool,
        showDividingLine: Bool,
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double,
        textureGrainDensity: Double,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop,
        onSingleTap: @escaping () -> Void,
        onTapLocation: ((CGFloat, Bool) -> Void)?,
        onZoomChanged: @escaping (CGFloat) -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onImageLoaded: ((MangaPage, UIImage) -> Void)?,
        onPageReady: ((Int) -> Void)?
    ) {
        let rootView = DoublePageSpreadCellView(
            spread: spread,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isRightToLeft: isRightToLeft,
            showSpineShadow: showSpineShadow,
            showDividingLine: showDividingLine,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureGrainDensity: textureGrainDensity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            onSingleTap: onSingleTap,
            onTapLocation: onTapLocation,
            onZoomChanged: onZoomChanged,
            onStatusUpdate: onStatusUpdate,
            onImageLoaded: onImageLoaded,
            onPageReady: onPageReady
        )

        if let hc = hostingController {
            hc.rootView = rootView
        } else {
            let hc = UIHostingController(rootView: rootView)
            hc.view.backgroundColor = .clear
            hc.view.frame = contentView.bounds
            hc.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            if #available(iOS 16.4, *) {
                hc.safeAreaRegions = []
            }
            contentView.addSubview(hc.view)
            self.hostingController = hc
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let hcView = hostingController?.view, hcView.frame != contentView.bounds {
            hcView.frame = contentView.bounds
        }
    }
}

/// 单帧双页对开渲染视图（支持两页独立超分/滤镜、无缝中缝贴合、对称书脊阴影与整幅缩放）
private struct DoublePageSpreadCellView: View {
    let spread: ReaderPageSpread
    let config: ImageUpscalerConfig
    let isEnabled: Bool
    let transitionAfterUpscaled: Bool
    let filterConfig: ImageFilterConfig
    let isRightToLeft: Bool
    let showSpineShadow: Bool
    let showDividingLine: Bool
    let background: ReaderBackground
    let texture: ReaderTextureType
    let textureOpacity: Double
    let textureTintOpacity: Double
    let textureGrainDensity: Double
    let textureTarget: ReaderTextureTarget
    let imageOnlyBackdrop: ReaderImageOnlyBackdrop
    let onSingleTap: () -> Void
    let onTapLocation: ((CGFloat, Bool) -> Void)?
    let onZoomChanged: (CGFloat) -> Void
    let onStatusUpdate: (String) -> Void
    let onImageLoaded: ((MangaPage, UIImage) -> Void)?
    let onPageReady: ((Int) -> Void)?

    @StateObject private var primarySlot = ComicPageSlot()
    @StateObject private var secondarySlot = ComicPageSlot()
    @ObservedObject private var translationManager = MangaTranslationManager.shared

    private var reloadTaskKey: String {
        let secID = spread.secondaryPage?.id ?? "none"
        return "\(spread.primaryPage.id)::\(secID)::\(config.reloadKey)::\(isEnabled)::\(filterConfig.cacheSignature)"
    }

    var body: some View {
        DoublePageZoomScrollContainer(
            onSingleTap: onSingleTap,
            onTapLocation: onTapLocation,
            onZoomChanged: onZoomChanged
        ) {
            GeometryReader { geo in
                ZStack {
                    if let secondaryPage = spread.secondaryPage {
                        let halfWidth = geo.size.width * 0.5
                        let leftSlot = isRightToLeft ? secondarySlot : primarySlot
                        let rightSlot = isRightToLeft ? primarySlot : secondarySlot
                        let leftPage = isRightToLeft ? secondaryPage : spread.primaryPage
                        let rightPage = isRightToLeft ? spread.primaryPage : secondaryPage

                        HStack(spacing: 0) {
                            spreadHalfPage(
                                slot: leftSlot,
                                page: leftPage,
                                alignment: .trailing,
                                maxWidth: halfWidth,
                                maxHeight: geo.size.height
                            )
                            spreadHalfPage(
                                slot: rightSlot,
                                page: rightPage,
                                alignment: .leading,
                                maxWidth: halfWidth,
                                maxHeight: geo.size.height
                            )
                        }
                        .frame(width: geo.size.width, height: geo.size.height)

                        if showSpineShadow {
                            DoublePageCenterSpineShadow(showDividingLine: showDividingLine)
                                .allowsHitTesting(false)
                        }
                    } else {
                        spreadHalfPage(
                            slot: primarySlot,
                            page: spread.primaryPage,
                            alignment: .center,
                            maxWidth: geo.size.width,
                            maxHeight: geo.size.height
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task(id: reloadTaskKey) {
            await loadBothPages()
        }
    }

    @ViewBuilder
    private func spreadHalfPage(
        slot: ComicPageSlot,
        page: MangaPage,
        alignment: Alignment,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        ZStack(alignment: alignment) {
            if let image = slot.displayImage {
                let renderedImage = translationManager.resolvedDisplayImage(
                    for: page.imageURL,
                    baseImage: image
                )
                Image(uiImage: renderedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
            } else if let err = slot.errorMessage {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text(err)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button("重试") {
                        Task { await loadBothPages() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("第 \(page.index + 1) 页")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
            }
        }
        .frame(width: maxWidth, height: maxHeight, alignment: alignment)
        .clipped()
    }

    private func loadBothPages() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await primarySlot.loadAndProcess(
                    page: spread.primaryPage,
                    config: config,
                    isEnabled: isEnabled,
                    transitionAfterUpscaled: transitionAfterUpscaled,
                    filterConfig: filterConfig
                )
                if primarySlot.errorMessage == nil, primarySlot.displayImage != nil {
                    onPageReady?(spread.primaryPage.index)
                }
                if let orig = primarySlot.originalImage {
                    onImageLoaded?(spread.primaryPage, orig)
                }
                if let p = primarySlot.processed {
                    let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
                    let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
                    if let model = p.appliedModel {
                        onStatusUpdate("双页 · \(model.displayName) · \(orig) → \(out)")
                    } else {
                        onStatusUpdate("双页 · 原图 \(orig)")
                    }
                }
            }

            if let secondary = spread.secondaryPage {
                group.addTask { @MainActor in
                    await secondarySlot.loadAndProcess(
                        page: secondary,
                        config: config,
                        isEnabled: isEnabled,
                        transitionAfterUpscaled: transitionAfterUpscaled,
                        filterConfig: filterConfig
                    )
                    if secondarySlot.errorMessage == nil, secondarySlot.displayImage != nil {
                        onPageReady?(secondary.index)
                    }
                    if let orig = secondarySlot.originalImage {
                        onImageLoaded?(secondary, orig)
                    }
                }
            }
        }
    }
}

/// 双页正中对称实体书脊凹陷阴影（还原纸质漫画书摊开装订中缝光影）
private struct DoublePageCenterSpineShadow: View {
    let showDividingLine: Bool

    var body: some View {
        HStack(spacing: 0) {
            LinearGradient(
                colors: [Color.clear, Color.black.opacity(0.08), Color.black.opacity(0.24)],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 22)

            if showDividingLine {
                Rectangle()
                    .fill(Color.black.opacity(0.32))
                    .frame(width: 0.75)
            }

            LinearGradient(
                colors: [Color.black.opacity(0.24), Color.black.opacity(0.08), Color.clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 22)
        }
        .frame(maxHeight: .infinity)
    }
}

/// 支持整幅双页 1x~4x 缩放、双击聚焦缩放与单击坐标透传的原生 UIScrollView 包装器
private struct DoublePageZoomScrollContainer<Content: View>: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onTapLocation: ((CGFloat, Bool) -> Void)?
    let onZoomChanged: (CGFloat) -> Void
    let content: Content

    init(
        onSingleTap: @escaping () -> Void,
        onTapLocation: ((CGFloat, Bool) -> Void)?,
        onZoomChanged: @escaping (CGFloat) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onSingleTap = onSingleTap
        self.onTapLocation = onTapLocation
        self.onZoomChanged = onZoomChanged
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onTapLocation: onTapLocation,
            onZoomChanged: onZoomChanged
        )
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let hostVC = UIHostingController(rootView: content)
        hostVC.view.backgroundColor = .clear
        hostVC.view.frame = scrollView.bounds
        hostVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if #available(iOS 16.4, *) {
            hostVC.safeAreaRegions = []
        }
        scrollView.addSubview(hostVC.view)

        context.coordinator.scrollView = scrollView
        context.coordinator.hostController = hostVC

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingleTap(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onTapLocation = onTapLocation
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.hostController?.rootView = content

        if let hostView = context.coordinator.hostController?.view,
           uiView.zoomScale <= 1.01,
           uiView.bounds.size != .zero,
           hostView.frame.size != uiView.bounds.size {
            hostView.frame = uiView.bounds
            uiView.contentSize = uiView.bounds.size
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        var hostController: UIHostingController<Content>?
        var onSingleTap: () -> Void
        var onTapLocation: ((CGFloat, Bool) -> Void)?
        var onZoomChanged: (CGFloat) -> Void

        init(
            onSingleTap: @escaping () -> Void,
            onTapLocation: ((CGFloat, Bool) -> Void)?,
            onZoomChanged: @escaping (CGFloat) -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onTapLocation = onTapLocation
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            hostController?.view
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let contentView = hostController?.view else { return }
            let offsetX = max((scrollView.bounds.width - contentView.frame.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - contentView.frame.height) * 0.5, 0)
            contentView.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
            onZoomChanged(scrollView.zoomScale)
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            if let onTapLocation {
                let width = max(scrollView?.bounds.width ?? UIScreen.main.bounds.width, 1)
                let locX = gesture.location(in: scrollView).x
                let normalizedX = min(max(locX / width, 0), 1)
                let isZoomed = (scrollView?.zoomScale ?? 1.0) > 1.05
                onTapLocation(normalizedX, isZoomed)
            } else {
                onSingleTap()
            }
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let contentView = hostController?.view else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
                onZoomChanged(1.0)
            } else {
                let point = gesture.location(in: contentView)
                let zoomScale: CGFloat = 2.4
                let w = scrollView.bounds.width / zoomScale
                let h = scrollView.bounds.height / zoomScale
                let rect = CGRect(x: point.x - w * 0.5, y: point.y - h * 0.5, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
                onZoomChanged(zoomScale)
            }
        }
    }
}
#endif
