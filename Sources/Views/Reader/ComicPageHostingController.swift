import SwiftUI
import UIKit

/// 封装单页漫画视图的 UIHostingController
public final class ComicPageHostingController: UIHostingController<ComicPageCellView> {
    public let pageIndex: Int
    private var page: MangaPage
    private var config: ImageUpscalerConfig
    private var isEnabled: Bool
    private var transitionAfterUpscaled: Bool
    private var isCompareMode: Bool
    private var showSpineShadow: Bool
    private var isRightToLeft: Bool
    private var background: ReaderBackground
    private var texture: ReaderTextureType
    private var textureOpacity: Double
    private var showDividingLine: Bool
    private var onSingleTap: () -> Void
    private var onStatusUpdate: (String) -> Void
    private var onZoomChanged: ((CGFloat) -> Void)?
    private var onImageLoaded: ((UIImage) -> Void)?

    public init(
        pageIndex: Int,
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool = false,
        transitionAfterUpscaled: Bool = true,
        isCompareMode: Bool = false,
        showSpineShadow: Bool = false,
        isRightToLeft: Bool = false,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        showDividingLine: Bool = true,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil
    ) {
        self.pageIndex = pageIndex
        self.page = page
        self.config = config
        self.isEnabled = isEnabled
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.isCompareMode = isCompareMode
        self.showSpineShadow = showSpineShadow
        self.isRightToLeft = isRightToLeft
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.showDividingLine = showDividingLine
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onZoomChanged = onZoomChanged
        self.onImageLoaded = onImageLoaded

        let rootView = ComicPageCellView(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            isCompareMode: isCompareMode,
            showSpineShadow: showSpineShadow,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            showDividingLine: showDividingLine,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged,
            onImageLoaded: onImageLoaded
        )
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    public func updateBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        showSpineShadow: Bool? = nil,
        showDividingLine: Bool? = nil
    ) {
        guard self.background != background
            || self.texture != texture
            || self.textureOpacity != textureOpacity
            || (showSpineShadow != nil && self.showSpineShadow != showSpineShadow)
            || (showDividingLine != nil && self.showDividingLine != showDividingLine) else {
            return
        }
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        if let showSpineShadow { self.showSpineShadow = showSpineShadow }
        if let showDividingLine { self.showDividingLine = showDividingLine }
        self.rootView = ComicPageCellView(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            isCompareMode: isCompareMode,
            showSpineShadow: self.showSpineShadow,
            isRightToLeft: isRightToLeft,
            background: self.background,
            texture: self.texture,
            textureOpacity: self.textureOpacity,
            showDividingLine: self.showDividingLine,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged,
            onImageLoaded: onImageLoaded
        )
    }
}
