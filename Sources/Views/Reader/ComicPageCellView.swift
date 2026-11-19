import SwiftUI
import UIKit

/// 单页加载与超分状态托管类（复用 Slot 逻辑并支持快速复原）
@MainActor
public final class ComicPageSlot: ObservableObject {
    @Published public var originalImage: UIImage?
    @Published public var processed: ProcessedPageImage?
    @Published public var isLoading = true
    @Published public var isUpscaling = false
    @Published public var errorMessage: String?

    public init() {}

    public func loadAndProcess(page: MangaPage, config: ImageUpscalerConfig) async {
        errorMessage = nil
        if originalImage == nil {
            isLoading = true
            do {
                originalImage = try await OnlineImageLoader.shared.loadImage(
                    urlString: page.imageURL,
                    headers: page.headers
                )
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
                return
            }
            isLoading = false
            await Task.yield()
        }

        guard let original = originalImage else { return }

        if config.engine == .off {
            let size = CGSize(
                width: original.cgImage?.width ?? Int(original.size.width),
                height: original.cgImage?.height ?? Int(original.size.height)
            )
            processed = ProcessedPageImage(
                image: original,
                originalSize: size,
                outputSize: size,
                elapsedMs: 0,
                appliedEngine: .off
            )
            return
        }

        isUpscaling = true
        defer { isUpscaling = false }
        processed = await PageUpscalerPipeline.shared.process(
            image: original,
            pageKey: page.imageURL,
            config: config
        )
    }

    /// 释放大图内存以应对长列表/长时间翻页，仅保留占位状态
    public func releaseImageMemory() {
        originalImage = nil
        processed = nil
        isLoading = false
        isUpscaling = false
    }
}

/// 统一单页漫画呈现视图（内嵌缩放、分屏对比、中缝立体阴影与超分状态更新）
public struct ComicPageCellView: View {
    public let page: MangaPage
    public let config: ImageUpscalerConfig
    public let isCompareMode: Bool
    public let showSpineShadow: Bool
    public let isRightToLeft: Bool
    public let onSingleTap: () -> Void
    public let onStatusUpdate: (String) -> Void
    public var onZoomChanged: ((CGFloat) -> Void)? = nil

    @StateObject private var slot = ComicPageSlot()

    public init(
        page: MangaPage,
        config: ImageUpscalerConfig,
        isCompareMode: Bool = false,
        showSpineShadow: Bool = false,
        isRightToLeft: Bool = false,
        onSingleTap: @escaping () -> Void,
        onStatusUpdate: @escaping (String) -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.page = page
        self.config = config
        self.isCompareMode = isCompareMode
        self.showSpineShadow = showSpineShadow
        self.isRightToLeft = isRightToLeft
        self.onSingleTap = onSingleTap
        self.onStatusUpdate = onStatusUpdate
        self.onZoomChanged = onZoomChanged
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let orig = slot.originalImage {
                let displayImage = slot.processed?.image ?? orig
                if isCompareMode, config.engine != .off, let processed = slot.processed {
                    SplitCompareView(
                        originalImage: orig,
                        enhancedImage: processed.image,
                        engineLabel: config.engine.shortName
                    )
                } else {
                    ZoomableImageView(
                        image: displayImage,
                        onSingleTap: onSingleTap,
                        onZoomChanged: onZoomChanged
                    )
                }

                // 书脊中缝立体渐变阴影（还原实体书装订处凹陷光影）
                if showSpineShadow && !isCompareMode {
                    spineShadowOverlay
                }

                if slot.isUpscaling {
                    VStack {
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("正在执行 \(config.engine.shortName) 2x 超分...")
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
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Button("重试") {
                        Task { await triggerLoad() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("加载第 \(page.index + 1) 页...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(page.id)::\(config.cacheKey)") {
            await triggerLoad()
        }
    }

    /// 纸张书脊中缝立体渐变阴影
    @ViewBuilder
    private var spineShadowOverlay: some View {
        HStack {
            if isRightToLeft {
                Spacer()
                LinearGradient(
                    colors: [.black.opacity(0.0), .black.opacity(0.36)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
                .allowsHitTesting(false)
            } else {
                LinearGradient(
                    colors: [.black.opacity(0.36), .black.opacity(0.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 22)
                .allowsHitTesting(false)
                Spacer()
            }
        }
        .ignoresSafeArea()
    }

    private func triggerLoad() async {
        await slot.loadAndProcess(page: page, config: config)
        if let p = slot.processed {
            let orig = "\(Int(p.originalSize.width))×\(Int(p.originalSize.height))"
            let out = "\(Int(p.outputSize.width))×\(Int(p.outputSize.height))"
            if let notice = p.notice {
                onStatusUpdate("\(orig) → \(out) · \(notice)")
            } else if p.appliedEngine == .off {
                onStatusUpdate("原图 \(orig)")
            } else {
                onStatusUpdate("\(p.appliedEngine.shortName) · \(orig) → \(out) · \(p.elapsedMs)ms")
            }
        }
    }
}
