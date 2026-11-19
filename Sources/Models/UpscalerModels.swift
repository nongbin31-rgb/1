import CoreGraphics
import Foundation

/// 超分引擎大类
public enum UpscalerEngine: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case anime4k = "anime4k"
    case waifu2x = "waifu2x"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .anime4k: return "Anime4K (Metal 实时)"
        case .waifu2x: return "Waifu2x (CoreML 深度)"
        }
    }

    public var shortName: String {
        switch self {
        case .off: return "原图"
        case .anime4k: return "Anime4K"
        case .waifu2x: return "Waifu2x"
        }
    }
}

/// Waifu2x 10 组经典 2x 放大预设（对应 imxieyi/waifu2x-ios 内置模型）
public enum Waifu2xModelPreset: String, Codable, CaseIterable, Identifiable {
    // 漫画/插画类模型
    case anime_scale2x
    case anime_noise0_scale2x
    case anime_noise1_scale2x
    case anime_noise2_scale2x
    case anime_noise3_scale2x

    // 照片/写实类模型
    case photo_scale2x
    case photo_noise0_scale2x
    case photo_noise1_scale2x
    case photo_noise2_scale2x
    case photo_noise3_scale2x

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .anime_scale2x:        return "漫画 · 2x 放大（无降噪）"
        case .anime_noise0_scale2x: return "漫画 · 2x 放大 · 降噪 0"
        case .anime_noise1_scale2x: return "漫画 · 2x 放大 · 降噪 1（推荐）"
        case .anime_noise2_scale2x: return "漫画 · 2x 放大 · 降噪 2"
        case .anime_noise3_scale2x: return "漫画 · 2x 放大 · 降噪 3"
        case .photo_scale2x:        return "照片 · 2x 放大（无降噪）"
        case .photo_noise0_scale2x: return "照片 · 2x 放大 · 降噪 0"
        case .photo_noise1_scale2x: return "照片 · 2x 放大 · 降噪 1"
        case .photo_noise2_scale2x: return "照片 · 2x 放大 · 降噪 2"
        case .photo_noise3_scale2x: return "照片 · 2x 放大 · 降噪 3"
        }
    }

    public var categoryTitle: String {
        rawValue.hasPrefix("anime") ? "漫画 / 二次元" : "照片 / 写实"
    }
}

/// Anime4K v4 6 大经典管线预设
public enum Anime4kPreset: String, Codable, CaseIterable, Identifiable {
    case AAFast
    case BBFast
    case CAFast
    case AAHQ
    case BBHQ
    case CAHQ

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .AAFast: return "Mode A+A (极速 · 清晰源)"
        case .BBFast: return "Mode B+B (极速 · 轻度模糊)"
        case .CAFast: return "Mode C+A (极速 · 重度压缩)"
        case .AAHQ:   return "Mode A+A HQ (旗舰 · 极致轮廓)"
        case .BBHQ:   return "Mode B+B HQ (旗舰 · 模糊重建)"
        case .CAHQ:   return "Mode C+A HQ (旗舰 · 强力降噪)"
        }
    }

    public var shortName: String { rawValue }

    /// 按顺序串行执行的 Anime4K v4 官方 GLSL 着色器列表 (subdir, filename)
    public var shaderSteps: [(subdir: String, name: String)] {
        switch self {
        case .AAFast:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Restore", "Anime4K_Restore_CNN_M.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_M.glsl"),
                ("Restore", "Anime4K_Restore_CNN_S.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_S.glsl"),
            ]
        case .BBFast:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Restore", "Anime4K_Restore_CNN_Soft_M.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_M.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Restore", "Anime4K_Restore_CNN_Soft_S.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_S.glsl"),
            ]
        case .CAFast:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Upscale+Denoise", "Anime4K_Upscale_Denoise_CNN_x2_M.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Restore", "Anime4K_Restore_CNN_S.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_S.glsl"),
            ]
        case .AAHQ:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Restore", "Anime4K_Restore_CNN_UL.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_UL.glsl"),
                ("Restore", "Anime4K_Restore_CNN_M.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_M.glsl"),
            ]
        case .BBHQ:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Restore", "Anime4K_Restore_CNN_Soft_UL.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_UL.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Restore", "Anime4K_Restore_CNN_Soft_M.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_M.glsl"),
            ]
        case .CAHQ:
            return [
                ("Restore", "Anime4K_Clamp_Highlights.glsl"),
                ("Upscale+Denoise", "Anime4K_Upscale_Denoise_CNN_x2_UL.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x2.glsl"),
                ("Upscale", "Anime4K_AutoDownscalePre_x4.glsl"),
                ("Restore", "Anime4K_Restore_CNN_M.glsl"),
                ("Upscale", "Anime4K_Upscale_CNN_x2_M.glsl"),
            ]
        }
    }
}

/// Anime4K 完整配置
public struct Anime4kConfig: Codable, Equatable, Hashable {
    public var preset: Anime4kPreset
    public var thinLines: Bool
    public var darkenLines: Bool

    public init(
        preset: Anime4kPreset = .AAFast,
        thinLines: Bool = false,
        darkenLines: Bool = false
    ) {
        self.preset = preset
        self.thinLines = thinLines
        self.darkenLines = darkenLines
    }

    /// 实际参与编译的完整着色器链（基础预设 + 可选线稿滤镜）
    public var fullShaderSteps: [(subdir: String, name: String)] {
        var steps = preset.shaderSteps
        if thinLines {
            steps.append(("Experimental-Effects", "Anime4K_Thin_HQ.glsl"))
        }
        if darkenLines {
            steps.append(("Experimental-Effects", "Anime4K_Darken_HQ.glsl"))
        }
        return steps
    }

    public var cacheKey: String {
        "\(preset.rawValue)_t\(thinLines ? 1 : 0)_d\(darkenLines ? 1 : 0)"
    }
}

/// 全局/单本超分配置
public struct ImageUpscalerConfig: Codable, Equatable, Hashable {
    public var engine: UpscalerEngine
    public var waifu2x: Waifu2xModelPreset
    public var anime4k: Anime4kConfig

    public init(
        engine: UpscalerEngine = .anime4k,
        waifu2x: Waifu2xModelPreset = .anime_noise1_scale2x,
        anime4k: Anime4kConfig = Anime4kConfig()
    ) {
        self.engine = engine
        self.waifu2x = waifu2x
        self.anime4k = anime4k
    }

    public var cacheKey: String {
        switch engine {
        case .off:
            return "off"
        case .waifu2x:
            return "w2x_\(waifu2x.rawValue)"
        case .anime4k:
            return "a4k_\(anime4k.cacheKey)"
        }
    }

    public var summaryText: String {
        switch engine {
        case .off:
            return "关闭（显示原图）"
        case .waifu2x:
            return "Waifu2x · \(waifu2x.displayName)"
        case .anime4k:
            var extras: [String] = []
            if anime4k.thinLines { extras.append("细化线稿") }
            if anime4k.darkenLines { extras.append("加深线稿") }
            let suffix = extras.isEmpty ? "" : " + \(extras.joined(separator: "/"))"
            return "Anime4K · \(anime4k.preset.shortName)\(suffix)"
        }
    }
}

/// 超分处理结果（附带耗时与尺寸信息，方便阅读器 HUD 观察效果）
public struct UpscaleResult {
    public let image: Data? // 可选序列化
    public let elapsedMs: Int
    public let originalSize: CGSize
    public let outputSize: CGSize
    public let skippedReason: String?

    public init(
        elapsedMs: Int,
        originalSize: CGSize,
        outputSize: CGSize,
        skippedReason: String? = nil
    ) {
        self.image = nil
        self.elapsedMs = elapsedMs
        self.originalSize = originalSize
        self.outputSize = outputSize
        self.skippedReason = skippedReason
    }
}
