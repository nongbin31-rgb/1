import SwiftUI
import UIKit

/// 封装单页漫画视图的 UIHostingController
public final class ComicPageHostingController: UIHostingController<ComicPageCellView> {
    public let pageIndex: Int
    private var page: MangaPage
    private var config: ImageUpscalerConfig
    private var isEnabled: Bool
    private var transitionAfterUpscaled: Bool
    private var filterConfig: ImageFilterConfig
    private var isCompareMode: Bool
    private var showSpineShadow: Bool
    private var isRightToLeft: Bool
    private var background: ReaderBackground
    private var texture: ReaderTextureType
    private var textureOpacity: Double
    private var textureTintOpacity: Double
    private var textureGrainDensity: Double
    private var textureTarget: ReaderTextureTarget
    private var imageOnlyBackdrop: ReaderImageOnlyBackdrop
    private var showDividingLine: Bool
    private var onSingleTap: () -> Void
    private var onStatusUpdate: (String) -> Void
    private var onZoomChanged: ((CGFloat) -> Void)?
    private var onImageLoaded: ((UIImage) -> Void)?
    private var onPageReady: ((Int) -> Void)?

    public init(
        pageIndex: Int,
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool = false,
        transitionAfterUpscaled: Bool = true,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool = false,
        showSpineShadow: Bool = false,
        isRightToLeft: Bool = false,
        background: ReaderBackground = .followSystem,
        texture: ReaderTextureType = .classic,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        textureGrainDensity: Double = 1.0,
        textureTarget: ReaderTextureTarget = .both,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop = .paperTint,
        showDividingLine: Bool = true,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onPageReady: ((Int) -> Void)? = nil
    ) {
        self.pageIndex = pageIndex
        self.page = page
        self.config = config
        self.isEnabled = isEnabled
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.filterConfig = filterConfig
        self.isCompareMode = isCompareMode
        self.showSpineShadow = showSpineShadow
        self.isRightToLeft = isRightToLeft
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = textureTintOpacity
        self.textureGrainDensity = textureGrainDensity
        self.textureTarget = textureTarget
        self.imageOnlyBackdrop = imageOnlyBackdrop
        self.showDividingLine = showDividingLine
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onZoomChanged = onZoomChanged
        self.onImageLoaded = onImageLoaded
        self.onPageReady = onPageReady

        super.init(rootView: ComicPageCellView(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isCompareMode: isCompareMode,
            showSpineShadow: showSpineShadow,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureGrainDensity: textureGrainDensity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            showDividingLine: showDividingLine,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged,
            onImageLoaded: onImageLoaded,
            onPageReady: onPageReady
        ))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    /// 全面动态同步页面超分配置、排版方向与背景材质（关键修复：开启超分/切换模式时当前页即时生效）
    public func updateConfiguration(
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig(),
        isCompareMode: Bool,
        isRightToLeft: Bool? = nil,
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double? = nil,
        textureGrainDensity: Double? = nil,
        textureTarget: ReaderTextureTarget? = nil,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop? = nil,
        showSpineShadow: Bool? = nil,
        showDividingLine: Bool? = nil
    ) {
        let newTintOpacity = textureTintOpacity ?? self.textureTintOpacity
        let newGrainDensity = textureGrainDensity ?? self.textureGrainDensity
        let newTarget = textureTarget ?? self.textureTarget
        let newBackdrop = imageOnlyBackdrop ?? self.imageOnlyBackdrop
        let newRTL = isRightToLeft ?? self.isRightToLeft
        let newSpineShadow = showSpineShadow ?? self.showSpineShadow
        let newDividingLine = showDividingLine ?? self.showDividingLine

        let upscalerChanged = self.config != config
            || self.isEnabled != isEnabled
            || self.transitionAfterUpscaled != transitionAfterUpscaled
            || self.filterConfig != filterConfig
            || self.isCompareMode != isCompareMode

        let layoutChanged = self.isRightToLeft != newRTL
            || self.showSpineShadow != newSpineShadow
            || self.showDividingLine != newDividingLine

        let backgroundChanged = self.background != background
            || self.texture != texture
            || self.textureOpacity != textureOpacity
            || self.textureTintOpacity != newTintOpacity
            || self.textureGrainDensity != newGrainDensity
            || self.textureTarget != newTarget
            || self.imageOnlyBackdrop != newBackdrop

        guard upscalerChanged || layoutChanged || backgroundChanged else {
            return
        }

        self.config = config
        self.isEnabled = isEnabled
        self.transitionAfterUpscaled = transitionAfterUpscaled
        self.filterConfig = filterConfig
        self.isCompareMode = isCompareMode
        self.isRightToLeft = newRTL
        self.showSpineShadow = newSpineShadow
        self.showDividingLine = newDividingLine
        self.background = background
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = newTintOpacity
        self.textureGrainDensity = newGrainDensity
        self.textureTarget = newTarget
        self.imageOnlyBackdrop = newBackdrop

        self.rootView = buildRootView()
    }

    /// 动态更新对比模式（关键修复：响应外部 isCompareMode 切换以退出/进入对比）
    public func updateCompareMode(_ isCompareMode: Bool) {
        guard self.isCompareMode != isCompareMode else { return }
        self.isCompareMode = isCompareMode
        self.rootView = buildRootView()
    }

    public func updateBackground(
        background: ReaderBackground,
        texture: ReaderTextureType,
        textureOpacity: Double,
        textureTintOpacity: Double? = nil,
        textureGrainDensity: Double? = nil,
        textureTarget: ReaderTextureTarget? = nil,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop? = nil,
        showSpineShadow: Bool? = nil,
        showDividingLine: Bool? = nil
    ) {
        updateConfiguration(
            config: self.config,
            isEnabled: self.isEnabled,
            transitionAfterUpscaled: self.transitionAfterUpscaled,
            isCompareMode: self.isCompareMode,
            isRightToLeft: self.isRightToLeft,
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

    private func buildRootView() -> ComicPageCellView {
        ComicPageCellView(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig,
            isCompareMode: isCompareMode,
            showSpineShadow: showSpineShadow,
            isRightToLeft: isRightToLeft,
            background: background,
            texture: texture,
            textureOpacity: textureOpacity,
            textureTintOpacity: textureTintOpacity,
            textureGrainDensity: textureGrainDensity,
            textureTarget: textureTarget,
            imageOnlyBackdrop: imageOnlyBackdrop,
            showDividingLine: showDividingLine,
            onSingleTap: onSingleTap,
            onStatusUpdate: onStatusUpdate,
            onZoomChanged: onZoomChanged,
            onImageLoaded: onImageLoaded,
            onPageReady: onPageReady
        )
    }
}
