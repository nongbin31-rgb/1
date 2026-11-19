import CoreGraphics
import CoreML
import Darwin
import Foundation
import UIKit

public enum Waifu2xServiceError: LocalizedError {
    case imageTooSmall(width: Int, height: Int)
    case imageTooLarge(width: Int, height: Int, maxPixels: Int)
    case decodeFailed
    case memoryAllocationFailed
    case modelNotFound(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .imageTooSmall(w, h):
            return "图片尺寸过小 (\(w)×\(h))，Waifu2x 要求最小边 ≥ 32px"
        case let .imageTooLarge(w, h, maxPixels):
            let mp = String(format: "%.1f", Double(w * h) / 1_000_000.0)
            let limitMP = maxPixels / 1_000_000
            return "图片总像素过大 (\(w)×\(h)，约 \(mp)M)，超过默认 \(limitMP)M 上限已跳过超分"
        case .decodeFailed:
            return "位图预解码失败"
        case .memoryAllocationFailed:
            return "设备可用内存不足，无法分配超分位图缓冲区"
        case let .modelNotFound(name):
            return "未找到 CoreML 模型包: \(name)"
        case let .inferenceFailed(msg):
            return "Waifu2x 神经网络推理失败: \(msg)"
        }
    }
}

/// Waifu2x 端侧 CoreML 深度超分服务（基于 Apple Neural Engine / Metal GPU）
/// 严格对齐官方 waifu2x 算法规范：
/// 块大小 142px、边缘扩展 7px (输入 156px)、反卷积输出 284px (2x 超分重建)
public final class Waifu2xService: @unchecked Sendable {
    public static let shared = Waifu2xService()

    public static let minDimension: Int = 32
    /// 默认最大允许总像素（1200 万像素，兼容 800×8000 等模糊条漫长图）
    public static let maxPixelCount: Int = ImageUpscalerConfig.maxPixelCountThreshold

    /// 严格串行调度队列，避免多页并发导致显存瞬间挤爆
    private let serialQueue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.waifu2x.serial", qos: .userInitiated)

    /// 缓存已编译加载的 MLModel 实例
    private var mlModelCache: [String: MLModel] = [:]
    private let modelCacheLock = NSLock()

    private init() {}

    /// 执行 Waifu2x 2x 超分辨率放大
    /// - Parameters:
    ///   - image: 输入原始图像
    ///   - model: 10 组模型之一（漫画/照片，不同降噪等级）
    ///   - bypassSizeLimit: 是否解除默认总像素上限
    ///   - progress: 进度回调 (0% ~ 100%)
    /// - Returns: 2 倍放大后的高清 UIImage
    public func enhance(
        image: UIImage,
        model: Waifu2xModel = .anime_noise1_scale2x,
        bypassSizeLimit: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UIImage {
        // 1. 先检查像素尺寸（避免超限图先做位图解码浪费内存）
        let (width, height) = Self.pixelDimensions(of: image)
        guard width >= Self.minDimension && height >= Self.minDimension else {
            throw Waifu2xServiceError.imageTooSmall(width: width, height: height)
        }
        if !bypassSizeLimit {
            let pixelCount = width * height
            guard pixelCount <= Self.maxPixelCount else {
                throw Waifu2xServiceError.imageTooLarge(
                    width: width,
                    height: height,
                    maxPixels: Self.maxPixelCount
                )
            }
        }

        // 2. 若原图已是正向 CGImage 则免去冗余中间拷贝，仅方向非 .up 或缺失 cgImage 时预解码规范化
        let preparedImage: UIImage
        if image.cgImage != nil && image.imageOrientation == .up {
            preparedImage = image
        } else {
            guard let decoded = Self.forceDecodeToPixelImage(image) else {
                throw Waifu2xServiceError.decodeFailed
            }
            preparedImage = decoded
        }

        // 3. 在专用串行队列中排队执行 CoreML 原生分块推理
        return try await withCheckedThrowingContinuation { continuation in
            serialQueue.async {
                autoreleasepool {
                    do {
                        let result = try self.runCoreMLTiledInference(image: preparedImage, model: model, progress: progress)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - CoreML 原生分块推理（加载 waifu2x 官方 10 组 .mlmodelc）

    private func runCoreMLTiledInference(
        image: UIImage,
        model: Waifu2xModel,
        progress: (@Sendable (String) -> Void)?
    ) throws -> UIImage {
        guard let cgImage = image.cgImage else {
            throw Waifu2xServiceError.decodeFailed
        }

        let width = cgImage.width
        let height = cgImage.height

        // 1. 提取原图 8-bit RGBA 像素数据（推理结束后立刻释放）
        let srcBytes = width * height * 4
        guard srcBytes > 0, let srcRawPtr = calloc(srcBytes, 1) else {
            throw Waifu2xServiceError.memoryAllocationFailed
        }
        var srcFreed = false
        defer {
            if !srcFreed {
                free(srcRawPtr)
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let srcBitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: srcRawPtr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: srcBitmapInfo
        ) else {
            throw Waifu2xServiceError.decodeFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let srcPtr = srcRawPtr.bindMemory(to: UInt8.self, capacity: srcBytes)

        // 2. Waifu2x 官方 2x 模型数学规格
        let blockSize = 142
        let shrinkSize = 7
        let inputTileSize = blockSize + 2 * shrinkSize // 156
        let outputTileSize = blockSize * 2 // 284
        let outScale = 2
        let targetWidth = width * outScale
        let targetHeight = height * outScale

        // 分配目标大图像素缓冲区（零拷贝移交 CGDataProvider，彻底消除 Data(dstPixels) 双倍内存峰值）
        let targetBytes = targetWidth * targetHeight * 4
        guard targetBytes > 0, let dstRawPtr = malloc(targetBytes) else {
            throw Waifu2xServiceError.memoryAllocationFailed
        }
        memset(dstRawPtr, 255, targetBytes)
        var dstOwnershipTransferred = false
        defer {
            if !dstOwnershipTransferred {
                free(dstRawPtr)
            }
        }
        let dstPtr = dstRawPtr.bindMemory(to: UInt8.self, capacity: targetBytes)

        // 3. 计算覆盖原图的全部切片区域
        let rects = Self.computeTileRects(width: width, height: height, step: blockSize)
        let totalTiles = rects.count
        guard totalTiles > 0 else {
            throw Waifu2xServiceError.inferenceFailed("分块切片失败")
        }

        // 4. 加载 CoreML 模型
        guard let modelURL = Self.locateModelURL(for: model) else {
            throw Waifu2xServiceError.modelNotFound(model.modelBundleName)
        }
        let mlModel = try getOrLoadMLModel(at: modelURL)

        // 5. 准备可复用的输入 MLMultiArray [3, 156, 156]（Double 类型）
        let inputShape: [NSNumber] = [3, NSNumber(value: inputTileSize), NSNumber(value: inputTileSize)]
        let inputMultiArray = try MLMultiArray(shape: inputShape, dataType: .double)
        let inputPtr = inputMultiArray.dataPointer.bindMemory(to: Double.self, capacity: 3 * inputTileSize * inputTileSize)
        let featureProvider = Waifu2xMLFeatureProvider(input: inputMultiArray)

        let inputPlaneSize = inputTileSize * inputTileSize

        // 6. 逐块执行推理并填充目标缓冲区
        for (tileIndex, rect) in rects.enumerated() {
            let originX = Int(rect.origin.x)
            let originY = Int(rect.origin.y)

            // 采样原图像素至 [3, 156, 156]，边界处采用镜像/边缘复制 (Edge Clamping)
            for py in 0..<inputTileSize {
                let sampleY = min(max(originY - shrinkSize + py, 0), height - 1)
                let rowOffset = sampleY * width
                let planeRow = py * inputTileSize

                for px in 0..<inputTileSize {
                    let sampleX = min(max(originX - shrinkSize + px, 0), width - 1)
                    let pixelIdx = (rowOffset + sampleX) * 4

                    let r = Double(srcPtr[pixelIdx]) / 255.0
                    let g = Double(srcPtr[pixelIdx + 1]) / 255.0
                    let b = Double(srcPtr[pixelIdx + 2]) / 255.0

                    let offsetInPlane = planeRow + px
                    inputPtr[offsetInPlane] = r
                    inputPtr[inputPlaneSize + offsetInPlane] = g
                    inputPtr[inputPlaneSize * 2 + offsetInPlane] = b
                }
            }

            // 单块推理放入 autoreleasepool，防止超长条漫数百个分块导致 CoreML 临时对象持续堆积
            try autoreleasepool {
                let prediction = try mlModel.prediction(from: featureProvider)
                guard let outputArray = prediction.featureValue(for: "conv7")?.multiArrayValue else {
                    throw Waifu2xServiceError.inferenceFailed("未找到输出层 conv7")
                }

                // 将 conv7 [3, 284, 284] 输出写入目标大图
                Self.writeOutputTile(
                    outputArray: outputArray,
                    outputTileSize: outputTileSize,
                    destOriginX: originX * outScale,
                    destOriginY: originY * outScale,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    dstPixels: dstPtr
                )
            }

            let percent = Int(Double(tileIndex + 1) / Double(totalTiles) * 100)
            progress?("\(percent)%")
        }

        // 提前释放原图像素缓冲
        free(srcRawPtr)
        srcFreed = true

        // 7. 零拷贝移交目标像素缓冲区所有权构建最终 UIImage
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: dstRawPtr,
            size: targetBytes,
            releaseData: { _, data, _ in
                free(UnsafeMutableRawPointer(mutating: data))
            }
        ) else {
            throw Waifu2xServiceError.inferenceFailed("无法创建位图数据提供者")
        }
        dstOwnershipTransferred = true

        let outBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        guard let finalCG = CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetWidth * 4,
            space: colorSpace,
            bitmapInfo: outBitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw Waifu2xServiceError.inferenceFailed("拼接超分大图失败")
        }

        return UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
    }

    /// 计算原图切片矩形网格（严格对应 142px 步长，边缘不足 142px 时靠外平移贴合，实现 100% 无缝覆盖）
    private static func computeTileRects(width: Int, height: Int, step: Int) -> [CGRect] {
        var xStarts: [Int] = []
        if width <= step {
            xStarts = [0]
        } else {
            var x = 0
            while x + step < width {
                xStarts.append(x)
                x += step
            }
            xStarts.append(width - step)
        }

        var yStarts: [Int] = []
        if height <= step {
            yStarts = [0]
        } else {
            var y = 0
            while y + step < height {
                yStarts.append(y)
                y += step
            }
            yStarts.append(height - step)
        }

        var rects: [CGRect] = []
        for y in yStarts {
            for x in xStarts {
                rects.append(CGRect(x: x, y: y, width: step, height: step))
            }
        }
        return rects
    }

    /// 安全读取 conv7 [3, 284, 284] 输出并直接写入目标像素指针（零拷贝，支持 Double、Float32、Float16 任意精度）
    private static func writeOutputTile(
        outputArray: MLMultiArray,
        outputTileSize: Int, // 284
        destOriginX: Int,
        destOriginY: Int,
        targetWidth: Int,
        targetHeight: Int,
        dstPixels: UnsafeMutablePointer<UInt8>
    ) {
        let planeSize = outputTileSize * outputTileSize
        let dataType = outputArray.dataType

        if dataType == .double {
            let ptr = outputArray.dataPointer.bindMemory(to: Double.self, capacity: 3 * planeSize)
            let rPtr = ptr
            let gPtr = ptr.advanced(by: planeSize)
            let bPtr = ptr.advanced(by: planeSize * 2)

            for sy in 0..<outputTileSize {
                let dy = destOriginY + sy
                guard dy >= 0 && dy < targetHeight else { continue }
                let dstRow = dy * targetWidth
                let srcRow = sy * outputTileSize

                for sx in 0..<outputTileSize {
                    let dx = destOriginX + sx
                    guard dx >= 0 && dx < targetWidth else { continue }

                    let srcIdx = srcRow + sx
                    let dstIdx = (dstRow + dx) * 4

                    let r = rPtr[srcIdx] * 255.0
                    let g = gPtr[srcIdx] * 255.0
                    let b = bPtr[srcIdx] * 255.0

                    dstPixels[dstIdx]     = UInt8(max(0.0, min(255.0, r)))
                    dstPixels[dstIdx + 1] = UInt8(max(0.0, min(255.0, g)))
                    dstPixels[dstIdx + 2] = UInt8(max(0.0, min(255.0, b)))
                    dstPixels[dstIdx + 3] = 255
                }
            }
        } else if dataType == .float32 {
            let ptr = outputArray.dataPointer.bindMemory(to: Float.self, capacity: 3 * planeSize)
            let rPtr = ptr
            let gPtr = ptr.advanced(by: planeSize)
            let bPtr = ptr.advanced(by: planeSize * 2)

            for sy in 0..<outputTileSize {
                let dy = destOriginY + sy
                guard dy >= 0 && dy < targetHeight else { continue }
                let dstRow = dy * targetWidth
                let srcRow = sy * outputTileSize

                for sx in 0..<outputTileSize {
                    let dx = destOriginX + sx
                    guard dx >= 0 && dx < targetWidth else { continue }

                    let srcIdx = srcRow + sx
                    let dstIdx = (dstRow + dx) * 4

                    let r = Double(rPtr[srcIdx]) * 255.0
                    let g = Double(gPtr[srcIdx]) * 255.0
                    let b = Double(bPtr[srcIdx]) * 255.0

                    dstPixels[dstIdx]     = UInt8(max(0.0, min(255.0, r)))
                    dstPixels[dstIdx + 1] = UInt8(max(0.0, min(255.0, g)))
                    dstPixels[dstIdx + 2] = UInt8(max(0.0, min(255.0, b)))
                    dstPixels[dstIdx + 3] = 255
                }
            }
        } else {
            // 通用下标兜底（支持 Float16 等未来格式）
            for sy in 0..<outputTileSize {
                let dy = destOriginY + sy
                guard dy >= 0 && dy < targetHeight else { continue }
                let dstRow = dy * targetWidth
                let srcRow = sy * outputTileSize

                for sx in 0..<outputTileSize {
                    let dx = destOriginX + sx
                    guard dx >= 0 && dx < targetWidth else { continue }

                    let srcIdx = srcRow + sx
                    let dstIdx = (dstRow + dx) * 4

                    let r = outputArray[srcIdx].doubleValue * 255.0
                    let g = outputArray[planeSize + srcIdx].doubleValue * 255.0
                    let b = outputArray[planeSize * 2 + srcIdx].doubleValue * 255.0

                    dstPixels[dstIdx]     = UInt8(max(0.0, min(255.0, r)))
                    dstPixels[dstIdx + 1] = UInt8(max(0.0, min(255.0, g)))
                    dstPixels[dstIdx + 2] = UInt8(max(0.0, min(255.0, b)))
                    dstPixels[dstIdx + 3] = 255
                }
            }
        }
    }

    private func getOrLoadMLModel(at url: URL) throws -> MLModel {
        modelCacheLock.lock()
        defer { modelCacheLock.unlock() }

        let key = url.lastPathComponent
        if let cached = mlModelCache[key] {
            return cached
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all // 优先 ANE（Apple Neural Engine）与 GPU
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
        // 2. 遍历所有加载的 Framework Bundle
        for bundle in Bundle.allFrameworks {
            if bundle.bundleURL.lastPathComponent == "waifu2x.framework",
               let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
                return url
            }
        }
        // 3. 在 Frameworks 目录下查找
        if let mainFwURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("waifu2x.framework/\(name).mlmodelc"),
           FileManager.default.fileExists(atPath: mainFwURL.path) {
            return mainFwURL
        }
        // 4. 在主工程 Bundle 根目录查找
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        // 5. 在 bundleURL 相对路径中查找
        let fallback = Bundle.main.bundleURL.appendingPathComponent("Frameworks/waifu2x.framework/\(name).mlmodelc")
        if FileManager.default.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    // MARK: - 辅助位图预解码（确保位图内存已就绪且 scale=1.0, orientation=.up，避免重复双份绘制）

    private static func pixelDimensions(of image: UIImage) -> (width: Int, height: Int) {
        if let cg = image.cgImage {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return (cg.height, cg.width)
            default:
                return (cg.width, cg.height)
            }
        }
        return (Int(image.size.width * image.scale), Int(image.size.height * image.scale))
    }

    public static func forceDecodeToPixelImage(_ image: UIImage) -> UIImage? {
        let (pixelWidth, pixelHeight) = pixelDimensions(of: image)
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
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
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
