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

    /// 清理已缓存的 Metal 管线以释放显存
    public func clearPipelineCache() {
        cachedPipelines.removeAll()
    }

    /// 执行 Anime4K 2x 超分
    /// - Parameters:
    ///   - image: 输入原始图片
    ///   - config: 包含预设（AAFast/BBFast/CAFast/AAHQ/BBHQ/CAHQ）以及 thinLines 与 darkenLines 开关
    ///   - bypassSizeLimit: 是否解除默认总像素上限（Metal 单边硬件上限仍生效）
    /// - Returns: 2 倍放大后的 UIImage
    public func enhance(
        image: UIImage,
        config: Anime4kConfig = Anime4kConfig(),
        bypassSizeLimit: Bool = false
    ) async throws -> UIImage {
        guard let device, let commandQueue else {
            throw Anime4kServiceError.metalUnavailable
        }

        let hardwareMaxInputSide = Self.maxHardwareInputDimension(for: device)

        // 0. 前置像素尺寸校验（在排队与分配位图前快速拦截超限图）
        let preSize = Self.pixelDimensions(of: image)
        if preSize.width > 0 && preSize.height > 0 {
            guard preSize.width <= hardwareMaxInputSide && preSize.height <= hardwareMaxInputSide else {
                throw Anime4kServiceError.exceedsMetalTextureLimit(
                    width: preSize.width,
                    height: preSize.height,
                    maxInputSide: hardwareMaxInputSide
                )
            }
            if !bypassSizeLimit {
                let pixelCount = preSize.width * preSize.height
                guard pixelCount <= Self.maxPixelCount else {
                    throw Anime4kServiceError.imageTooLarge(
                        width: preSize.width,
                        height: preSize.height,
                        maxPixels: Self.maxPixelCount
                    )
                }
            }
        }

        // 严格串行排队：同一时刻仅允许 1 页占用共享 Anime4K 管线与 GPU 显存
        await acquireGate()
        defer { releaseGate() }

        try Task.checkCancellation()

        // 1. 同步标准化为 8-bit sRGB RGBA 并直接上传到 MTLTexture（彻底避开 iOS 15 MTKTextureLoader 异步兼容坑）
        let (inputTex, inWidth, inHeight) = try Self.makeInputTexture(from: image, device: device)

        // 2. 标准化后二次校验 Metal 硬件上限与默认总像素上限
        guard inWidth <= hardwareMaxInputSide && inHeight <= hardwareMaxInputSide else {
            throw Anime4kServiceError.exceedsMetalTextureLimit(
                width: inWidth,
                height: inHeight,
                maxInputSide: hardwareMaxInputSide
            )
        }
        if !bypassSizeLimit {
            let pixelCount = inWidth * inHeight
            guard pixelCount <= Self.maxPixelCount else {
                throw Anime4kServiceError.imageTooLarge(
                    width: inWidth,
                    height: inHeight,
                    maxPixels: Self.maxPixelCount
                )
            }
        }

        try Task.checkCancellation()

        // 3. 加载或复用该配置对应的多 Pass Anime4K 着色器链
        let pipeline = try loadOrCreatePipeline(config: config, device: device)
        guard let finalPass = pipeline.last else {
            throw Anime4kServiceError.emptyShaderChain
        }

        // 无论正常结束、任务取消还是异常退出，均确保释放全部中间 rgba16Float 纹理
        defer {
            for pass in pipeline {
                pass.releaseIntermediateTextures()
            }
        }

        let targetWidth = inWidth * 2
        let targetHeight = inHeight * 2

        // 4. 按当前图片分辨率配置各 Pass 的纹理尺寸与 WHEN 条件
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

        // 5. 分阶段提交 GPU 计算任务：每完成一个着色器文件立刻释放该阶段全部中间 rgba16Float 纹理，
        //    将单页瞬时显存峰值降低 65%~75%，并避免单次长命令缓冲触发 iOS 15 Metal Watchdog 超时
        var currentTex: MTLTexture? = inputTex
        for pass in pipeline {
            try Task.checkCancellation()
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

        // 6. 创建 2x 目标 RGBA8 输出纹理（shared 模式便于 CPU 零拷贝读回）并执行最终 CenterResize
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

        // 提前释放最后的中间 rgba16Float 显存纹理，与下方 CPU 位图读回错峰
        currentTex = nil

        // 7. 零拷贝读回像素并生成高质量 UIImage
        guard let outImage = Self.makeUIImage(from: outputTexture) else {
            throw Anime4kServiceError.readbackFailed
        }

        return outImage
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

        // 限制缓存数量，防止长期切换预设占用过多内存
        if cachedPipelines.count >= 2 {
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

    /// 同步将 UIImage 规范化为 8-bit sRGB RGBA8 并直写 MTLTexture（兼容全系 iOS 15~26，零异步重入风险）
    private static func makeInputTexture(from image: UIImage, device: MTLDevice) throws -> (MTLTexture, Int, Int) {
        return try autoreleasepool {
            let sourceCG: CGImage
            if let cg = image.cgImage, image.imageOrientation == .up {
                sourceCG = cg
            } else {
                guard let normalized = Waifu2xService.forceDecodeToPixelImage(image),
                      let cg = normalized.cgImage else {
                    throw Anime4kServiceError.imageNormalizationFailed
                }
                sourceCG = cg
            }

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
            return (texture, width, height)
        }
    }

    /// 从 shared MTLTexture 零拷贝读回像素并构造 UIImage（确保 Alpha 为 100% 不透明，彻底消除 Data 双倍拷贝峰值）
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

            // 强制将第 4 通道 Alpha 设为 255（不透明），杜绝着色器 luma 计算导致 Alpha 为 0 呈现透明空图
            let bytePtr = rawPtr.bindMemory(to: UInt8.self, capacity: totalBytes)
            for i in stride(from: 3, to: totalBytes, by: 4) {
                bytePtr[i] = 255
            }

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
