import CoreGraphics
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
        }
    }
}

/// Anime4K v4 实时超分辨率服务（基于 Metal + 逆向自可达阅读器的 16 组着色器管线）
public actor Anime4kService {
    public static let shared = Anime4kService()

    /// 最大允许单边分辨率（对齐可达阅读器原版硬上限 2500px）
    public static let maxDimension: Int = 2500

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureLoader: MTKTextureLoader?
    private let ciContext: CIContext

    /// Anime4K 引擎调度实例
    private var anime4kEngine: Anime4K?

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
            self.anime4kEngine = Anime4K(name: "Anime4K_Engine", device: mtlDevice)
        } else {
            self.textureLoader = nil
            self.ciContext = CIContext()
            self.anime4kEngine = nil
        }
    }

    /// 执行 Anime4K 2x 超分
    /// - Parameters:
    ///   - image: 输入原始图片
    ///   - config: 包含预设（AAFast/BBFast/CAFast/AAHQ/BBHQ/CAHQ）以及 thinLines 与 darkenLines 开关
    /// - Returns: 2 倍放大后的 UIImage
    public func enhance(image: UIImage, config: Anime4kConfig = Anime4kConfig()) async throws -> UIImage {
        guard let device, let commandQueue, let textureLoader, let engine = anime4kEngine else {
            throw Anime4kServiceError.metalUnavailable
        }

        // 1. 标准化为 8-bit sRGB RGBA（修正方向与色彩空间）
        guard let normalizedCG = normalizeToSRGBCGImage(image) else {
            throw Anime4kServiceError.imageNormalizationFailed
        }

        let inWidth = normalizedCG.width
        let inHeight = normalizedCG.height

        // 2. 尺寸硬上限检查（2500px 防爆显存）
        guard inWidth <= Self.maxDimension && inHeight <= Self.maxDimension else {
            throw Anime4kServiceError.imageTooLarge(width: inWidth, height: inHeight)
        }

        // 3. 配置引擎尺寸
        let targetWidth = inWidth * 2
        let targetHeight = inHeight * 2
        engine.configure(
            textureInW: inWidth,
            textureInH: inHeight,
            outputW: targetWidth,
            outputH: targetHeight
        )

        // 4. 创建输入纹理
        let inputTexture = try await textureLoader.newTexture(
            cgImage: normalizedCG,
            options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ]
        )

        // 5. 创建 2x 目标输出纹理（shared 模式方便 CPU 无拷贝读回）
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: targetWidth,
            height: targetHeight,
            mipmapped: false
        )
        outDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        outDesc.storageMode = .shared

        guard let outputTexture = device.makeTexture(descriptor: outDesc) else {
            throw Anime4kServiceError.textureCreationFailed
        }

        // 6. 编码并提交 GPU 计算任务
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw Anime4kServiceError.commandBufferFailed
        }

        try engine.encode(
            cmdBuf: commandBuffer,
            input: inputTexture,
            output: outputTexture,
            preset: config.preset,
            thinLines: config.thinLines,
            darkenLines: config.darkenLines
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

        // 7. 读回像素并生成高清 UIImage（autoreleasepool 保护抑制内存抖动）
        guard let outImage = Self.makeUIImage(from: outputTexture) else {
            throw Anime4kServiceError.readbackFailed
        }

        return outImage
    }

    /// 使用 CoreImage + CIColorControls 标准化为 8-bit sRGB RGBA
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

    /// 从 shared MTLTexture 读回像素并构造 UIImage
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
