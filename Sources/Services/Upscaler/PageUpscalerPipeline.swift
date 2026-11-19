import Foundation
import UIKit

/// 超分执行结果（包含处理后图片及诊断统计）
public struct ProcessedPageImage {
    public let image: UIImage
    public let originalSize: CGSize
    public let outputSize: CGSize
    public let elapsedMs: Int
    public let appliedEngine: UpscalerEngine
    public let notice: String?

    public init(
        image: UIImage,
        originalSize: CGSize,
        outputSize: CGSize,
        elapsedMs: Int,
        appliedEngine: UpscalerEngine,
        notice: String? = nil
    ) {
        self.image = image
        self.originalSize = originalSize
        self.outputSize = outputSize
        self.elapsedMs = elapsedMs
        self.appliedEngine = appliedEngine
        self.notice = notice
    }
}

/// 统一页面超分调度器（路由 Off / Anime4K / Waifu2x，并缓存近期超分结果）
public final class PageUpscalerPipeline: @unchecked Sendable {
    public static let shared = PageUpscalerPipeline()

    private let resultCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 180 * 1024 * 1024 // 约 180MB 上限，防止多张 2x 大图撑爆内存
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
        config: ImageUpscalerConfig
    ) async -> ProcessedPageImage {
        let origSize = pixelSize(of: image)

        guard config.engine != .off else {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedEngine: .off
            )
        }

        let cacheKey = "\(pageKey)::\(config.cacheKey)" as NSString
        if let cached = resultCache.object(forKey: cacheKey) {
            return ProcessedPageImage(
                image: cached,
                originalSize: origSize,
                outputSize: pixelSize(of: cached),
                elapsedMs: 0,
                appliedEngine: config.engine,
                notice: "命中超分缓存"
            )
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let enhanced: UIImage
            switch config.engine {
            case .off:
                enhanced = image
            case .anime4k:
                enhanced = try await Anime4kService.shared.enhance(image: image, config: config.anime4k)
            case .waifu2x:
                enhanced = try await Waifu2xService.shared.enhance(image: image, preset: config.waifu2x)
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
                appliedEngine: config.engine
            )
        } catch {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: elapsedMs,
                appliedEngine: .off,
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
