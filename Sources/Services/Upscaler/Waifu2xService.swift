import CoreGraphics
import CoreML
import Foundation
import UIKit

public enum Waifu2xServiceError: LocalizedError {
    case imageTooSmall(width: Int, height: Int)
    case imageTooLarge(width: Int, height: Int)
    case decodeFailed
    case modelNotFound(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .imageTooSmall(w, h):
            return "图片尺寸过小 (\(w)×\(h))，Waifu2x 要求最小边 ≥ 200px"
        case let .imageTooLarge(w, h):
            return "图片尺寸过大 (\(w)×\(h))，超过 2500px 上限已跳过超分"
        case .decodeFailed:
            return "位图预解码失败"
        case let .modelNotFound(name):
            return "未找到 CoreML 模型包: \(name)"
        case let .inferenceFailed(msg):
            return "Waifu2x 神经网络推理失败: \(msg)"
        }
    }
}

/// Waifu2x 端侧 CoreML 深度超分服务（基于可达阅读器内置 waifu2x.framework + Apple Neural Engine）
/// 注意：Waifu2x 内部使用全局静态管道变量，不能并发重入！
/// 这里使用独立串行队列 + 异步排他锁保证全 App 任何时刻最多只有 1 个 Waifu2x 任务执行。
public final class Waifu2xService: @unchecked Sendable {
    public static let shared = Waifu2xService()

    public static let minDimension: Int = 200
    public static let maxDimension: Int = 2500

    /// 严格串行调度队列（非可重入），避免多页并发调用导致静态管道踩踏
    private let serialQueue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.waifu2x.serial", qos: .userInitiated)

    /// 缓存已编译加载的 MLModel 实例
    private var mlModelCache: [String: MLModel] = [:]
    private let modelCacheLock = NSLock()

    private init() {}

    /// 执行 Waifu2x 2x 超分辨率放大
    /// - Parameters:
    ///   - image: 输入原始图像
    ///   - model: 10 组模型之一（漫画/照片，不同降噪等级）
    ///   - progress: 进度回调 (0% ~ 100%)
    /// - Returns: 2 倍放大后的高清 UIImage
    public func enhance(
        image: UIImage,
        model: Waifu2xModel = .anime_noise1_scale2x,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UIImage {
        // 1. 强制位图预解码并统一为 scale = 1.0、orientation = .up，规避 iOS 延迟解码崩溃
        guard let preparedImage = Self.forceDecodeToPixelImage(image) else {
            throw Waifu2xServiceError.decodeFailed
        }

        let width = Int(preparedImage.size.width)
        let height = Int(preparedImage.size.height)

        // 2. 双向尺寸安全阈值拦截（下限 200px 防分块越界，上限 2500px 防爆内存）
        guard width >= Self.minDimension && height >= Self.minDimension else {
            throw Waifu2xServiceError.imageTooSmall(width: width, height: height)
        }
        guard width <= Self.maxDimension && height <= Self.maxDimension else {
            throw Waifu2xServiceError.imageTooLarge(width: width, height: height)
        }

        // 3. 在专用串行队列中严格排队执行推理
        return try await withCheckedThrowingContinuation { continuation in
            serialQueue.async {
                autoreleasepool {
                    do {
                        // 优先尝试动态调用已加载的 waifu2x.framework 原生 run 函数
                        if let nativeResult = Self.tryNativeWaifu2xRun(image: preparedImage, model: model, progress: progress) {
                            continuation.resume(returning: nativeResult)
                            return
                        }

                        // 如果框架动态符号未加载，则使用 CoreML 原生执行 framework 内的 .mlmodelc
                        let coreMLResult = try self.runCoreMLTiledInference(image: preparedImage, model: model, progress: progress)
                        continuation.resume(returning: coreMLResult)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - 动态调用 waifu2x.framework

    private static func tryNativeWaifu2xRun(
        image: UIImage,
        model: Waifu2xModel,
        progress: (@Sendable (String) -> Void)?
    ) -> UIImage? {
        // 查找 waifu2x.framework 是否已由系统动态链接
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }

        // Swift mangled 符号：_$s7waifu2x7Waifu2xC3run_5model_So7UIImageCSgAH_AA5ModelOSgySSctFZ
        let symbol = "_$s7waifu2x7Waifu2xC3run_5model_So7UIImageCSgAH_AA5ModelOSgySSctFZ"
        guard let sym = dlsym(handle, symbol) else { return nil }

        // 对应原版 waifu2x.Model 内存布局 (enum 带 18 个 case，从 0 开始对应)
        let modelIndex = Self.modelToWaifu2xEnumIndex(model)
        typealias Waifu2xRunFunc = @convention(c) (
            UIImage,
            UInt8,
            AnyObject?,
            AnyObject?
        ) -> UIImage?

        let runFunc = unsafeBitCast(sym, to: Waifu2xRunFunc.self)
        return runFunc(image, modelIndex, nil, nil)
    }

    private static func modelToWaifu2xEnumIndex(_ model: Waifu2xModel) -> UInt8 {
        switch model {
        case .anime_noise0_scale2x: return 8
        case .anime_noise1_scale2x: return 9
        case .anime_noise2_scale2x: return 10
        case .anime_noise3_scale2x: return 11
        case .anime_scale2x:        return 12
        case .photo_noise0_scale2x: return 13
        case .photo_noise1_scale2x: return 14
        case .photo_noise2_scale2x: return 15
        case .photo_noise3_scale2x: return 16
        case .photo_scale2x:        return 17
        }
    }

    // MARK: - CoreML 原生分块推理（加载 waifu2x.framework 内置 .mlmodelc）

    private func runCoreMLTiledInference(
        image: UIImage,
        model: Waifu2xModel,
        progress: (@Sendable (String) -> Void)?
    ) throws -> UIImage {
        // 1. 寻找模型 bundle 路径
        guard let modelURL = Self.locateModelURL(for: model) else {
            throw Waifu2xServiceError.modelNotFound(model.modelBundleName)
        }

        let mlModel = try getOrLoadMLModel(at: modelURL)

        guard let cgImage = image.cgImage else {
            throw Waifu2xServiceError.decodeFailed
        }

        let inputWidth = cgImage.width
        let inputHeight = cgImage.height

        // 2. 模型固定块大小与重叠边距
        let tileSize = 128
        let padding = 14
        let innerSize = tileSize - padding * 2 // 100

        let xTiles = Int(ceil(Double(inputWidth) / Double(innerSize)))
        let yTiles = Int(ceil(Double(inputHeight) / Double(innerSize)))
        let totalTiles = xTiles * yTiles

        let outputWidth = inputWidth * 2
        let outputHeight = inputHeight * 2

        UIGraphicsBeginImageContextWithOptions(CGSize(width: outputWidth, height: outputHeight), true, 1.0)
        guard let outputContext = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            throw Waifu2xServiceError.inferenceFailed("无法创建输出位图上下文")
        }

        var completedTiles = 0
        for y in 0..<yTiles {
            for x in 0..<xTiles {
                let srcX = x * innerSize - padding
                let srcY = y * innerSize - padding

                let cropRect = CGRect(x: srcX, y: srcY, width: tileSize, height: tileSize)
                guard let tileCG = Self.cropWithPadding(cgImage: cgImage, rect: cropRect) else {
                    continue
                }

                // 准备 MLMultiArray 输入 [3, 156, 156]（在 128 上做 14 边距扩展到 156）
                let multiArray = try Self.cgImageToMultiArray(tileCG, targetSize: 156)
                let featureProvider = Waifu2xMLFeatureProvider(input: multiArray)
                let prediction = try mlModel.prediction(from: featureProvider)

                if let outputArray = prediction.featureValue(for: "conv7")?.multiArrayValue,
                   let upscaledTileCG = Self.multiArrayToCGImage(outputArray, size: 312) {
                    // 裁剪掉扩边并拼接入大图
                    let validInnerOut = innerSize * 2
                    let cropOutRect = CGRect(x: padding * 2, y: padding * 2, width: validInnerOut, height: validInnerOut)
                    if let croppedOut = upscaledTileCG.cropping(to: cropOutRect) {
                        let dstX = CGFloat(x * innerSize * 2)
                        let dstY = CGFloat(y * innerSize * 2)
                        outputContext.draw(croppedOut, in: CGRect(x: dstX, y: dstY, width: CGFloat(croppedOut.width), height: CGFloat(croppedOut.height)))
                    }
                }

                completedTiles += 1
                let percent = Int(Double(completedTiles) / Double(totalTiles) * 100)
                progress?("\(percent)%")
            }
        }

        let finalCG = outputContext.makeImage()
        UIGraphicsEndImageContext()

        guard let finalCG else {
            throw Waifu2xServiceError.inferenceFailed("拼接超分大图失败")
        }

        return UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
    }

    private func getOrLoadMLModel(at url: URL) throws -> MLModel {
        modelCacheLock.lock()
        defer { modelCacheLock.unlock() }

        let key = url.lastPathComponent
        if let cached = mlModelCache[key] {
            return cached
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all // 优先 ANE（Neural Engine）与 GPU
        let model = try MLModel(contentsOf: url, configuration: config)
        mlModelCache[key] = model
        return model
    }

    private static func locateModelURL(for model: Waifu2xModel) -> URL? {
        let name = model.rawValue // 如 "up_anime_noise1_scale2x_model"
        // 1. 在 waifu2x.framework 内部查找
        if let fwBundle = Bundle(identifier: "xieyi.waifu2x"),
           let url = fwBundle.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        // 2. 在 Frameworks 目录下查找
        if let mainFwURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("waifu2x.framework/\(name).mlmodelc"),
           FileManager.default.fileExists(atPath: mainFwURL.path) {
            return mainFwURL
        }
        // 3. 在主工程 Bundle 根目录查找
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        return nil
    }

    // MARK: - 辅助位图处理工具

    private static func cropWithPadding(cgImage: CGImage, rect: CGRect) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height

        UIGraphicsBeginImageContextWithOptions(rect.size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return nil
        }

        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: rect.size))

        let drawRect = CGRect(x: -rect.origin.x, y: -rect.origin.y, width: CGFloat(width), height: CGFloat(height))
        ctx.draw(cgImage, in: drawRect)

        let result = ctx.makeImage()
        UIGraphicsEndImageContext()
        return result
    }

    private static func cgImageToMultiArray(_ cgImage: CGImage, targetSize: Int) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 3, NSNumber(value: targetSize), NSNumber(value: targetSize)]
        let multiArray = try MLMultiArray(shape: shape, dataType: .double)

        let width = cgImage.width
        let height = cgImage.height
        var rawBytes = [UInt8](repeating: 0, count: width * height * 4)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &rawBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let ptr = multiArray.dataPointer.bindMemory(to: Double.self, capacity: 3 * targetSize * targetSize)
        for c in 0..<3 {
            let channelOffset = c * targetSize * targetSize
            for y in 0..<targetSize {
                let srcY = min(y, height - 1)
                for x in 0..<targetSize {
                    let srcX = min(x, width - 1)
                    let pixelIndex = (srcY * width + srcX) * 4
                    let val = Double(rawBytes[pixelIndex + c]) / 255.0
                    ptr[channelOffset + y * targetSize + x] = val
                }
            }
        }

        return multiArray
    }

    private static func multiArrayToCGImage(_ array: MLMultiArray, size: Int) -> CGImage? {
        let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: 3 * size * size)
        var rawBytes = [UInt8](repeating: 255, count: size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                let pixelIdx = (y * size + x) * 4
                for c in 0..<3 {
                    let channelOffset = c * size * size
                    let val = ptr[channelOffset + y * size + x]
                    let clamped = max(0.0, min(1.0, val))
                    rawBytes[pixelIdx + c] = UInt8(clamped * 255.0)
                }
            }
        }

        let cfData = Data(rawBytes) as CFData
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    /// 强制将图像绘制为 8-bit sRGB 完整内存位图，scale = 1.0，orientation = .up
    public static func forceDecodeToPixelImage(_ image: UIImage) -> UIImage? {
        let pixelWidth: Int
        let pixelHeight: Int
        if let cg = image.cgImage {
            if image.imageOrientation == .left || image.imageOrientation == .leftMirrored ||
               image.imageOrientation == .right || image.imageOrientation == .rightMirrored {
                pixelWidth = cg.height
                pixelHeight = cg.width
            } else {
                pixelWidth = cg.width
                pixelHeight = cg.height
            }
        } else {
            pixelWidth = Int(image.size.width * image.scale)
            pixelHeight = Int(image.size.height * image.scale)
        }

        guard pixelWidth > 0 && pixelHeight > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        format.preferredRange = .standard

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pixelWidth, height: pixelHeight),
            format: format
        )
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        guard let cgImage = rendered.cgImage else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: nil,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard let decompressed = context.makeImage() else { return nil }
        return UIImage(cgImage: decompressed, scale: 1.0, orientation: .up)
    }
}

// MARK: - CoreML 特性提供者辅助类

private final class Waifu2xMLFeatureProvider: MLFeatureProvider {
    let input: MLMultiArray

    init(input: MLMultiArray) {
        self.input = input
    }

    var featureNames: Set<String> {
        ["input"]
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "input" {
            return MLFeatureValue(multiArray: input)
        }
        return nil
    }
}
