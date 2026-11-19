import CoreImage
import Foundation
import Metal
import MetalKit
import UIKit

public enum Anime4kServiceError: LocalizedError {
    case metalUnavailable
    case imageTooLarge(width: Int, height: Int)
    case imageNormalizationFailed
    case textureCreationFailed
    case commandBufferFailed
    case readbackFailed
    case emptyShaderChain

    public var errorDescription: String? {
        switch self {
        case .metalUnavailable:
            return "当前设备不支持 Metal GPU 计算"
        case let .imageTooLarge(w, h):
            return "图片尺寸过大 (\(w)×\(h))，超过 2500px 上限已跳过 Anime4K"
        case .imageNormalizationFailed:
            return "图像色彩空间标准化失败"
        case .textureCreationFailed:
            return "Metal 纹理创建失败"
        case .commandBufferFailed:
            return "Metal 命令缓冲提交失败"
        case .readbackFailed:
            return "Metal 输出纹理读回失败"
        case .emptyShaderChain:
            return "Anime4K 着色器管线为空"
        }
    }
}

/// Anime4K v4 多 Pass Metal 实时超分服务（基于 imxieyi/Anime4KMetal + bloc97/Anime4K）
public actor Anime4kService {
    public static let shared = Anime4kService()

    public static let maxDimension: Int = 2500

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureLoader: MTKTextureLoader?
    private let ciContext: CIContext

    /// 按配置缓存已转译并编译好的 Anime4K 着色器管线（避免每页重复 GLSL->MSL 编译耗时）
    private var cachedPipelines: [String: [Anime4K]] = [:]

    private init() {
        let mtlDevice = MTLCreateSystemDefaultDevice()
        self.device = mtlDevice
        self.commandQueue = mtlDevice?.makeCommandQueue()
        if let mtlDevice {
            self.textureLoader = MTKTextureLoader(device: mtlDevice)
            self.ciContext = CIContext(
                mtlDevice: mtlDevice,
                options: [
                    .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                ]
            )
        } else {
            self.textureLoader = nil
            self.ciContext = CIContext()
        }
    }

    /// 清理已缓存的 Metal 管线以释放显存
    public func clearPipelineCache() {
        cachedPipelines.removeAll()
    }

    /// 执行 Anime4K v4 多 Pass 2x 超分
    public func enhance(image: UIImage, config: Anime4kConfig) async throws -> UIImage {
        guard let device, let commandQueue, let textureLoader else {
            throw Anime4kServiceError.metalUnavailable
        }

        // 1. 通过 CIColorControls 标准化为 8-bit sRGB RGBA（同时处理 EXIF 方向与广色域/灰度兼容）
        guard let normalizedCG = normalizeToSRGBCGImage(image) else {
            throw Anime4kServiceError.imageNormalizationFailed
        }

        let inWidth = normalizedCG.width
        let inHeight = normalizedCG.height

        // 2. 最大尺寸硬门控（防暴显存）
        guard inWidth <= Self.maxDimension && inHeight <= Self.maxDimension else {
            throw Anime4kServiceError.imageTooLarge(width: inWidth, height: inHeight)
        }

        // 3. 加载或复用该配置对应的多 Pass Anime4K 着色器链
        let pipeline = try loadOrCreatePipeline(config: config, device: device)
        guard !pipeline.isEmpty else {
            throw Anime4kServiceError.emptyShaderChain
        }

        // 4. 创建输入纹理（SRGB = false 保持线性采样数值与原图一致）
        let inputTexture = try await textureLoader.newTexture(
            cgImage: normalizedCG,
            options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ]
        )

        // 5. 创建 2x 目标输出纹理（rgba8Unorm + shaderRead/shaderWrite + shared 便于 CPU 零拷贝读回）
        let targetWidth = inWidth * 2
        let targetHeight = inHeight * 2

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

        // 6. 按当前图片分辨率配置各 Pass 的纹理尺寸与 WHEN 条件
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
            currentInW = Int(pass.outputW)
            currentInH = Int(pass.outputH)
        }

        // 7. 编码并提交多 Pass GPU 乒乓计算任务
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw Anime4kServiceError.commandBufferFailed
        }

        var currentTex: MTLTexture = inputTexture
        if pipeline.count > 1 {
            for idx in 0..<(pipeline.count - 1) {
                currentTex = try pipeline[idx].encode(device, cmdBuf: commandBuffer, input: currentTex)
            }
        }
        try pipeline[pipeline.count - 1].encode(
            device,
            cmdBuf: commandBuffer,
            input: currentTex,
            output: outputTexture
        )

        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }

        if let error = commandBuffer.error {
            throw error
        }

        // 8. 从 shared 纹理读回像素并重建 UIImage
        guard let outImage = Self.makeUIImage(from: outputTexture) else {
            throw Anime4kServiceError.readbackFailed
        }

        return outImage
    }

    private func loadOrCreatePipeline(config: Anime4kConfig, device: MTLDevice) throws -> [Anime4K] {
        let key = config.cacheKey
        if let existing = cachedPipelines[key] {
            return existing
        }

        // 限制缓存数量，防止长期切换预设占用过多 Metal 资源
        if cachedPipelines.count >= 3 {
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

    /// 使用 CoreImage + CIColorControls 强制转换为 8-bit sRGB RGBA（修正方向与色彩空间）
    private func normalizeToSRGBCGImage(_ image: UIImage) -> CGImage? {
        var ciImage: CIImage?
        if let cg = image.cgImage {
            ciImage = CIImage(cgImage: cg)
                .oriented(forExifOrientation: Self.exifOrientation(from: image.imageOrientation))
        } else if let existingCI = image.ciImage {
            ciImage = existingCI
        }

        guard let baseCI = ciImage else { return nil }

        let filter = CIFilter(name: "CIColorControls")
        filter?.setValue(baseCI, forKey: kCIInputImageKey)
        filter?.setValue(1.0, forKey: kCIInputContrastKey)
        filter?.setValue(0.0, forKey: kCIInputBrightnessKey)
        filter?.setValue(1.0, forKey: kCIInputSaturationKey)

        let outputCI = filter?.outputImage ?? baseCI
        let extent = outputCI.extent.integral
        guard extent.width > 0 && extent.height > 0 else { return nil }

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(
            outputCI,
            from: extent,
            format: .RGBA8,
            colorSpace: sRGB
        )
    }

    private static func exifOrientation(from orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }

    /// 从 rgba8Unorm shared MTLTexture 读取字节并生成 UIImage（autoreleasepool 保护抑制内存抖动）
    private static func makeUIImage(from texture: MTLTexture) -> UIImage? {
        autoreleasepool {
            let width = texture.width
            let height = texture.height
            let bytesPerRow = width * 4
            let totalBytes = bytesPerRow * height

            var rawBytes = [UInt8](repeating: 0, count: totalBytes)
            let region = MTLRegionMake2D(0, 0, width, height)
            texture.getBytes(&rawBytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

            let cfData = Data(rawBytes) as CFData
            guard let provider = CGDataProvider(data: cfData) else { return nil }

            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
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
