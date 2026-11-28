import Foundation
import UIKit
import CoreImage

/// 漫画画面滤镜处理引擎（基于 CoreImage 与 Metal 硬件级 GPU 加速管线）
public final class ImageFilterPipeline: @unchecked Sendable {
    public static let shared = ImageFilterPipeline()

    private let ciContext: CIContext
    private let cache = NSCache<NSString, UIImage>()
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        // 创建高性能 Metal 硬件加速上下文
        let options: [CIContextOption: Any] = [
            .useSoftwareRenderer: false,
            .priorityRequestLow: false,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ]
        self.ciContext = CIContext(options: options)
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        self.cache.countLimit = 32
        self.cache.totalCostLimit = memGB >= 5.5 ? 100 * 1024 * 1024 : 64 * 1024 * 1024

        self.memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
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

        // 后台/非活跃状态禁止触发 CoreImage Metal 渲染，防止后台 GPU 提交被系统强杀
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            return image
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
                currentCI = applyGrayscale(
                    to: currentCI,
                    intensity: item.grayscaleIntensity,
                    contrast: item.grayscaleContrast
                )
            case .gamma:
                currentCI = applyGamma(to: currentCI, gamma: item.gammaValue)
            case .sharpen:
                currentCI = applySharpen(to: currentCI, sharpness: item.sharpnessValue)
            case .tone:
                currentCI = applyTone(
                    to: currentCI,
                    temperature: item.toneTemperature,
                    saturation: item.toneSaturation,
                    tintEnabled: item.toneTintEnabled,
                    tintColor: item.toneTintColor
                )
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

        // 写入缓存（单张超过 48MB 的超分大图不常驻滤镜缓存，避免与超分 L1 形成双份百兆驻留）
        if let key = fullCacheKey {
            let cost = cgImage.width * cgImage.height * 4
            if cost > 0 && cost <= 48 * 1024 * 1024 {
                cache.setObject(resultImage, forKey: key, cost: cost)
            }
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

    /// 生成跨排版模式统一的滤镜缓存 Key（避免条漫与翻页割裂，并隔离不同超分模型配置）
    public static func cacheKey(
        pageURL: String,
        upscalerConfig: ImageUpscalerConfig?,
        isUpscaled: Bool
    ) -> String {
        if isUpscaled, let upscalerConfig {
            return "\(pageURL)::upscaled::\(upscalerConfig.cacheKey)"
        }
        return "\(pageURL)::raw"
    }

    /// 同步查询已缓存的滤镜成品图（专供主线程快路径与预热跳过检查使用）
    public func cachedImage(cacheKey: String, config: ImageFilterConfig) -> UIImage? {
        guard config.hasActiveFilters else { return nil }
        let fullKey = "\(cacheKey)_\(config.cacheSignature)" as NSString
        return cache.object(forKey: fullKey)
    }

    /// 清空图片滤镜缓存
    public func clearCache() {
        cache.removeAllObjects()
    }

    // MARK: - 单项滤镜实现

    /// 1. 黑白滤镜（彩图变黑白，支持饱和度无级去色与独立对比度调节）
    private func applyGrayscale(to input: CIImage, intensity: Double, contrast: Double) -> CIImage {
        let clampedIntensity = min(max(intensity, 0.0), 1.0)
        let clampedContrast = min(max(contrast, 0.5), 2.0)
        guard clampedIntensity > 0.001 || abs(clampedContrast - 1.0) > 0.005 else {
            return input
        }
        guard let filter = CIFilter(name: "CIColorControls") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        // 饱和度从 1.0 降低至 0.0 (纯净无损去色，保持白底纯净不发灰)
        filter.setValue(max(0.0, 1.0 - clampedIntensity), forKey: kCIInputSaturationKey)
        // 独立对比度调节（默认 1.12 令黑白线条分明，用户可按需拉高去灰或降低保留灰阶）
        filter.setValue(clampedContrast, forKey: kCIInputContrastKey)
        return filter.outputImage ?? input
    }

    /// 2. 伽马校正（改善扫描图发灰、中间调发虚的问题，支持 0.2 ~ 3.0 宽幅校正）
    private func applyGamma(to input: CIImage, gamma: Double) -> CIImage {
        let clampedGamma = min(max(gamma, 0.2), 3.0)
        guard abs(clampedGamma - 1.0) > 0.005 else { return input }
        guard let filter = CIFilter(name: "CIGammaAdjust") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        // inputPower > 1.0 压暗发灰背景加深墨线，< 1.0 提亮画面
        filter.setValue(clampedGamma, forKey: "inputPower")
        return filter.outputImage ?? input
    }

    /// 3. 锐化（边缘轮廓清晰化，提升漫画网点与线条锐利度，支持 0.0 ~ 2.0）
    private func applySharpen(to input: CIImage, sharpness: Double) -> CIImage {
        let clampedSharpness = min(max(sharpness, 0.0), 2.0)
        guard clampedSharpness > 0.01 else { return input }
        guard let filter = CIFilter(name: "CISharpenLuminance") else { return input }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(clampedSharpness, forKey: kCIInputSharpnessKey)
        return filter.outputImage ?? input
    }

    /// 4. 色调（冷暖色温 + 零开销 CIColorMatrix 护眼染纸色 + 独立饱和度）
    private func applyTone(
        to input: CIImage,
        temperature: Double,
        saturation: Double,
        tintEnabled: Bool,
        tintColor: FilterRGBColor
    ) -> CIImage {
        var current = input

        // 4.1 冷暖色温调节（基准 6500K，正值偏暖、负值偏冷）
        if abs(temperature) > 0.01, let tempFilter = CIFilter(name: "CITemperatureAndTint") {
            tempFilter.setValue(current, forKey: kCIInputImageKey)
            let neutral = CIVector(x: 6500, y: 0)
            let targetTemp = 6500.0 - (temperature * 2400.0)
            let targetTint = temperature * 12.0
            let target = CIVector(x: CGFloat(targetTemp), y: CGFloat(targetTint))
            tempFilter.setValue(neutral, forKey: "inputNeutral")
            tempFilter.setValue(target, forKey: "inputTargetNeutral")
            if let out = tempFilter.outputImage {
                current = out
            }
        }

        // 4.2 护眼染纸色（使用 GPU 单指令 CIColorMatrix 逐通道相乘，与 3D LUT 数学等价且零内存分配，纯黑墨线不受影响）
        if tintEnabled,
           (tintColor.red < 0.999 || tintColor.green < 0.999 || tintColor.blue < 0.999),
           let matrixFilter = CIFilter(name: "CIColorMatrix") {
            matrixFilter.setValue(current, forKey: kCIInputImageKey)
            matrixFilter.setValue(CIVector(x: CGFloat(tintColor.red), y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrixFilter.setValue(CIVector(x: 0, y: CGFloat(tintColor.green), z: 0, w: 0), forKey: "inputGVector")
            matrixFilter.setValue(CIVector(x: 0, y: 0, z: CGFloat(tintColor.blue), w: 0), forKey: "inputBVector")
            matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
            if let out = matrixFilter.outputImage {
                current = out
            }
        }

        // 4.3 独立饱和度调节（0.0 ~ 2.0，1.0 为原始色彩）
        let clampedSat = min(max(saturation, 0.0), 2.0)
        if abs(clampedSat - 1.0) > 0.01, let satFilter = CIFilter(name: "CIColorControls") {
            satFilter.setValue(current, forKey: kCIInputImageKey)
            satFilter.setValue(clampedSat, forKey: kCIInputSaturationKey)
            if let out = satFilter.outputImage {
                current = out
            }
        }

        return current
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
