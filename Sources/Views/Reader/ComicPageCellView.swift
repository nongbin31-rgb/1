import SwiftUI
import UIKit

/// 单页加载与超分状态托管类（复用 Slot 逻辑并支持快速复原）
@MainActor
public final class ComicPageSlot: ObservableObject {
    @Published public var originalImage: UIImage?
    @Published public var processed: ProcessedPageImage?
    @Published public var displayImage: UIImage?
    @Published public var isLoading = true
    @Published public var isUpscaling = false
    @Published public var upscaleProgress: String = ""
    @Published public var errorMessage: String?

    private var loadedPageID: String?
    private var lastAppliedConfig: ImageUpscalerConfig?
    private var lastIsEnabled: Bool?
    private var lastAppliedFilterSignature: String?
    private var loadGeneration: UInt64 = 0

    public init() {}

    public func loadAndProcess(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool,
        filterConfig: ImageFilterConfig = ImageFilterConfig.defaultConfig()
    ) async {
        // 页面切换（例如 UICollectionViewCell 复用）时，必须清空上一页缓存的图片与状态
        if loadedPageID != page.id {
            loadedPageID = page.id
            originalImage = nil
            processed = nil
            displayImage = nil
            errorMessage = nil
            isLoading = true
            isUpscaling = false
            upscaleProgress = ""
            lastAppliedConfig = nil
            lastIsEnabled = nil
            lastAppliedFilterSignature = nil
        } else {
            errorMessage = nil
        }

        let targetFilterSig = filterConfig.cacheSignature

        // 动态调滤镜极速响应快路径：原图已在内存，且超分配置/开启状态未变，仅调整滤镜参数时直接对现有成品跑 CoreImage 滤镜
        if let existingOriginal = originalImage {
            if !isEnabled {
                if lastIsEnabled == false {
                    if lastAppliedFilterSignature == targetFilterSig, displayImage != nil {
                        return
                    }
                    let filterKey = ImageFilterPipeline.cacheKey(
                        pageURL: page.imageURL,
                        upscalerConfig: nil,
                        isUpscaled: false
                    )
                    let finalImage = filterConfig.hasActiveFilters
                        ? ImageFilterPipeline.shared.process(image: existingOriginal, cacheKey: filterKey, config: filterConfig)
                        : existingOriginal
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.displayImage = finalImage
                    self.isLoading = false
                    return
                }
            } else if lastIsEnabled == true, lastAppliedConfig == config, let existingProcessed = processed {
                if lastAppliedFilterSignature == targetFilterSig, displayImage != nil {
                    return
                }
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: config,
                    isUpscaled: existingProcessed.appliedModel != nil
                )
                let finalImage = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.process(image: existingProcessed.image, cacheKey: filterKey, config: filterConfig)
                    : existingProcessed.image
                self.lastAppliedFilterSignature = targetFilterSig
                self.displayImage = finalImage
                self.isLoading = false
                return
            }
        }

        // 零闪烁内存全命中快路径：预载入或近期翻阅已将原图 + 目标超分/滤镜备齐时，直接同步直出跳过转圈与淡入
        if let memOriginal = originalImage ?? OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) {
            let origSize = Self.pixelSize(of: memOriginal)
            if !isEnabled {
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: nil,
                    isUpscaled: false
                )
                let fastDisplay = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterConfig)
                    : memOriginal
                if let fastDisplay {
                    loadGeneration &+= 1
                    self.originalImage = memOriginal
                    self.processed = ProcessedPageImage(
                        image: memOriginal,
                        originalSize: origSize,
                        outputSize: origSize,
                        elapsedMs: 0,
                        appliedModel: nil
                    )
                    self.lastIsEnabled = false
                    self.lastAppliedConfig = nil
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.isLoading = false
                    self.isUpscaling = false
                    self.upscaleProgress = ""
                    self.displayImage = fastDisplay
                    return
                }
            } else if let memUpscaled = PageUpscalerPipeline.shared.cachedImage(
                pageKey: page.imageURL,
                config: config
            ) {
                let filterKey = ImageFilterPipeline.cacheKey(
                    pageURL: page.imageURL,
                    upscalerConfig: config,
                    isUpscaled: true
                )
                let fastDisplay = filterConfig.hasActiveFilters
                    ? ImageFilterPipeline.shared.cachedImage(cacheKey: filterKey, config: filterConfig)
                    : memUpscaled
                if let fastDisplay {
                    loadGeneration &+= 1
                    self.originalImage = memOriginal
                    self.processed = ProcessedPageImage(
                        image: memUpscaled,
                        originalSize: origSize,
                        outputSize: Self.pixelSize(of: memUpscaled),
                        elapsedMs: 0,
                        appliedModel: config.model,
                        notice: "命中缓存"
                    )
                    self.lastIsEnabled = true
                    self.lastAppliedConfig = config
                    self.lastAppliedFilterSignature = targetFilterSig
                    self.isLoading = false
                    self.isUpscaling = false
                    self.upscaleProgress = ""
                    self.displayImage = fastDisplay
                    return
                }
            }
        }

        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        var rawLoadedImage: UIImage? = originalImage
        if rawLoadedImage == nil {
            if let memOriginal = OnlineImageLoader.shared.cachedMemoryImage(for: page.imageURL) {
                rawLoadedImage = memOriginal
            } else {
                isLoading = true
                do {
                    let img = try await OnlineImageLoader.shared.loadImage(
                        urlString: page.imageURL,
                        headers: page.headers
                    )
                    guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
                        return
                    }
                    rawLoadedImage = img
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
                        return
                    }
                    errorMessage = error.localizedDescription
                    isLoading = false
                    return
                }
            }
        }

        guard let original = rawLoadedImage else { return }
        self.originalImage = original

        // 【原子化滤镜门禁】：先根据当前滤镜配置生成 1x 基准底图，绝不在屏幕上提前暴露未处理的原图
        let rawFilterKey = ImageFilterPipeline.cacheKey(
            pageURL: page.imageURL,
            upscalerConfig: nil,
            isUpscaled: false
        )
        let baselineFilteredImage = filterConfig.hasActiveFilters
            ? ImageFilterPipeline.shared.process(
                image: original,
                cacheKey: rawFilterKey,
                config: filterConfig
            )
            : original

        // 若超分未启用，直接呈现带滤镜的原图，首帧即是最终效果，绝无二次跳变闪烁
        guard isEnabled else {
            let size = Self.pixelSize(of: original)
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedModel: nil
            )
            lastIsEnabled = false
            lastAppliedConfig = nil
            self.lastAppliedFilterSignature = targetFilterSig
            self.displayImage = baselineFilteredImage
            self.isLoading = false
            return
        }

        // 超分已启用：秒显底图直接展示带滤镜的 baselineFilteredImage，基准色调从第 0 毫秒起就与最终成品完全一致
        self.displayImage = baselineFilteredImage
        self.isLoading = false

        let hasCachedUpscaled = PageUpscalerPipeline.shared.hasCachedResult(
            pageKey: page.imageURL,
            config: config
        )
        if !hasCachedUpscaled {
            isUpscaling = true
            upscaleProgress = ""
        }
        defer {
            if loadGeneration == currentGeneration {
                isUpscaling = false
                upscaleProgress = ""
            }
        }

        let result = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config,
            isEnabled: isEnabled,
            progress: { [weak self] pct in
                Task { @MainActor [weak self] in
                    guard let self, self.loadGeneration == currentGeneration else { return }
                    self.upscaleProgress = pct
                }
            }
        )
        guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
            return
        }
        self.processed = result
        self.lastIsEnabled = true
        self.lastAppliedConfig = config

        let finalImage: UIImage
        if filterConfig.hasActiveFilters {
            let filterKey = ImageFilterPipeline.cacheKey(
                pageURL: page.imageURL,
                upscalerConfig: config,
                isUpscaled: result.appliedModel != nil
            )
            finalImage = ImageFilterPipeline.shared.process(
                image: result.image,
                cacheKey: filterKey,
                config: filterConfig
            )
        } else {
            finalImage = result.image
        }
        self.lastAppliedFilterSignature = targetFilterSig

        // 命中预热缓存时零闪烁直出；仅现场等待超分完成后播放平滑淡入（色调完全一致，仅清晰度由 1x 柔和过渡到 2x）
        let shouldAnimateTransition = transitionAfterUpscaled
            && result.appliedModel != nil
            && result.notice != "命中缓存"
            && result.elapsedMs > 0
        if shouldAnimateTransition {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = finalImage
            }
        } else {
            self.displayImage = finalImage
        }
    }

    private static func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CGSize(width: cg.height, height: cg.width)
            default:
                return CGSize(width: cg.width, height: cg.height)
            }
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }

    /// 释放大图内存以应对长列表/长时间翻页，仅保留占位状态
    public func releaseImageMemory() {
        loadGeneration &+= 1
        loadedPageID = nil
        originalImage = nil
        processed = nil
        displayImage = nil
        isLoading = false
        isUpscaling = false
        lastAppliedConfig = nil
        lastIsEnabled = nil
    }
}

/// 统一单页漫画呈现视图（内嵌缩放、分屏对比、中缝立体阴影与超分状态更新）
public struct ComicPageCellView: View {
    public let page: MangaPage
    public let config: ImageUpscalerConfig
    public let isEnabled: Bool
    public let transitionAfterUpscaled: Bool
    public let isCompareMode: Bool
    public let showSpineShadow: Bool
    public let isRightToLeft: Bool
    public let background: ReaderBackground
    public let texture: ReaderTextureType
    public let textureOpacity: Double
    public let textureTintOpacity: Double
    public let textureGrainDensity: Double
    public let textureTarget: ReaderTextureTarget
    public let imageOnlyBackdrop: ReaderImageOnlyBackdrop
    public let showDividingLine: Bool
    public let filterConfig: ImageFilterConfig
    public let onSingleTap: () -> Void
    public let onTapLocation: ((CGFloat, Bool) -> Void)?
    public let onStatusUpdate: (String) -> Void
    public var onZoomChanged: ((CGFloat) -> Void)? = nil
    public var onImageLoaded: ((UIImage) -> Void)? = nil
    public var onPageReady: ((Int) -> Void)? = nil

    @StateObject private var slot = ComicPageSlot()
    @ObservedObject private var translationManager = MangaTranslationManager.shared

    public init(
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
        onTapLocation: ((CGFloat, Bool) -> Void)? = nil,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        onPageReady: ((Int) -> Void)? = nil
    ) {
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
        self.onTapLocation = onTapLocation
        self.onStatusUpdate = onStatusUpdate
        self.onZoomChanged = onZoomChanged
        self.onImageLoaded = onImageLoaded
        self.onPageReady = onPageReady
    }

    public var body: some View {
        ZStack {
            // 每页自带完整不透明且铺满安全区的纸张背景与纹理（确保仿真卷页/层叠翻页时上下留白为真实实体纸面而非透明镂空）
            pageBackdropView

            if let currentImg = slot.displayImage, let orig = slot.originalImage {
                if isCompareMode, isEnabled, let processed = slot.processed, processed.appliedModel != nil {
                    SplitCompareView(
                        originalImage: orig,
                        enhancedImage: processed.image,
                        engineLabel: config.model.displayName,
                        onSingleTap: onSingleTap
                    )
                } else {
                    let renderedImg = translationManager.resolvedDisplayImage(
                        for: page.imageURL,
                        baseImage: currentImg
                    )
                    ZoomableImageView(
                        image: renderedImg,
                        texture: texture,
                        textureOpacity: textureOpacity,
                        textureTintOpacity: textureTintOpacity,
                        textureGrainDensity: textureGrainDensity,
                        applyTextureToImage: background == .texture && (textureTarget == .both || textureTarget == .imageOnly),
                        onSingleTap: onSingleTap,
                        onTapLocation: onTapLocation,
                        onZoomChanged: onZoomChanged
                    )
                }

                // 书脊中缝立体渐变阴影（还原实体书装订处凹陷光影）
                if showSpineShadow && !isCompareMode {
                    SpineShadowOverlayView(
                        edge: isRightToLeft ? .trailing : .leading,
                        showDividingLine: showDividingLine
                    )
                }

                if slot.isUpscaling {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text(
                                slot.upscaleProgress.isEmpty
                                    ? "正在执行 \(config.model.displayName) 2x 超分..."
                                    : "正在执行 \(config.model.displayName) 2x 超分 \(slot.upscaleProgress)"
                            )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.75), in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 78)
                }
            } else if let err = slot.errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.title)
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(textColorForBackground.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("重试") {
                        Task { await triggerLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(textColorForBackground)
                    Text("加载第 \(page.index + 1) 页...")
                        .font(.caption)
                        .foregroundStyle(textColorForBackground.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSingleTap()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .task(id: "\(page.id)::\(config.reloadKey)::\(isEnabled)::\(filterConfig.cacheSignature)") {
            await triggerLoad()
        }
        .onChange(of: slot.displayImage) { newImg in
            if let newImg {
                onImageLoaded?(newImg)
            }
        }
    }

    private var pageBackdropView: some View {
        GeometryReader { geo in
            pageBackdropContent(referenceSize: geo.size)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .compositingGroup()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func pageBackdropContent(referenceSize: CGSize) -> some View {
        switch background {
        case .followSystem:
            Color(uiColor: .systemBackground)
        case .light:
            Color.white
        case .dark:
            Color.black
        case .immersive:
            pageImmersiveBackdrop(referenceSize: referenceSize)
        case .texture:
            if textureTarget == .imageOnly {
                pageImageOnlyBackdrop(referenceSize: referenceSize)
            } else {
                ZStack {
                    pagePaperTintBackdrop
                    if !isCompareMode {
                        PaperTextureOverlayView(
                            texture: texture,
                            opacity: textureOpacity,
                            tintOpacity: textureTintOpacity,
                            grainDensity: textureGrainDensity,
                            phaseAnchor: .local,
                            referenceSize: referenceSize
                        )
                    }
                }
            }
        }
    }

    private var pagePaperTintBackdrop: some View {
        ZStack {
            Color.white
            if textureTintOpacity > 0.001 {
                texture.basePaperSwiftUIColor
                    .opacity(textureTintOpacity)
            }
        }
    }

    @ViewBuilder
    private func pageImageOnlyBackdrop(referenceSize: CGSize) -> some View {
        switch imageOnlyBackdrop {
        case .paperTint:
            pagePaperTintBackdrop
        case .followSystem:
            Color(uiColor: .systemBackground)
        case .light:
            Color.white
        case .dark:
            Color.black
        case .immersive:
            pageImmersiveBackdrop(referenceSize: referenceSize)
        }
    }

    private func pageImmersiveBackdrop(referenceSize: CGSize) -> some View {
        let sourceImg = slot.originalImage ?? slot.displayImage
        let blurredImg = sourceImg.flatMap {
            ReaderTextureCache.shared.ambientBlurImage(for: $0, cacheKey: page.imageURL)
        }
        return ZStack {
            Color.black
            if let blurredImg {
                Image(uiImage: blurredImg)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: referenceSize.width, height: referenceSize.height)
                    .clipped()
                    .opacity(0.8)
            }
        }
    }

    private var textColorForBackground: Color {
        switch background {
        case .light:
            return .black
        case .followSystem:
            return .primary
        case .texture:
            if textureTarget == .imageOnly {
                return imageOnlyBackdrop.placeholderTextColor
            }
            return Color(red: 0.2, green: 0.18, blue: 0.15)
        default:
            return .white
        }
    }

    private func triggerLoad() async {
        await slot.loadAndProcess(
            page: page,
            config: config,
            isEnabled: isEnabled,
            transitionAfterUpscaled: transitionAfterUpscaled,
            filterConfig: filterConfig
        )
        guard !Task.isCancelled else { return }
        if slot.errorMessage == nil, slot.displayImage != nil {
            onPageReady?(page.index)
        }
        if let p = slot.processed {
            let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
            let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
            if let notice = p.notice {
                onStatusUpdate("\(orig) → \(out) · \(notice)")
            } else if let model = p.appliedModel {
                onStatusUpdate("\(model.displayName) · \(orig) → \(out) · \(p.elapsedMs)ms")
            } else {
                onStatusUpdate("原图 \(orig)")
            }
        }
    }
}
