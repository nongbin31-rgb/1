import Accelerate
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

/// 线程安全取消令牌（用于及时中止排队中或分块循环中的过期 Waifu2x 推理任务）
private final class Waifu2xCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Waifu2x 端侧 CoreML 深度超分服务（基于 Apple Neural Engine / Metal GPU / BNNS）
/// 严格对齐官方 waifu2x 算法规范：
/// 块大小 142px、边缘扩展 7px (输入 156px)、反卷积输出 284px (2x 超分重建)
public final class Waifu2xService: @unchecked Sendable {
    public static let shared = Waifu2xService()

    public static let minDimension: Int = 32
    /// 默认最大允许总像素（1200 万像素，兼容 800×8000 等模糊条漫长图）
    public static let maxPixelCount: Int = ImageUpscalerConfig.maxPixelCountThreshold

    /// 严格串行调度队列，避免多页并发导致内存瞬间挤爆
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
        try Task.checkCancellation()

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

        try Task.checkCancellation()

        // 3. 在专用串行队列中排队执行 CoreML 原生分块推理，支持 Swift Task 协作式即时取消
        let cancelFlag = Waifu2xCancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                serialQueue.async {
                    if cancelFlag.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    autoreleasepool {
                        do {
                            let result = try self.runCoreMLTiledInference(
                                image: preparedImage,
                                model: model,
                                cancelFlag: cancelFlag,
                                progress: progress
                            )
                            continuation.resume(returning: result)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } onCancel: {
            cancelFlag.cancel()
        }
    }

    // MARK: - CoreML 原生分块推理（加载 waifu2x 官方 10 组 .mlmodelc）

    private func runCoreMLTiledInference(
        image: UIImage,
        model: Waifu2xModel,
        cancelFlag: Waifu2xCancellationFlag,
        progress: (@Sendable (String) -> Void)?
    ) throws -> UIImage {
        if cancelFlag.isCancelled {
            throw CancellationError()
        }

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

        if cancelFlag.isCancelled {
            throw CancellationError()
        }

        // 4. 加载 CoreML 模型（iOS 15 自动走稳定 CPU/BNNS 后端，杜绝 ANE 与 MPSCNN 挂死）
        guard let modelURL = Self.locateModelURL(for: model) else {
            throw Waifu2xServiceError.modelNotFound(model.modelBundleName)
        }
        let mlModel = try getOrLoadMLModel(at: modelURL)

        // 5. 准备可复用的 Float32 输入 MLMultiArray 池 [3, 156, 156]
        //    iOS 16+ 使用 MLArrayBatchProvider 4 块并发喂给 ANE/GPU；iOS 15 保持单块稳定路径，内存与带宽较 Double 减半
        let batchSize: Int
        if #available(iOS 16.0, *) {
            batchSize = min(4, totalTiles)
        } else {
            batchSize = 1
        }

        let inputShape: [NSNumber] = [3, NSNumber(value: inputTileSize), NSNumber(value: inputTileSize)]
        var inputArrays: [MLMultiArray] = []
        var inputStridesList: [TensorChannelStrides] = []
        var inputPtrs: [UnsafeMutablePointer<Float>] = []
        var providers: [Waifu2xMLFeatureProvider] = []
        inputArrays.reserveCapacity(batchSize)
        inputStridesList.reserveCapacity(batchSize)
        inputPtrs.reserveCapacity(batchSize)
        providers.reserveCapacity(batchSize)

        for _ in 0..<batchSize {
            let arr = try MLMultiArray(shape: inputShape, dataType: .float32)
            let strides = Self.extractChannelStrides(from: arr, tileSize: inputTileSize)
            let capacity = max(arr.count, strides.minRequiredCount)
            let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            inputArrays.append(arr)
            inputStridesList.append(strides)
            inputPtrs.append(ptr)
            providers.append(Waifu2xMLFeatureProvider(input: arr))
        }

        // 复用行级 vDSP 临时缓冲，避免在分块读回循环中反复分配堆内存
        var rowR = [Float](repeating: 0, count: outputTileSize)
        var rowG = [Float](repeating: 0, count: outputTileSize)
        var rowB = [Float](repeating: 0, count: outputTileSize)
        var byteR = [UInt8](repeating: 0, count: outputTileSize)
        var byteG = [UInt8](repeating: 0, count: outputTileSize)
        var byteB = [UInt8](repeating: 0, count: outputTileSize)

        let inv255: Float = 1.0 / 255.0

        // 6. 按批执行推理并填充目标缓冲区（每批前检查取消标志，翻页/切配置即时释放队列）
        var cursor = 0
        while cursor < totalTiles {
            if cancelFlag.isCancelled {
                throw CancellationError()
            }

            let currentBatchCount = min(batchSize, totalTiles - cursor)

            // 填充当前批次的全部输入分块（边界 Edge Clamping）
            for b in 0..<currentBatchCount {
                let rect = rects[cursor + b]
                let originX = Int(rect.origin.x)
                let originY = Int(rect.origin.y)
                let inStrides = inputStridesList[b]
                let inputPtr = inputPtrs[b]
                let gBase = inStrides.cStride
                let bBase = inStrides.cStride * 2

                for py in 0..<inputTileSize {
                    let sampleY = min(max(originY - shrinkSize + py, 0), height - 1)
                    let rowOffset = sampleY * width
                    let planeRow = py * inStrides.yStride

                    for px in 0..<inputTileSize {
                        let sampleX = min(max(originX - shrinkSize + px, 0), width - 1)
                        let pixelIdx = (rowOffset + sampleX) * 4

                        let offsetInPlane = planeRow + px * inStrides.xStride
                        inputPtr[offsetInPlane] = Float(srcPtr[pixelIdx]) * inv255
                        inputPtr[gBase + offsetInPlane] = Float(srcPtr[pixelIdx + 1]) * inv255
                        inputPtr[bBase + offsetInPlane] = Float(srcPtr[pixelIdx + 2]) * inv255
                    }
                }
            }

            // 单批推理放入 autoreleasepool，防止超长条漫数百个分块导致 CoreML 临时对象持续堆积
            try autoreleasepool {
                if currentBatchCount == 1 {
                    let prediction = try mlModel.prediction(from: providers[0])
                    guard let outputArray = prediction.featureValue(for: "conv7")?.multiArrayValue else {
                        throw Waifu2xServiceError.inferenceFailed("未找到输出层 conv7")
                    }
                    let rect = rects[cursor]
                    Self.writeOutputTile(
                        outputArray: outputArray,
                        outputTileSize: outputTileSize,
                        destOriginX: Int(rect.origin.x) * outScale,
                        destOriginY: Int(rect.origin.y) * outScale,
                        targetWidth: targetWidth,
                        targetHeight: targetHeight,
                        dstPixels: dstPtr,
                        rowR: &rowR,
                        rowG: &rowG,
                        rowB: &rowB,
                        byteR: &byteR,
                        byteG: &byteG,
                        byteB: &byteB
                    )
                } else {
                    let batchProvider = MLArrayBatchProvider(array: Array(providers[0..<currentBatchCount]))
                    let batchOutput = try mlModel.predictions(fromBatch: batchProvider)
                    guard batchOutput.count == currentBatchCount else {
                        throw Waifu2xServiceError.inferenceFailed("批量推理输出数量不匹配")
                    }
                    for b in 0..<currentBatchCount {
                        let prediction = batchOutput.features(at: b)
                        guard let outputArray = prediction.featureValue(for: "conv7")?.multiArrayValue else {
                            throw Waifu2xServiceError.inferenceFailed("未找到输出层 conv7")
                        }
                        let rect = rects[cursor + b]
                        Self.writeOutputTile(
                            outputArray: outputArray,
                            outputTileSize: outputTileSize,
                            destOriginX: Int(rect.origin.x) * outScale,
                            destOriginY: Int(rect.origin.y) * outScale,
                            targetWidth: targetWidth,
                            targetHeight: targetHeight,
                            dstPixels: dstPtr,
                            rowR: &rowR,
                            rowG: &rowG,
                            rowB: &rowB,
                            byteR: &byteR,
                            byteG: &byteG,
                            byteB: &byteB
                        )
                    }
                }
            }

            cursor += currentBatchCount
            let percent = Int(Double(cursor) / Double(totalTiles) * 100)
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

    private struct TensorChannelStrides {
        let cStride: Int
        let yStride: Int
        let xStride: Int
        let minRequiredCount: Int
    }

    /// 提取最后三维 [C, H, W] 的真实内存步长（兼容带行对齐 padding 的 MLMultiArray）
    private static func extractChannelStrides(from array: MLMultiArray, tileSize: Int) -> TensorChannelStrides {
        let rawStrides = array.strides.map { $0.intValue }
        let cStride: Int
        let yStride: Int
        let xStride: Int
        if rawStrides.count >= 3 {
            let n = rawStrides.count
            cStride = max(1, rawStrides[n - 3])
            yStride = max(1, rawStrides[n - 2])
            xStride = max(1, rawStrides[n - 1])
        } else {
            cStride = tileSize * tileSize
            yStride = tileSize
            xStride = 1
        }
        let maxIdx = 2 * cStride + (tileSize - 1) * yStride + (tileSize - 1) * xStride
        return TensorChannelStrides(
            cStride: cStride,
            yStride: yStride,
            xStride: xStride,
            minRequiredCount: maxIdx + 1
        )
    }

    @inline(__always)
    private static func clampToByte(_ value: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        let scaled = value * 255.0
        if scaled <= 0.0 { return 0 }
        if scaled >= 255.0 { return 255 }
        return UInt8(scaled)
    }

    /// vDSP 矢量化快路径：将 Float32 平面 RGB 批量缩放/钳位并转为 UInt8 写入目标 RGBA 位图
    private static func copyFloat32PlanesSIMD(
        _ ptr: UnsafePointer<Float>,
        strides: TensorChannelStrides,
        outputTileSize: Int,
        destOriginX: Int,
        destOriginY: Int,
        targetWidth: Int,
        targetHeight: Int,
        dstPixels: UnsafeMutablePointer<UInt8>,
        rowR: inout [Float],
        rowG: inout [Float],
        rowB: inout [Float],
        byteR: inout [UInt8],
        byteG: inout [UInt8],
        byteB: inout [UInt8]
    ) {
        let validXStart = max(0, -destOriginX)
        let validXEnd = min(outputTileSize, targetWidth - destOriginX)
        let validWidth = validXEnd - validXStart
        guard validWidth > 0 else { return }

        let validYStart = max(0, -destOriginY)
        let validYEnd = min(outputTileSize, targetHeight - destOriginY)
        guard validYStart < validYEnd else { return }

        let rPtr = ptr
        let gPtr = ptr.advanced(by: strides.cStride)
        let bPtr = ptr.advanced(by: strides.cStride * 2)
        let yStride = strides.yStride

        var scale255: Float = 255.0
        var low: Float = 0.0
        var high: Float = 255.0
        let count = vDSP_Length(validWidth)

        for sy in validYStart..<validYEnd {
            let srcRowOffset = sy * yStride + validXStart
            let rSrc = rPtr.advanced(by: srcRowOffset)
            let gSrc = gPtr.advanced(by: srcRowOffset)
            let bSrc = bPtr.advanced(by: srcRowOffset)

            rowR.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_vsmul(rSrc, 1, &scale255, base, 1, count)
                vDSP_vclip(base, 1, &low, &high, base, 1, count)
                vDSP_vfixu8(base, 1, &byteR, 1, count)
            }

            rowG.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_vsmul(gSrc, 1, &scale255, base, 1, count)
                vDSP_vclip(base, 1, &low, &high, base, 1, count)
                vDSP_vfixu8(base, 1, &byteG, 1, count)
            }

            rowB.withUnsafeMutableBufferPointer { buf in
                guard let base = buf.baseAddress else { return }
                vDSP_vsmul(bSrc, 1, &scale255, base, 1, count)
                vDSP_vclip(base, 1, &low, &high, base, 1, count)
                vDSP_vfixu8(base, 1, &byteB, 1, count)
            }

            let dy = destOriginY + sy
            var dstIdx = (dy * targetWidth + destOriginX + validXStart) * 4
            for x in 0..<validWidth {
                dstPixels[dstIdx]     = byteR[x]
                dstPixels[dstIdx + 1] = byteG[x]
                dstPixels[dstIdx + 2] = byteB[x]
                dstPixels[dstIdx + 3] = 255
                dstIdx += 4
            }
        }
    }

    /// 将平面 RGB 缓冲区的单个分块快速写入目标 RGBA 位图指针（严格按真实 strides 读取，防对齐错位与 NaN 崩溃）
    private static func copyChannelPlanes<T>(
        _ ptr: UnsafePointer<T>,
        strides: TensorChannelStrides,
        outputTileSize: Int,
        destOriginX: Int,
        destOriginY: Int,
        targetWidth: Int,
        targetHeight: Int,
        dstPixels: UnsafeMutablePointer<UInt8>,
        toDouble: (T) -> Double
    ) {
        let rPtr = ptr
        let gPtr = ptr.advanced(by: strides.cStride)
        let bPtr = ptr.advanced(by: strides.cStride * 2)
        let yStride = strides.yStride
        let xStride = strides.xStride

        for sy in 0..<outputTileSize {
            let dy = destOriginY + sy
            guard dy >= 0 && dy < targetHeight else { continue }
            let dstRow = dy * targetWidth
            let srcRow = sy * yStride

            for sx in 0..<outputTileSize {
                let dx = destOriginX + sx
                guard dx >= 0 && dx < targetWidth else { continue }

                let srcIdx = srcRow + sx * xStride
                let dstIdx = (dstRow + dx) * 4

                dstPixels[dstIdx]     = clampToByte(toDouble(rPtr[srcIdx]))
                dstPixels[dstIdx + 1] = clampToByte(toDouble(gPtr[srcIdx]))
                dstPixels[dstIdx + 2] = clampToByte(toDouble(bPtr[srcIdx]))
                dstPixels[dstIdx + 3] = 255
            }
        }
    }

    /// 安全读取 conv7 [3, 284, 284] 输出并直接写入目标像素指针（Float32 连续行启用 vDSP SIMD 加速，兼容 Double/Float16 与任意步长）
    private static func writeOutputTile(
        outputArray: MLMultiArray,
        outputTileSize: Int, // 284
        destOriginX: Int,
        destOriginY: Int,
        targetWidth: Int,
        targetHeight: Int,
        dstPixels: UnsafeMutablePointer<UInt8>,
        rowR: inout [Float],
        rowG: inout [Float],
        rowB: inout [Float],
        byteR: inout [UInt8],
        byteG: inout [UInt8],
        byteB: inout [UInt8]
    ) {
        let strides = extractChannelStrides(from: outputArray, tileSize: outputTileSize)
        let capacity = max(outputArray.count, strides.minRequiredCount)
        let dataType = outputArray.dataType

        if dataType == .float32 {
            let ptr = outputArray.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            if strides.xStride == 1 {
                copyFloat32PlanesSIMD(
                    ptr,
                    strides: strides,
                    outputTileSize: outputTileSize,
                    destOriginX: destOriginX,
                    destOriginY: destOriginY,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    dstPixels: dstPixels,
                    rowR: &rowR,
                    rowG: &rowG,
                    rowB: &rowB,
                    byteR: &byteR,
                    byteG: &byteG,
                    byteB: &byteB
                )
            } else {
                copyChannelPlanes(
                    ptr,
                    strides: strides,
                    outputTileSize: outputTileSize,
                    destOriginX: destOriginX,
                    destOriginY: destOriginY,
                    targetWidth: targetWidth,
                    targetHeight: targetHeight,
                    dstPixels: dstPixels
                ) { Double($0) }
            }
            return
        }

        if dataType == .double {
            let ptr = outputArray.dataPointer.bindMemory(to: Double.self, capacity: capacity)
            copyChannelPlanes(
                ptr,
                strides: strides,
                outputTileSize: outputTileSize,
                destOriginX: destOriginX,
                destOriginY: destOriginY,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                dstPixels: dstPixels
            ) { $0 }
            return
        }

        #if arch(arm64)
        // 0x10010 (65552) 为 MLMultiArrayDataType.float16.rawValue；该枚举 case 仅在 iOS 16+ 公开，直接按 rawValue 判断以兼容 iOS 15 编译
        if #available(iOS 14.0, *), dataType.rawValue == 0x10010 {
            let ptr = outputArray.dataPointer.bindMemory(to: Float16.self, capacity: capacity)
            copyChannelPlanes(
                ptr,
                strides: strides,
                outputTileSize: outputTileSize,
                destOriginX: destOriginX,
                destOriginY: destOriginY,
                targetWidth: targetWidth,
                targetHeight: targetHeight,
                dstPixels: dstPixels
            ) { Double($0) }
            return
        }
        #endif

        // 通用下标兜底（支持其他格式或非 arm64 平台）
        for sy in 0..<outputTileSize {
            let dy = destOriginY + sy
            guard dy >= 0 && dy < targetHeight else { continue }
            let dstRow = dy * targetWidth
            let srcRow = sy * strides.yStride

            for sx in 0..<outputTileSize {
                let dx = destOriginX + sx
                guard dx >= 0 && dx < targetWidth else { continue }

                let srcIdx = srcRow + sx * strides.xStride
                let dstIdx = (dstRow + dx) * 4

                dstPixels[dstIdx]     = clampToByte(outputArray[srcIdx].doubleValue)
                dstPixels[dstIdx + 1] = clampToByte(outputArray[strides.cStride + srcIdx].doubleValue)
                dstPixels[dstIdx + 2] = clampToByte(outputArray[strides.cStride * 2 + srcIdx].doubleValue)
                dstPixels[dstIdx + 3] = 255
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

        // 限制模型缓存上限，避免连续切换模型后常驻过多权重内存
        if mlModelCache.count >= 2 {
            mlModelCache.removeAll()
        }

        let primaryUnits: MLComputeUnits
        if #available(iOS 16.0, *) {
            primaryUnits = .all // iOS 16+ 优先 ANE（Apple Neural Engine）与 GPU
        } else {
            // iOS 15 下旧版 Espresso 的 ANE 与 MPSCNN GPU 后端对高版本预编译反卷积模型均存在挂死/死等风险，
            // 使用 Accelerate/BNNS 纯 CPU 后端可 100% 稳定完成推理且不卡死队列
            primaryUnits = .cpuOnly
        }

        let config = MLModelConfiguration()
        config.computeUnits = primaryUnits

        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            guard primaryUnits != .cpuOnly else {
                throw error
            }
            let fallbackConfig = MLModelConfiguration()
            fallbackConfig.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: fallbackConfig)
        }

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
