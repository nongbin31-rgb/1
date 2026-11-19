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

    public init() {}

    public func loadAndProcess(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isEnabled: Bool,
        transitionAfterUpscaled: Bool
    ) async {
        errorMessage = nil
        if originalImage == nil {
            isLoading = true
            do {
                let img = try await OnlineImageLoader.shared.loadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
                self.originalImage = img
                self.displayImage = img
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
            isLoading = false
            await Task.yield()
        }

        guard let original = originalImage else { return }

        // 若超分未启用，直接显示原图
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
            displayImage = original
            return
        }

        isUpscaling = true
        defer { isUpscaling = false }

        let result = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config,
            isEnabled: isEnabled
        )
        self.processed = result

        // 增强后平滑淡入（可达阅读器 transitionAfterImageUpscaled 逻辑）
        if transitionAfterUpscaled {
            withAnimation(.easeInOut(duration: 0.35)) {
                self.displayImage = result.image
            }
        } else {
            self.displayImage = result.image
        }
    }

    /// 释放大图内存以应对长列表/长时间翻页，仅保留占位状态
    public func releaseImageMemory() {
        originalImage = nil
        processed = nil
        displayImage = nil
        isLoading = false
        isUpscaling = false
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
    public let showDividingLine: Bool
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
    }

    public var body: some View {
        ZStack {
            currentBackgroundColor

            if let currentImg = slot.displayImage, let orig = slot.originalImage {
                if isCompareMode, isEnabled, let processed = slot.processed, processed.appliedModel != nil {
                    SplitCompareView(
                        originalImage: orig,
                        enhancedImage: processed.image,
                        engineLabel: config.model.displayName
                    )
                } else {
                    ZoomableImageView(
                        image: currentImg,
                        onSingleTap: onSingleTap,
                        onZoomChanged: onZoomChanged
                    )
                }

                // 物理纸张材质纹理覆盖（使用正片叠底 multiply 混合滤镜）
                if background == .texture && !isCompareMode {
                    PaperTextureOverlayView(texture: texture, opacity: textureOpacity)
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
        .task(id: "\(page.id)::\(config.cacheKey)::\(isEnabled)") {
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
        case .immersive:
            Color.clear.ignoresSafeArea()
        case .texture:
            Color(red: 0.965, green: 0.957, blue: 0.941).ignoresSafeArea()
        }
    }

    private var textColorForBackground: Color {
        switch background {
        case .light:
            return .black
        case .texture:
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
            transitionAfterUpscaled: transitionAfterUpscaled
        )
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
