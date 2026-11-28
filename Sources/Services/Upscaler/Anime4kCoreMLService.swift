import Accelerate
import CoreGraphics
import CoreML
import Darwin
import Foundation
import UIKit

public enum Anime4kCoreMLServiceError: LocalizedError {
    case imageTooSmall(width: Int, height: Int)
    case outputTooLarge(width: Int, height: Int, scale: Int, maxOutputPixels: Int)
    case decodeFailed
    case memoryAllocationFailed
    case modelNotFound(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .imageTooSmall(w, h):
            return "图片尺寸过小 (\(w)×\(h))，Anime4K AI 要求最小边 ≥ 16px"
        case let .outputTooLarge(w, h, scale, maxOutputPixels):
            let outMP = String(format: "%.1f", Double(w * scale * h * scale) / 1_000_000.0)
            let limitMP = maxOutputPixels / 1_000_000
            return "\(scale)x 输出像素过大 (\(w * scale)×\(h * scale)，约 \(outMP)M)，超过默认 \(limitMP)M 上限已跳过"
        case .decodeFailed:
            return "位图预解码失败"
        case .memoryAllocationFailed:
            return "设备可用内存不足，无法分配超分位图缓冲区"
        case let .modelNotFound(name):
            return "未找到 Anime4K CoreML 模型: \(name)"
        case let .inferenceFailed(msg):
            return "Anime4K CoreML 推理失败: \(msg)"
        }
    }
}

/// 线程安全取消令牌（用于及时中止排队中或分块循环中的过期推理任务）
private final class Anime4kCoreMLCancellationFlag: @unchecked Sendable {
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

/// Anime4K CoreML 神经网络超分服务（基于 Apple Neural Engine / CoreML MLProgram FP16）
/// 模型规格：
/// - 输入：`input_MAIN` Float32 `[B, 3, 128, 128]`（动态 Batch，RGB 值域 [0, 1]）
/// - 输出：`Identity` Float32 `[B, 3, 128*S, 128*S]`（S ∈ {1, 2, 3, 4}）
/// - 无缝裁边：采用 `margin = 8`、`validBlock = 112` 重叠采样，推理后丢弃四周 `8*S` 边缘像素，彻底消除 same-padding 拼缝
public final class Anime4kCoreMLService: @unchecked Sendable {
    public static let shared = Anime4kCoreMLService()

    public static let minDimension: Int = 16
    /// 默认最大允许输出总像素（48M 输出像素 ≈ 192MB RGBA8）
    public static let maxOutputPixelCount: Int = ImageUpscalerConfig.maxOutputPixelCountThreshold

    private static let inputTileSize: Int = 128
    private static let overlapMargin: Int = 8
    private static let validBlockSize: Int = inputTileSize - overlapMargin * 2 // 112

    /// 严格串行调度队列，防止多页并发推理导致内存挤爆
    private let serialQueue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.anime4kcoreml.serial", qos: .userInitiated)

    /// 缓存已编译加载的 MLModel 实例（最多常驻 2 个）
    private var mlModelCache: [String: MLModel] = [:]
    private let modelCacheLock = NSLock()

    private init() {}

    /// 清理已缓存的模型实例以释放内存
    public func clearModelCache() {
        modelCacheLock.lock()
        mlModelCache.removeAll()
        modelCacheLock.unlock()
    }

    /// 执行 Anime4K CoreML 神经网络超分（支持 1x 修复 / 2x / 3x / 4x / GAN）
    public func enhance(
        image: UIImage,
        model: Anime4kCoreMLModel = .perset2x_a_a_fast,
        bypassSizeLimit: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UIImage {
        try Task.checkCancellation()
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            throw CancellationError()
        }

        let scale = model.scaleFactor
        let (width, height) = Self.pixelDimensions(of: image)
        guard width >= Self.minDimension && height >= Self.minDimension else {
            throw Anime4kCoreMLServiceError.imageTooSmall(width: width, height: height)
        }
        let workingOverhead = scale >= 4 ? 140 * 1024 * 1024 : 96 * 1024 * 1024
        _ = try UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
            width: width,
            height: height,
            scale: scale,
            bypassSizeLimit: bypassSizeLimit,
            workingOverheadBytes: workingOverhead
        )

        // 仅当方向非 .up 或缺失 cgImage 时做规范化预解码
        let preparedImage: UIImage
        if image.cgImage != nil && image.imageOrientation == .up {
            preparedImage = image
        } else {
            guard let decoded = Waifu2xService.forceDecodeToPixelImage(image) else {
                throw Anime4kCoreMLServiceError.decodeFailed
            }
            preparedImage = decoded
        }

        try Task.checkCancellation()

        // 跨引擎全局互斥执行：确保与 Anime4K Metal / Waifu2x / 预览页绝不并发争抢显存与 ANE
        let acquiredGlobal = await UpscalerRuntimeGuard.shared.acquireExclusiveSlot()
        guard acquiredGlobal else {
            throw CancellationError()
        }
        defer { UpscalerRuntimeGuard.shared.releaseExclusiveSlot() }

        let cancelFlag = Anime4kCoreMLCancellationFlag()
        let bgToken = UpscalerRuntimeGuard.shared.registerActiveCancellation {
            cancelFlag.cancel()
        }
        defer {
            UpscalerRuntimeGuard.shared.unregisterActiveCancellation(bgToken)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.serialQueue.async {
                    if cancelFlag.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    autoreleasepool {
                        do {
                            let result = try self.runTiledInference(
                                image: preparedImage,
                                model: model,
                                bypassSizeLimit: bypassSizeLimit,
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

    // MARK: - CoreML 原生固定 Batch 分块推理

    private func runTiledInference(
        image: UIImage,
        model: Anime4kCoreMLModel,
        bypassSizeLimit: Bool,
        cancelFlag: Anime4kCoreMLCancellationFlag,
        progress: (@Sendable (String) -> Void)?
    ) throws -> UIImage {
        if cancelFlag.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
            throw CancellationError()
        }

        guard let cgImage = image.cgImage else {
            throw Anime4kCoreMLServiceError.decodeFailed
        }

        let width = cgImage.width
        let height = cgImage.height
        let scale = model.scaleFactor
        let workingOverhead = scale >= 4 ? 140 * 1024 * 1024 : 96 * 1024 * 1024
        let validated = try UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
            width: width,
            height: height,
            scale: scale,
            bypassSizeLimit: bypassSizeLimit,
            workingOverheadBytes: workingOverhead
        )
        let targetWidth = validated.targetWidth
        let targetHeight = validated.targetHeight
        let targetBytes = validated.targetBytes

        // 1. 提取原图 8-bit sRGB RGBA 像素缓冲
        let srcBytes = width * height * 4
        guard srcBytes > 0, let srcRawPtr = calloc(srcBytes, 1) else {
            throw Anime4kCoreMLServiceError.memoryAllocationFailed
        }
        var srcFreed = false
        defer {
            if !srcFreed {
                free(srcRawPtr)
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let srcBitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: srcRawPtr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: srcBitmapInfo
        ) else {
            throw Anime4kCoreMLServiceError.decodeFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        let srcPtr = srcRawPtr.bindMemory(to: UInt8.self, capacity: srcBytes)

        // 2. 分配目标大图 RGBA8 缓冲（零拷贝移交 CGDataProvider）
        guard targetBytes > 0, let dstRawPtr = malloc(targetBytes) else {
            throw Anime4kCoreMLServiceError.memoryAllocationFailed
        }
        memset(dstRawPtr, 255, targetBytes)
        var dstOwnershipTransferred = false
        defer {
            if !dstOwnershipTransferred {
                free(dstRawPtr)
            }
        }
        let dstPtr = dstRawPtr.bindMemory(to: UInt8.self, capacity: targetBytes)

        // 3. 按 112px 有效步长切分覆盖全图的网格（四周各自扩展 8px 形成 128×128 输入块）
        let inputSize = Self.inputTileSize
        let margin = Self.overlapMargin
        let blockSize = Self.validBlockSize
        let fullOutTileSize = inputSize * scale
        let outMargin = margin * scale
        let validOutBlockSize = blockSize * scale

        let rects = Self.computeTileRects(width: width, height: height, step: blockSize)
        let totalTiles = rects.count
        guard totalTiles > 0 else {
            throw Anime4kCoreMLServiceError.inferenceFailed("分块切片失败")
        }

        if cancelFlag.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
            throw CancellationError()
        }

        // 4. 加载 CoreML MLProgram 模型
        guard let modelURL = Self.locateModelURL(for: model) else {
            throw Anime4kCoreMLServiceError.modelNotFound(model.modelBundleName)
        }
        let mlModel = try getOrLoadMLModel(at: modelURL)

        // 5. 准备固定 4D Batch 输入张量 [B, 3, 128, 128]
        //    4x 模型内部特征图极大，固定 batch=1 控制 ANE 峰值显存；3x 固定 batch=2；1x/2x 固定 batch=4；
        //    尾批不足时直接复用同一固定 shape（空槽拷贝尾块并在输出时丢弃），彻底消除 ANE 动态 shape 重编译！
        let maxBatchSize: Int
        if #available(iOS 16.0, *) {
            if scale >= 4 {
                maxBatchSize = 1
            } else if scale == 3 {
                maxBatchSize = min(2, totalTiles)
            } else {
                maxBatchSize = min(4, totalTiles)
            }
        } else {
            maxBatchSize = 1
        }

        let primaryInputArray = try MLMultiArray(
            shape: [NSNumber(value: maxBatchSize), 3, NSNumber(value: inputSize), NSNumber(value: inputSize)],
            dataType: .float32
        )
        let primaryStrides = Self.extract4DStrides(from: primaryInputArray, batch: maxBatchSize, tileSize: inputSize)
        let primaryProvider = Anime4kCoreMLFeatureProvider(input: primaryInputArray)
        let inputCapacity = max(primaryInputArray.count, primaryStrides.minRequiredCount)
        let inputPtr = primaryInputArray.dataPointer.bindMemory(to: Float.self, capacity: inputCapacity)

        // 复用行级 vDSP 临时缓冲
        var rowR = [Float](repeating: 0, count: validOutBlockSize)
        var rowG = [Float](repeating: 0, count: validOutBlockSize)
        var rowB = [Float](repeating: 0, count: validOutBlockSize)
        var byteR = [UInt8](repeating: 0, count: validOutBlockSize)
        var byteG = [UInt8](repeating: 0, count: validOutBlockSize)
        var byteB = [UInt8](repeating: 0, count: validOutBlockSize)

        let inv255: Float = 1.0 / 255.0

        // 6. 逐批推理并裁去四周 overlap 边距拼回目标大图（固定 shape 零重编译）
        var cursor = 0
        while cursor < totalTiles {
            if cancelFlag.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
                throw CancellationError()
            }

            let batchCount = min(maxBatchSize, totalTiles - cursor)

            try autoreleasepool {
                // 填充本批所有分块至固定 [maxBatchSize, 3, 128, 128]（尾批多余空槽复用尾块，避免数值异常且不改变张量形状）
                for b in 0..<maxBatchSize {
                    let tileIndex = cursor + min(b, batchCount - 1)
                    let rect = rects[tileIndex]
                    let originX = Int(rect.origin.x)
                    let originY = Int(rect.origin.y)
                    let batchBase = b * primaryStrides.bStride
                    let rBase = batchBase
                    let gBase = batchBase + primaryStrides.cStride
                    let bBase = batchBase + primaryStrides.cStride * 2

                    for py in 0..<inputSize {
                        let sampleY = min(max(originY - margin + py, 0), height - 1)
                        let rowOffset = sampleY * width
                        let planeRow = py * primaryStrides.yStride

                        for px in 0..<inputSize {
                            let sampleX = min(max(originX - margin + px, 0), width - 1)
                            let pixelIdx = (rowOffset + sampleX) * 4
                            let offset = planeRow + px * primaryStrides.xStride

                            inputPtr[rBase + offset] = Float(srcPtr[pixelIdx]) * inv255
                            inputPtr[gBase + offset] = Float(srcPtr[pixelIdx + 1]) * inv255
                            inputPtr[bBase + offset] = Float(srcPtr[pixelIdx + 2]) * inv255
                        }
                    }
                }

                if cancelFlag.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
                    throw CancellationError()
                }

                // 执行 CoreML 推理
                let prediction = try mlModel.prediction(from: primaryProvider)
                guard let outputArray = prediction.featureValue(for: "Identity")?.multiArrayValue else {
                    throw Anime4kCoreMLServiceError.inferenceFailed("未找到输出层 Identity")
                }

                let outStrides = Self.extract4DStrides(from: outputArray, batch: maxBatchSize, tileSize: fullOutTileSize)

                for b in 0..<batchCount {
                    let rect = rects[cursor + b]
                    Self.writeCroppedOutputTile(
                        outputArray: outputArray,
                        batchIndex: b,
                        strides: outStrides,
                        outMargin: outMargin,
                        validOutBlockSize: validOutBlockSize,
                        destOriginX: Int(rect.origin.x) * scale,
                        destOriginY: Int(rect.origin.y) * scale,
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

            cursor += batchCount
            let percent = Int(Double(cursor) / Double(totalTiles) * 100)
            progress?("\(percent)%")
        }

        // 提前释放原图缓冲
        free(srcRawPtr)
        srcFreed = true

        // 7. 零拷贝移交目标位图所有权
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: dstRawPtr,
            size: targetBytes,
            releaseData: { _, data, _ in
                free(UnsafeMutableRawPointer(mutating: data))
            }
        ) else {
            throw Anime4kCoreMLServiceError.inferenceFailed("无法创建位图数据提供者")
        }
        dstOwnershipTransferred = true

        let outBitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
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
            throw Anime4kCoreMLServiceError.inferenceFailed("拼接超分大图失败")
        }

        return UIImage(cgImage: finalCG, scale: 1.0, orientation: .up)
    }

    // MARK: - 切片网格与张量读写

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
        rects.reserveCapacity(xStarts.count * yStarts.count)
        for y in yStarts {
            for x in xStarts {
                rects.append(CGRect(x: x, y: y, width: step, height: step))
            }
        }
        return rects
    }

    private struct Tensor4DStrides {
        let bStride: Int
        let cStride: Int
        let yStride: Int
        let xStride: Int
        let minRequiredCount: Int
    }

    private static func extract4DStrides(from array: MLMultiArray, batch: Int, tileSize: Int) -> Tensor4DStrides {
        let raw = array.strides.map { $0.intValue }
        let bStride: Int
        let cStride: Int
        let yStride: Int
        let xStride: Int
        if raw.count >= 4 {
            let n = raw.count
            bStride = max(1, raw[n - 4])
            cStride = max(1, raw[n - 3])
            yStride = max(1, raw[n - 2])
            xStride = max(1, raw[n - 1])
        } else if raw.count == 3 {
            cStride = max(1, raw[0])
            yStride = max(1, raw[1])
            xStride = max(1, raw[2])
            bStride = max(1, cStride * 3)
        } else {
            xStride = 1
            yStride = tileSize
            cStride = tileSize * tileSize
            bStride = cStride * 3
        }
        let maxIdx = max(0, batch - 1) * bStride + 2 * cStride + (tileSize - 1) * yStride + (tileSize - 1) * xStride
        return Tensor4DStrides(
            bStride: bStride,
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

    private static func writeCroppedOutputTile(
        outputArray: MLMultiArray,
        batchIndex: Int,
        strides: Tensor4DStrides,
        outMargin: Int,
        validOutBlockSize: Int,
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
        let validXEnd = min(validOutBlockSize, targetWidth - destOriginX)
        let validWidth = validXEnd - validXStart
        guard validWidth > 0 else { return }

        let validYStart = max(0, -destOriginY)
        let validYEnd = min(validOutBlockSize, targetHeight - destOriginY)
        guard validYStart < validYEnd else { return }

        let capacity = max(outputArray.count, strides.minRequiredCount)
        let batchOffset = batchIndex * strides.bStride
        let dataType = outputArray.dataType

        if dataType == .float32 {
            let basePtr = outputArray.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            let rPtr = basePtr.advanced(by: batchOffset)
            let gPtr = basePtr.advanced(by: batchOffset + strides.cStride)
            let bPtr = basePtr.advanced(by: batchOffset + strides.cStride * 2)

            if strides.xStride == 1 {
                var scale255: Float = 255.0
                var low: Float = 0.0
                var high: Float = 255.0
                let count = vDSP_Length(validWidth)

                for sy in validYStart..<validYEnd {
                    let srcRowOffset = (outMargin + sy) * strides.yStride + (outMargin + validXStart)
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
                return
            }

            // 非连续 xStride 安全路径
            for sy in validYStart..<validYEnd {
                let dy = destOriginY + sy
                let srcRow = (outMargin + sy) * strides.yStride
                let dstRow = dy * targetWidth
                for sx in validXStart..<validXEnd {
                    let srcIdx = srcRow + (outMargin + sx) * strides.xStride
                    let dstIdx = (dstRow + destOriginX + sx) * 4
                    dstPixels[dstIdx]     = clampToByte(Double(rPtr[srcIdx]))
                    dstPixels[dstIdx + 1] = clampToByte(Double(gPtr[srcIdx]))
                    dstPixels[dstIdx + 2] = clampToByte(Double(bPtr[srcIdx]))
                    dstPixels[dstIdx + 3] = 255
                }
            }
            return
        }

        #if arch(arm64)
        if #available(iOS 14.0, *), dataType.rawValue == 0x10010 {
            let basePtr = outputArray.dataPointer.bindMemory(to: Float16.self, capacity: capacity)
            let rPtr = basePtr.advanced(by: batchOffset)
            let gPtr = basePtr.advanced(by: batchOffset + strides.cStride)
            let bPtr = basePtr.advanced(by: batchOffset + strides.cStride * 2)
            for sy in validYStart..<validYEnd {
                let dy = destOriginY + sy
                let srcRow = (outMargin + sy) * strides.yStride
                let dstRow = dy * targetWidth
                for sx in validXStart..<validXEnd {
                    let srcIdx = srcRow + (outMargin + sx) * strides.xStride
                    let dstIdx = (dstRow + destOriginX + sx) * 4
                    dstPixels[dstIdx]     = clampToByte(Double(rPtr[srcIdx]))
                    dstPixels[dstIdx + 1] = clampToByte(Double(gPtr[srcIdx]))
                    dstPixels[dstIdx + 2] = clampToByte(Double(bPtr[srcIdx]))
                    dstPixels[dstIdx + 3] = 255
                }
            }
            return
        }
        #endif

        // 通用兜底路径（Double 或其他类型）
        for sy in validYStart..<validYEnd {
            let dy = destOriginY + sy
            let srcRow = batchOffset + (outMargin + sy) * strides.yStride
            let dstRow = dy * targetWidth
            for sx in validXStart..<validXEnd {
                let srcIdx = srcRow + (outMargin + sx) * strides.xStride
                let dstIdx = (dstRow + destOriginX + sx) * 4
                dstPixels[dstIdx]     = clampToByte(outputArray[srcIdx].doubleValue)
                dstPixels[dstIdx + 1] = clampToByte(outputArray[srcIdx + strides.cStride].doubleValue)
                dstPixels[dstIdx + 2] = clampToByte(outputArray[srcIdx + strides.cStride * 2].doubleValue)
                dstPixels[dstIdx + 3] = 255
            }
        }
    }

    // MARK: - 模型定位与缓存

    private func getOrLoadMLModel(at url: URL) throws -> MLModel {
        modelCacheLock.lock()
        defer { modelCacheLock.unlock() }

        let key = url.lastPathComponent
        if let cached = mlModelCache[key] {
            return cached
        }

        if mlModelCache.count >= 1 {
            mlModelCache.removeAll()
        }

        let primaryUnits: MLComputeUnits
        if #available(iOS 16.0, *) {
            primaryUnits = .all
        } else {
            // MLProgram FP16 模型在 iOS 15 优先走 GPU/CPU，若不支持自动降级 .cpuOnly
            primaryUnits = .cpuAndGPU
        }

        let config = MLModelConfiguration()
        config.computeUnits = primaryUnits

        let model: MLModel
        do {
            model = try MLModel(contentsOf: url, configuration: config)
        } catch {
            let fallbackConfig = MLModelConfiguration()
            fallbackConfig.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: fallbackConfig)
        }

        mlModelCache[key] = model
        return model
    }

    private static func locateModelURL(for model: Anime4kCoreMLModel) -> URL? {
        let name = model.rawValue
        // 1. 在 Resources/Anime4K_CoreML 目录下查找
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Anime4K_CoreML") {
            return url
        }
        // 2. 在主工程 Bundle 根目录查找
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        // 3. 在 bundleURL 相对路径中查找
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Anime4K_CoreML/\(name).mlmodelc"),
            Bundle.main.bundleURL.appendingPathComponent("Waifu2x_Anime4kModels.bundle/\(name).mlmodelc"),
            Bundle.main.bundleURL.appendingPathComponent("\(name).mlmodelc"),
        ]
        for url in candidates {
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

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
}

// MARK: - CoreML 特性提供者

private final class Anime4kCoreMLFeatureProvider: MLFeatureProvider {
    let input: MLMultiArray

    init(input: MLMultiArray) {
        self.input = input
    }

    var featureNames: Set<String> {
        ["input_MAIN"]
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "input_MAIN" {
            return MLFeatureValue(multiArray: input)
        }
        return nil
    }
}
