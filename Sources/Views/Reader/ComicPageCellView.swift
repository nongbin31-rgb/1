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
            lastAppliedConfig = nil
            lastIsEnabled = nil
            lastAppliedFilterSignature = nil
        } else {
            errorMessage = nil
        }

        let targetFilterSig = filterConfig.cacheSignature

        // 如果当前页原图已经存在，检查是否已经达到目标状态以避免重复计算
        if let original = originalImage {
            if !isEnabled {
                if lastIsEnabled == false,
                   processed?.appliedModel == nil,
                   lastAppliedFilterSignature == targetFilterSig,
                   displayImage != nil {
                    return
                }
            } else if lastIsEnabled == true,
                      lastAppliedConfig == config,
                      lastAppliedFilterSignature == targetFilterSig,
                      let currentProcessed = processed,
                      displayImage != nil {
                return
            }
        }

        loadGeneration &+= 1
        let currentGeneration = loadGeneration

        if originalImage == nil {
            isLoading = true
            do {
                let img = try await OnlineImageLoader.shared.loadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
                guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
                    return
                }
                self.originalImage = img
                self.displayImage = img
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
            isLoading = false
            await Task.yield()
            guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
                return
            }
        }

        guard let original = originalImage else { return }

        // 若超分未启用，直接处理原图 + 滤镜
        guard isEnabled else {
            let size = CGSize(
                width: original.cgImage?.width ?? Int(original.size.width),
                height: original.cgImage?.height ?? Int(original.size.height)
            )
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedModel: nil
            )
            lastIsEnabled = false
            lastAppliedConfig = nil

            let finalImage: UIImage
            if filterConfig.hasActiveFilters {
                finalImage = ImageFilterPipeline.shared.process(
                    image: original,
                    cacheKey: "\(page.imageURL)_raw",
                    config: filterConfig
                )
            } else {
                finalImage = original
            }
            self.lastAppliedFilterSignature = targetFilterSig
            self.displayImage = finalImage
            return
        }

        isUpscaling = true
        defer {
            if loadGeneration == currentGeneration {
                isUpscaling = false
            }
        }

        let result = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config,
            isEnabled: isEnabled
        )
        guard !Task.isCancelled, loadGeneration == currentGeneration, loadedPageID == page.id else {
            return
        }
        self.processed = result
        self.lastIsEnabled = true
        self.lastAppliedConfig = config

        let finalImage: UIImage
        if filterConfig.hasActiveFilters {
            finalImage = ImageFilterPipeline.shared.process(
                image: result.image,
                cacheKey: "\(page.imageURL)_upscaled",
                config: filterConfig
            )
        } else {
            finalImage = result.image
        }
        self.lastAppliedFilterSignature = targetFilterSig

        // 增强后平滑淡入（可达阅读器 transitionAfterImageUpscaled 逻辑）
        if transitionAfterUpscaled {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = finalImage
            }
        } else {
            self.displayImage = finalImage
        }
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
    public let onStatusUpdate: (String) -> Void
    public var onZoomChanged: ((CGFloat) -> Void)? = nil
    public var onImageLoaded: ((UIImage) -> Void)? = nil

    @StateObject private var slot = ComicPageSlot()

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
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil,
        onImageLoaded: ((UIImage) -> Void)? = nil
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
        self.onStatusUpdate = onStatusUpdate
        self.onZoomChanged = onZoomChanged
        self.onImageLoaded = onImageLoaded
    }

    public var body: some View {
        ZStack {
            currentBackgroundColor

            // 当处于纹理或沉浸模式时，单页留白区域保持完全透明，
            // 统一直透最底层铺满全屏的 readerBackgroundView，彻底消除翻页时 Cell 背景遮挡与安全区错位产生的白块
            if background == .texture && (textureTarget == .both || textureTarget == .backgroundOnly) && !isCompareMode {
                // 由外层 ReaderView 的 readerBackgroundView 统一承载全屏纸张底色与微粒纹理
            }

            if let currentImg = slot.displayImage, let orig = slot.originalImage {
                if isCompareMode, isEnabled, let processed = slot.processed, processed.appliedModel != nil {
                    SplitCompareView(
                        originalImage: orig,
                        enhancedImage: processed.image,
                        engineLabel: config.model.displayName,
                        onSingleTap: onSingleTap
                    )
                } else {
                    ZoomableImageView(
                        image: currentImg,
                        texture: texture,
                        textureOpacity: textureOpacity,
                        textureTintOpacity: textureTintOpacity,
                        textureGrainDensity: textureGrainDensity,
                        applyTextureToImage: background == .texture && (textureTarget == .both || textureTarget == .imageOnly),
                        onSingleTap: onSingleTap,
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
                            Text("正在执行 \(config.model.displayName) 2x 超分...")
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

    @ViewBuilder
    private var currentBackgroundColor: some View {
        switch background {
        case .followSystem:
            Color(uiColor: .systemBackground).ignoresSafeArea()
        case .light:
            Color.white.ignoresSafeArea()
        case .dark:
            Color.black.ignoresSafeArea()
        case .immersive, .texture:
            Color.clear.ignoresSafeArea()
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
