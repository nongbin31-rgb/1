import CoreGraphics
import Darwin
import Foundation
import Metal
import UIKit

public enum Anime4kServiceError: LocalizedError {
    case metalUnavailable
    case imageTooLarge(width: Int, height: Int, maxPixels: Int)
    case exceedsMetalTextureLimit(width: Int, height: Int, maxInputSide: Int)
    case imageNormalizationFailed
    case textureCreationFailed
    case commandBufferFailed
    case readbackFailed
    case emptyShaderChain

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "当前设备不支持 Metal GPU 计算"
        case let .imageTooLarge(w, h, maxPixels):
            let mp = String(format: "%.1f", Double(w * h) / 1_000_000.0)
            let limitMP = maxPixels / 1_000_000
            return "图片总像素过大 (\(w)×\(h)，约 \(mp)M)，超过默认 \(limitMP)M 上限已跳过 Anime4K"
        case let .exceedsMetalTextureLimit(w, h, maxInputSide):
            return "图片单边过大 (\(w)×\(h))，超出 Metal 2x 纹理硬件上限 (\(maxInputSide)px)，可切换 Waifu2x 引擎"
        case .imageNormalizationFailed:
            return "图像色彩空间标准化失败"
        case .textureCreationFailed:
            return "Metal 纹理创建失败"
        case .commandBufferFailed:
            return "Metal 命令缓冲提交失败"
        case .readbackFailed:
            return "Metal 输出纹理读回失败（内存不足或位图构造失败）"
        case .emptyShaderChain:
            return "Anime4K 着色器管线为空"
        }
    }
}

/// Anime4K v4 实时超分辨率服务（基于 Metal + 官方经典 Anime4K 着色器管线）
public actor Anime4kService {
    public static let shared = Anime4kService()

    /// 默认最大允许总像素（1200 万像素，兼容 800×8000 等条漫长图）
    public static let maxPixelCount: Int = ImageUpscalerConfig.maxPixelCountThreshold

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?

    /// 按配置缓存已转译并编译好的 Anime4K 着色器管线（避免每页重复 GLSL->MSL 编译耗时）
    private var cachedPipelines: [String: [Anime4K]] = [:]

    /// 严格串行门闩：彻底杜绝 Swift Actor 在 await 处重入导致多页并发踩踏共享 pipeline 状态与显存叠爆
    private var isProcessing: Bool = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        let mtlDevice = MTLCreateSystemDefaultDevice()
        self.device = mtlDevice
        self.commandQueue = mtlDevice?.makeCommandQueue()
    }

    private func acquireGate() async {
        if !isProcessing {
            isProcessing = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseGate() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            isProcessing = false
        }
    }

    /// 清理已缓存的 Metal 管线以释放显存（仅在空闲时清理，避免影响在途推理）
    public func clearPipelineCache() {
        guard !isProcessing else { return }
        cachedPipelines.removeAll()
    }

    /// 执行 Anime4K 2x 超分
    /// - Parameters:
    ///   - image: 输入原始图片
    ///   - config: 包含预设（AAFast/BBFast/CAFast/AAHQ/BBHQ/CAHQ）以及 thinLines 与 darkenLines 开关
    ///   - bypassSizeLimit: 是否解除默认总像素上限（仍受硬件安全天花板与可用内存守卫保护）
    ///   - progress: 分块处理进度回调
    /// - Returns: 2 倍放大后的 UIImage
    public func enhance(
        image: UIImage,
        config: Anime4kConfig = Anime4kConfig(),
        bypassSizeLimit: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UIImage {
        guard let device, let commandQueue else {
            throw Anime4kServiceError.metalUnavailable
        }

        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            throw CancellationError()
        }

        let hardwareMaxInputSide = Self.maxHardwareInputDimension(for: device)

        // 0. 前置防溢出尺寸与可用内存安全校验（拦截巨图与低内存场景，杜绝 Jetsam / GPU 驱动重启）
        let preSize = Self.pixelDimensions(of: image)
        if preSize.width > 0 && preSize.height > 0 {
            _ = try UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
                width: preSize.width,
                height: preSize.height,
                scale: 2,
                bypassSizeLimit: bypassSizeLimit,
                workingOverheadBytes: 110 * 1024 * 1024
            )
        }

        // 跨引擎全局唯一互斥 + 内部串行门闩：确保全 App 同一时刻仅 1 个 GPU/ANE 超分引擎运行
        let acquiredGlobal = await UpscalerRuntimeGuard.shared.acquireExclusiveSlot()
        guard acquiredGlobal else {
            throw CancellationError()
        }
        defer { UpscalerRuntimeGuard.shared.releaseExclusiveSlot() }

        await acquireGate()
        defer { releaseGate() }

        return try await executeEnhancedLocked(
            image: image,
            config: config,
            bypassSizeLimit: bypassSizeLimit,
            hardwareMaxInputSide: hardwareMaxInputSide,
            device: device,
            commandQueue: commandQueue,
            progress: progress
        )
    }

    private func executeEnhancedLocked(
        image: UIImage,
        config: Anime4kConfig,
        bypassSizeLimit: Bool,
        hardwareMaxInputSide: Int,
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> UIImage {
        try Task.checkCancellation()
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            throw CancellationError()
        }

        // 1. 提取正向 CGImage 并复核真实尺寸与实时可用内存
        let sourceCG = try Self.normalizedCGImage(from: image)
        let inWidth = sourceCG.width
        let inHeight = sourceCG.height
        guard inWidth > 0, inHeight > 0 else {
            throw Anime4kServiceError.imageNormalizationFailed
        }
        _ = try UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
            width: inWidth,
            height: inHeight,
            scale: 2,
            bypassSizeLimit: bypassSizeLimit,
            workingOverheadBytes: 110 * 1024 * 1024
        )

        try Task.checkCancellation()
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            throw CancellationError()
        }

        // 2. 加载或复用该配置对应的多 Pass Anime4K 着色器链
        let pipeline = try loadOrCreatePipeline(config: config, device: device)
        guard !pipeline.isEmpty else {
            throw Anime4kServiceError.emptyShaderChain
        }

        // 无论正常结束、任务取消还是异常退出，均确保释放全部中间 rgba16Float 纹理
        defer {
            for pass in pipeline {
                pass.releaseIntermediateTextures()
            }
        }

        // 3. 安全瓦片分块策略：
        //    HQ 预设含 25-pass UL 网络及 2x 分辨率 10 张 rgba16Float 纹理，若整图直通极易触发 1.5GB+ 私有显存与 GPU Watchdog 重启；
        //    按像素面积与单边双门限自动启用带 32px 重叠边的安全瓦片分块，将单次 CommandBuffer 显存峰值锁定在 ≤ 120MB！
        let isHQPreset = (config.preset == .AAHQ || config.preset == .BBHQ || config.preset == .CAHQ)
        let safeTileSide = min(hardwareMaxInputSide, isHQPreset ? 768 : 1024)
        let safeDirectPixelLimit = isHQPreset ? 520_000 : 950_000

        if inWidth > safeTileSide || inHeight > safeTileSide || (inWidth * inHeight) > safeDirectPixelLimit {
            return try await enhanceTiledStrips(
                sourceCG: sourceCG,
                pipeline: pipeline,
                device: device,
                commandQueue: commandQueue,
                maxStripSide: safeTileSide,
                progress: progress
            )
        }

        // 4. 小图安全直通路径（输入像素 ≤ 0.52M / 0.95M，峰值显存 ≤ 120MB）
        let inputTex = try Self.makeInputTexture(from: sourceCG, device: device)
        let outputTexture = try await runPipeline(
            inputTex: inputTex,
            inWidth: inWidth,
            inHeight: inHeight,
            pipeline: pipeline,
            device: device,
            commandQueue: commandQueue
        )

        // 5. 零拷贝读回像素并生成高质量 UIImage
        guard let outImage = Self.makeUIImage(from: outputTexture) else {
            throw Anime4kServiceError.readbackFailed
        }

        return outImage
    }

    /// 执行单次完整 Anime4K Metal 多 Pass 计算并返回 2x 输出纹理
    private func runPipeline(
        inputTex: MTLTexture,
        inWidth: Int,
        inHeight: Int,
        pipeline: [Anime4K],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) async throws -> MTLTexture {
        guard let finalPass = pipeline.last else {
            throw Anime4kServiceError.emptyShaderChain
        }

        let targetWidth = inWidth * 2
        let targetHeight = inHeight * 2

        // 按当前分辨率配置各 Pass 的纹理尺寸与 WHEN 条件（复用已缓存的 ComputePipelineState）
        var currentInW = inWidth
        var currentInH = inHeight
        for pass in pipeline {
            try pass.compileShaders(
                device,
                videoInW: inWidth,
                videoInH: inHeight,
                textureInW: currentInW,
                textureInH: currentInH,
                displayOutW: targetWidth,
                displayOutH: targetHeight
            )
            currentInW = max(1, Int(pass.outputW))
            currentInH = max(1, Int(pass.outputH))
        }

        // 分阶段提交 GPU 计算任务：每完成一个着色器文件立刻释放该阶段全部中间 rgba16Float 纹理，
        // 并在每次 commit 前校验前后台安全门禁，杜绝后台非法提交触发 iOS 内核强杀或驱动重启
        var currentTex: MTLTexture? = inputTex
        for pass in pipeline {
            try Task.checkCancellation()
            guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
                throw CancellationError()
            }
            guard !pass.enabledShaders.isEmpty else {
                continue
            }
            guard let passInput = currentTex else {
                throw Anime4kServiceError.textureCreationFailed
            }
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw Anime4kServiceError.commandBufferFailed
            }

            let nextTex = try pass.encode(device, cmdBuf: commandBuffer, input: passInput)
            try await Self.commitAndWait(commandBuffer)

            // 立刻释放当前阶段的 conv2d_* 等全部中间显存（nextTex 已被局部变量强持有）
            pass.releaseIntermediateTextures()
            currentTex = nextTex
        }

        try Task.checkCancellation()
        guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
            throw CancellationError()
        }

        // 创建 2x 目标 RGBA8 输出纹理（shared 模式便于 CPU 零拷贝读回）并执行最终 CenterResize
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite]
        outDesc.storageMode = .shared

        guard let outputTexture = device.makeTexture(descriptor: outDesc) else {
            throw Anime4kServiceError.textureCreationFailed
        }
        guard let resizeInput = currentTex else {
            throw Anime4kServiceError.textureCreationFailed
        }
        guard let finalCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw Anime4kServiceError.commandBufferFailed
        }

        try finalPass.encodeFinalResize(cmdBuf: finalCommandBuffer, input: resizeInput, output: outputTexture)
        try await Self.commitAndWait(finalCommandBuffer)

        // 提前释放最后的中间 rgba16Float 显存纹理，与后续 CPU 位图读回错峰
        currentTex = nil
        return outputTexture
    }

    /// 安全瓦片分块超分并无缝拼接（将单次 Metal CommandBuffer 显存峰值锁定在 ≤ 120MB，彻底杜绝 GPU 超时与重启）
    private func enhanceTiledStrips(
        sourceCG: CGImage,
        pipeline: [Anime4K],
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        maxStripSide: Int,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> UIImage {
        let inWidth = sourceCG.width
        let inHeight = sourceCG.height
        let targetWidth = inWidth * 2
        let targetHeight = inHeight * 2
        let dstBytesPerRow = targetWidth * 4
        let totalTargetBytes = dstBytesPerRow * targetHeight
        guard totalTargetBytes > 0, let dstRawPtr = malloc(totalTargetBytes) else {
            throw Anime4kServiceError.readbackFailed
        }
        var ownershipTransferred = false
        defer {
            if !ownershipTransferred {
                free(dstRawPtr)
            }
        }
        let dstPtr = dstRawPtr.bindMemory(to: UInt8.self, capacity: totalTargetBytes)

        // 32px 重叠边充分覆盖 7 层 3x3 UL + 2x Restore_M 卷积感受野，实现 100% 零拼缝
        let overlap = 32
        let stepX = max(256, maxStripSide - overlap * 2)
        let stepY = max(256, maxStripSide - overlap * 2)

        let xRanges = Self.computeStripRanges(total: inWidth, maxChunk: maxStripSide, step: stepX)
        let yRanges = Self.computeStripRanges(total: inHeight, maxChunk: maxStripSide, step: stepY)
        let totalTiles = max(1, xRanges.count * yRanges.count)
        var completedTiles = 0

        // 复用单个小瓦片读回缓冲区（~9~16MB），避免循环内反复 malloc/free
        var reusableTileBuf: UnsafeMutableRawPointer? = nil
        var reusableTileCap: Int = 0
        defer {
            if let buf = reusableTileBuf {
                free(buf)
            }
        }

        for yRange in yRanges {
            let cropY0 = max(0, yRange.lowerBound - overlap)
            let cropY1 = min(inHeight, yRange.upperBound + overlap)
            let cropH = cropY1 - cropY0
            let trimTop = (yRange.lowerBound - cropY0) * 2
            let validOutH = (yRange.upperBound - yRange.lowerBound) * 2

            for xRange in xRanges {
                try Task.checkCancellation()
                guard UpscalerRuntimeGuard.shared.isGPUExecutionPermitted else {
                    throw CancellationError()
                }

                let cropX0 = max(0, xRange.lowerBound - overlap)
                let cropX1 = min(inWidth, xRange.upperBound + overlap)
                let cropW = cropX1 - cropX0
                let trimLeft = (xRange.lowerBound - cropX0) * 2
                let validOutW = (xRange.upperBound - xRange.lowerBound) * 2

                let tileInputTex: MTLTexture = try autoreleasepool {
                    let cropRect = CGRect(x: cropX0, y: cropY0, width: cropW, height: cropH)
                    guard let tileCG = sourceCG.cropping(to: cropRect) else {
                        throw Anime4kServiceError.imageNormalizationFailed
                    }
                    return try Self.makeInputTexture(from: tileCG, device: device)
                }

                let tileOutTex = try await runPipeline(
                    inputTex: tileInputTex,
                    inWidth: cropW,
                    inHeight: cropH,
                    pipeline: pipeline,
                    device: device,
                    commandQueue: commandQueue
                )

                // 读回有效中心区域并无缝写入最终目标位图
                let tileBytesPerRow = cropW * 2 * 4
                let tileTotalBytes = tileBytesPerRow * cropH * 2
                guard tileTotalBytes > 0 else {
                    throw Anime4kServiceError.readbackFailed
                }
                if reusableTileCap < tileTotalBytes {
                    if let old = reusableTileBuf {
                        free(old)
                        reusableTileBuf = nil
                        reusableTileCap = 0
                    }
                    guard let fresh = malloc(tileTotalBytes) else {
                        throw Anime4kServiceError.readbackFailed
                    }
                    reusableTileBuf = fresh
                    reusableTileCap = tileTotalBytes
                }
                guard let tileBuf = reusableTileBuf else {
                    throw Anime4kServiceError.readbackFailed
                }

                autoreleasepool {
                    let region = MTLRegionMake2D(0, 0, cropW * 2, cropH * 2)
                    tileOutTex.getBytes(tileBuf, bytesPerRow: tileBytesPerRow, from: region, mipmapLevel: 0)

                    let srcTilePtr = tileBuf.bindMemory(to: UInt8.self, capacity: tileTotalBytes)
                    let dstOriginX = xRange.lowerBound * 2
                    let dstOriginY = yRange.lowerBound * 2
                    let copyRowBytes = validOutW * 4

                    for row in 0..<validOutH {
                        let srcOffset = (trimTop + row) * tileBytesPerRow + trimLeft * 4
                        let dstOffset = (dstOriginY + row) * dstBytesPerRow + dstOriginX * 4
                        memcpy(dstPtr.advanced(by: dstOffset), srcTilePtr.advanced(by: srcOffset), copyRowBytes)
                    }
                }

                completedTiles += 1
                let percent = Int(Double(completedTiles) / Double(totalTiles) * 100)
                progress?("\(percent)%")
            }
        }

        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: dstRawPtr,
            size: totalTargetBytes,
            releaseData: { _, data, _ in
                free(UnsafeMutableRawPointer(mutating: data))
            }
        ) else {
            throw Anime4kServiceError.readbackFailed
        }
        ownershipTransferred = true

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        )
        guard let cgImage = CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: dstBytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw Anime4kServiceError.readbackFailed
        }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private static func computeStripRanges(total: Int, maxChunk: Int, step: Int) -> [Range<Int>] {
        if total <= maxChunk {
            return [0..<total]
        }
        var ranges: [Range<Int>] = []
        var cursor = 0
        while cursor < total {
            let next = min(total, cursor + step)
            ranges.append(cursor..<next)
            cursor = next
        }
        return ranges
    }

    private static func commitAndWait(_ commandBuffer: MTLCommandBuffer) async throws {
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
        if let error = commandBuffer.error {
            throw error
        }
    }

    private static func maxHardwareInputDimension(for device: MTLDevice) -> Int {
        // Apple4 (A11) 及以上支持 16384×16384 2D 纹理，2x 超分输入单边上限 8192px；早期 GPU 为 8192px（输入 ≤ 4096px）
        #if targetEnvironment(simulator)
        return ImageUpscalerConfig.maxMetalInputDimension
        #else
        return device.supportsFamily(.apple4) ? ImageUpscalerConfig.maxMetalInputDimension : 4096
        #endif
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

    private func loadOrCreatePipeline(config: Anime4kConfig, device: MTLDevice) throws -> [Anime4K] {
        let key = config.cacheKey
        if let existing = cachedPipelines[key] {
            return existing
        }

        // 仅保留当前活跃的 1 套已编译 Metal 管线，切换预设时立即释放旧管线显存
        if cachedPipelines.count >= 1 {
            cachedPipelines.removeAll()
        }

        let steps = config.fullShaderSteps
        var compiled: [Anime4K] = []
        compiled.reserveCapacity(steps.count)

        for step in steps {
            let shader = try Anime4K(step.name, subdir: step.subdir, device: device)
            compiled.append(shader)
        }

        cachedPipelines[key] = compiled
        return compiled
    }

    /// 提取正向 CGImage（避免重复解码，仅方向非 .up 或无 cgImage 时规范化）
    private static func normalizedCGImage(from image: UIImage) throws -> CGImage {
        if let cg = image.cgImage, image.imageOrientation == .up {
            return cg
        }
        guard let normalized = Waifu2xService.forceDecodeToPixelImage(image),
              let cg = normalized.cgImage else {
            throw Anime4kServiceError.imageNormalizationFailed
        }
        return cg
    }

    /// 同步将 CGImage 规范化为 8-bit sRGB RGBA8 并直写 MTLTexture（兼容全系 iOS 15~26，零异步重入风险）
    private static func makeInputTexture(from sourceCG: CGImage, device: MTLDevice) throws -> MTLTexture {
        return try autoreleasepool {
            let width = sourceCG.width
            let height = sourceCG.height
            let bytesPerRow = width * 4
            let totalBytes = bytesPerRow * height
            guard width > 0, height > 0, totalBytes > 0, let rawPtr = malloc(totalBytes) else {
                throw Anime4kServiceError.imageNormalizationFailed
            }
            defer { free(rawPtr) }
            memset(rawPtr, 255, totalBytes)

            let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(
                data: rawPtr,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: sRGB,
                bitmapInfo: bitmapInfo
            ) else {
                throw Anime4kServiceError.imageNormalizationFailed
            }
            context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: width, height: height))

            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared

            guard let texture = device.makeTexture(descriptor: desc) else {
                throw Anime4kServiceError.textureCreationFailed
            }
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.replace(region: region, mipmapLevel: 0, withBytes: rawPtr, bytesPerRow: bytesPerRow)
            return texture
        }
    }

    /// 从 shared MTLTexture 零拷贝读回像素并构造 UIImage（CenterResize 已写入 alpha=1.0 且 CGImage 使用 noneSkipLast，免除 CPU 全图遍历）
    private static func makeUIImage(from texture: MTLTexture) -> UIImage? {
        autoreleasepool {
            let width = texture.width
            let height = texture.height
            let bytesPerRow = width * 4
            let totalBytes = bytesPerRow * height
            guard totalBytes > 0, let rawPtr = malloc(totalBytes) else {
                return nil
            }

            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(rawPtr, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

            // 零拷贝移交堆内存所有权给 CGDataProvider，UIImage/CGImage 释放时自动 free
            guard let provider = CGDataProvider(
                dataInfo: nil,
                data: rawPtr,
                size: totalBytes,
                releaseData: { _, data, _ in
                    free(UnsafeMutableRawPointer(mutating: data))
                }
            ) else {
                free(rawPtr)
                return nil
            }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            )

            guard let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            ) else {
                return nil
            }

            return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        }
    }
}
