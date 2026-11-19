import Foundation
import UIKit
import Waifu2xEngine

public enum Waifu2xServiceError: LocalizedError {
    case imageTooSmall(width: Int, height: Int)
    case imageTooLarge(width: Int, height: Int)
    case decodeFailed
    case inferenceFailed

    public var errorDescription: String? {
        switch self {
        case let .imageTooSmall(w, h):
            return "图片尺寸过小 (\(w)×\(h))，Waifu2x 要求最小边 ≥ 200px"
        case let .imageTooLarge(w, h):
            return "图片尺寸过大 (\(w)×\(h))，超过 2500px 上限已跳过超分"
        case .decodeFailed:
            return "位图预解码失败"
        case .inferenceFailed:
            return "Waifu2x CoreML 推理失败"
        }
    }
}

/// Waifu2x 端侧 CoreML 超分服务（基于 imxieyi/waifu2x-ios）
/// 使用 actor 串行调度，防止上游 Waifu2x 静态管线并发竞态及多页同时推理导致 OOM
public actor Waifu2xService {
    public static let shared = Waifu2xService()

    public static let minDimension: Int = 200
    public static let maxDimension: Int = 2500

    private init() {}

    /// 执行 Waifu2x 2x 超分
    public func enhance(
        image: UIImage,
        preset: Waifu2xModelPreset,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> UIImage {
        // 1. 统一像素化并规避 iOS 15+ 延迟位图解码空数据问题（同时归一化 scale = 1.0 与方向 .up）
        guard let preparedImage = Self.forceDecodeToPixelImage(image) else {
            throw Waifu2xServiceError.decodeFailed
        }

        let width = Int(preparedImage.size.width)
        let height = Int(preparedImage.size.height)

        // 2. 双向尺寸安全边界拦截（下限 200px 防止 156x156 分块越界，上限 2500px 防爆内存）
        guard width >= Self.minDimension && height >= Self.minDimension else {
            throw Waifu2xServiceError.imageTooSmall(width: width, height: height)
        }
        guard width <= Self.maxDimension && height <= Self.maxDimension else {
            throw Waifu2xServiceError.imageTooLarge(width: width, height: height)
        }

        // 3. 显式映射到 Waifu2xEngine.Model 枚举
        let engineModel = Self.mapModel(preset)

        // 4. 在后台队列执行分块 CoreML + Metal 双三次插值推理
        let output: UIImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Waifu2x.run(preparedImage, model: engineModel) { state in
                    progress?(state)
                }
                continuation.resume(returning: result)
            }
        }

        guard let enhanced = output else {
            throw Waifu2xServiceError.inferenceFailed
        }
        return enhanced
    }

    /// 中断当前正在进行的 Waifu2x 推理
    public func cancelCurrent() {
        Waifu2x.interrupt = true
    }

    /// 映射 10 组预设到 Waifu2xEngine 内置模型
    private static func mapModel(_ preset: Waifu2xModelPreset) -> Waifu2xEngine.Model {
        switch preset {
        case .anime_scale2x:        return .anime_scale2x
        case .anime_noise0_scale2x: return .anime_noise0_scale2x
        case .anime_noise1_scale2x: return .anime_noise1_scale2x
        case .anime_noise2_scale2x: return .anime_noise2_scale2x
        case .anime_noise3_scale2x: return .anime_noise3_scale2x
        case .photo_scale2x:        return .photo_scale2x
        case .photo_noise0_scale2x: return .photo_noise0_scale2x
        case .photo_noise1_scale2x: return .photo_noise1_scale2x
        case .photo_noise2_scale2x: return .photo_noise2_scale2x
        case .photo_noise3_scale2x: return .photo_noise3_scale2x
        }
    }

    /// 强制将图像绘制为 8-bit sRGB RGBA 完整内存位图，scale = 1.0，orientation = .up
    private static func forceDecodeToPixelImage(_ image: UIImage) -> UIImage? {
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
        format.opaque = false
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
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
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
