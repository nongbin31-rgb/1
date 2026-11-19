import Foundation
import UIKit
import CoreImage

/// 漫画画面滤镜处理引擎（基于 CoreImage 与 Metal 硬件级 GPU 加速管线）
public final class ImageFilterPipeline: @unchecked Sendable {
    public static let shared = ImageFilterPipeline()

    private let ciContext: CIContext
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        // 创建高性能 Metal 硬件加速上下文
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ]
        self.ciContext = CIContext(options: options)
        self.cache.countLimit = 64
        self.cache.totalCostLimit = 150 * 1024 * 1024 // 150MB 内存缓存保护
    }

    /// 应用滤镜链并生成新图片
    /// - Parameters:
    ///   - image: 输入的原图
    ///   - cacheKey: 缓存唯一标识符（如图片 URL 或图片 ID），可为空
    ///   - config: 滤镜配置
    /// - Returns: 处理完成的 UIImage
    public func process(
        image: UIImage,
        cacheKey: String? = nil,
        config: ImageFilterConfig
    ) -> UIImage {
        // 若没有启用任何滤镜，零开销直通返回原图
        guard config.hasActiveFilters else {
            return image
        }

        // 尝试从内存缓存中命中
        let signature = config.cacheSignature
        let fullCacheKey: NSString? = cacheKey.map { "\($0)_\(signature)" as NSString }
        if let key = fullCacheKey, let cached = cache.object(forKey: key) {
            return cached
        }

        guard let cgImage = image.cgImage else {
            return image
        }

        var currentCI = CIImage(cgImage: cgImage)

        // 依照用户配置的滤镜顺序依次执行滤镜管线
        for type in config.activeFilterTypes {
            let item = config.config(for: type)
            switch type {
            case .grayscale:
                currentCI = applyGrayscale(to: currentCI, intensity: item.grayscaleIntensity)
            case .gamma:
                currentCI = applyGamma(to: currentCI, gamma: item.gammaValue)
            case .sharpen:
                currentCI = applySharpen(to: currentCI, sharpness: item.sharpnessValue)
            case .tone:
                currentCI = applyTone(to: currentCI, temperature: item.toneTemperature)
            case .shadow:
                currentCI = applyShadow(to: currentCI, shadowAmount: item.shadowAmount)
            }
        }

        let outputRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let outputCG = ciContext.createCGImage(currentCI, from: outputRect) else {
            return image
        }

        let resultImage = UIImage(
            cgImage: outputCG,
            scale: image.scale,
            orientation: image.imageOrientation
        )

        // 写入缓存
        if let key = fullCacheKey {
            let cost = cgImage.width * cgImage.height * 4
            cache.setObject(resultImage, forKey: key, cost: cost)
        }

        return resultImage
    }

    /// 异步处理接口（适合后台高分辨率批量渲染）
    public func processAsync(
        image: UIImage,
        cacheKey: String? = nil,
        config: ImageFilterConfig
    ) async -> UIImage {
        guard config.hasActiveFilters else { return image }
        return await Task.detached(priority: .userInitiated) {
            self.process(image: image, cacheKey: cacheKey, config: config)
        }.value
    }

    /// 清空图片滤镜缓存
    public func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - 单项滤镜实现

    /// 1. 黑白滤镜（彩图变黑白，支持饱和度无级过渡与反差微调）
    private func applyGrayscale(to input: CIImage, intensity: Double) -> CIImage {
        guard intensity > 0.001 else { return input }
        guard let filter = CIFilter(name: "CIColorControls") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        // 饱和度从 1.0 降低至 0.0 (去色)
        let saturation = max(0.0, 1.0 - intensity)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        // 配合轻微对比度增强让黑白漫画线条更加黑白分明
        let contrast = 1.0 + (0.12 * intensity)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        return filter.outputImage ?? input
    }

    /// 2. 伽马校正（改善扫描图发灰、中间调发虚的问题）
    private func applyGamma(to input: CIImage, gamma: Double) -> CIImage {
        guard abs(gamma - 1.0) > 0.01 else { return input }
        guard let filter = CIFilter(name: "CIGammaAdjust") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        // inputPower > 1.0 压暗发灰背景加深墨线，< 1.0 提亮画面
        filter.setValue(gamma, forKey: "inputPower")
        return filter.outputImage ?? input
    }

    /// 3. 锐化（边缘轮廓清晰化，提升漫画网点与线条锐利度）
    private func applySharpen(to input: CIImage, sharpness: Double) -> CIImage {
        guard sharpness > 0.05 else { return input }
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(sharpness, forKey: kCIInputSharpnessKey)
        return filter.outputImage ?? input
    }

    /// 4. 色调（冷暖调节、墨水屏色调与暖黄纸张护眼）
    private func applyTone(to input: CIImage, temperature: Double) -> CIImage {
        guard abs(temperature) > 0.01 else { return input }
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)

        // 基准中性色温: 6500K
        let neutral = CIVector(x: 6500, y: 0)
        // 当 temperature > 0 时为暖光（羊皮纸护眼色，低至 4500K），< 0 时为冷光
        let targetTemp = 6500.0 - (temperature * 2400.0)
        let targetTint = temperature * 12.0
        let target = CIVector(x: CGFloat(targetTemp), y: CGFloat(targetTint))

        filter.setValue(neutral, forKey: "inputNeutral")
        filter.setValue(target, forKey: "inputTargetNeutral")
        return filter.outputImage ?? input
    }

    /// 5. 阴影（调节暗部深浅与阴影层次）
    private func applyShadow(to input: CIImage, shadowAmount: Double) -> CIImage {
        guard abs(shadowAmount) > 0.01 else { return input }
        guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        // inputShadowAmount 在 CoreImage 中范围 0.0 ~ 1.0 为提亮阴影
        // 当 shadowAmount > 0 时提亮暗部细节；当 shadowAmount < 0 时配合黑色级别压暗纯黑
        if shadowAmount >= 0 {
            filter.setValue(shadowAmount, forKey: "inputShadowAmount")
            return filter.outputImage ?? input
        } else {
            // 压暗阴影：通过轻微曝光和对比度微调加深暗部
            if let colorControl = CIFilter(name: "CIColorControls") {
                colorControl.setValue(input, forKey: kCIInputImageKey)
                colorControl.setValue(1.0 + abs(shadowAmount) * 0.15, forKey: kCIInputContrastKey)
                colorControl.setValue(shadowAmount * 0.06, forKey: kCIInputBrightnessKey)
                return colorControl.outputImage ?? input
            }
            return input
        }
    }
}
