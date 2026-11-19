import Foundation
import UIKit

/// 超分执行结果（包含处理后图片及诊断统计）
public struct ProcessedPageImage {
    public let image: UIImage
    public let originalSize: CGSize
    public let outputSize: CGSize
    public let elapsedMs: Int
    public let appliedModel: ImageUpscalerModel?
    public let notice: String?

    public init(
        image: UIImage,
        originalSize: CGSize,
        outputSize: CGSize,
        elapsedMs: Int,
        appliedModel: ImageUpscalerModel?,
        notice: String? = nil
    ) {
        self.image = image
        self.originalSize = originalSize
        self.outputSize = outputSize
        self.elapsedMs = elapsedMs
        self.appliedModel = appliedModel
        self.notice = notice
    }
}

/// 统一页面超分调度器（对齐可达阅读器：管理 Anime4K 与 Waifu2x 执行与近期显存级缓存）
public final class PageUpscalerPipeline: @unchecked Sendable {
    public static let shared = PageUpscalerPipeline()

    private let resultCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 180 * 1024 * 1024 // 约 180MB 上限，防止多张 2x 大图挤爆显存导致 Jetsam 闪退
        return cache
    }()

    private init() {}

    public func clearCache() {
        resultCache.removeAllObjects()
    }

    /// 对漫画单页执行超分（若命中缓存则瞬时返回）
    public func process(
        image: UIImage,
        pageKey: String,
        config: ImageUpscalerConfig,
        isEnabled: Bool = true
    ) async -> ProcessedPageImage {
        let origSize = pixelSize(of: image)

        // 1. 全局开关未开启则直接跳过
        guard isEnabled else {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil
            )
        }

        // 2. 尺寸安全硬上限截断：max(w, h) <= 2500px
        let maxSide = max(origSize.width, origSize.height)
        guard maxSide <= ImageUpscalerConfig.maxDimensionThreshold else {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil,
                notice: "图像单边超过 2500px，已自动跳过超分"
            )
        }

        let cacheKey = "\(pageKey)::\(config.cacheKey)" as NSString
        if let cached = resultCache.object(forKey: cacheKey) {
            return ProcessedPageImage(
                image: cached,
                originalSize: origSize,
                outputSize: pixelSize(of: cached),
                elapsedMs: 0,
                appliedModel: config.model,
                notice: "命中缓存"
            )
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let enhanced: UIImage
            switch config.model {
            case .anime4k:
                enhanced = try await Anime4kService.shared.enhance(image: image, config: config.anime4k)
            case .waifu2x:
                enhanced = try await Waifu2xService.shared.enhance(image: image, model: config.waifu2x)
            }

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let outSize = pixelSize(of: enhanced)
            let cost = Int(outSize.width * outSize.height * 4)
            resultCache.setObject(enhanced, forKey: cacheKey, cost: cost)

            return ProcessedPageImage(
                image: enhanced,
                originalSize: origSize,
                outputSize: outSize,
                elapsedMs: elapsedMs,
                appliedModel: config.model
            )
        } catch {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: elapsedMs,
                appliedModel: nil,
                notice: error.localizedDescription
            )
        }
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}
