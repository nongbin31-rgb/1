import CoreGraphics
import Foundation

// MARK: - 1. 核心引擎分类（对齐可达阅读器 ImageUpscalerModel）

/// 超分模型大类
public enum ImageUpscalerModel: String, Codable, CaseIterable, Identifiable {
    case anime4k = "anime4k"
    case waifu2x = "waifu2x"

    public var id: String { rawValue }

    /// 对齐可达阅读器多语言文案
    public var displayName: String {
        switch self {
        case .anime4k: return "Anime4K"
        case .waifu2x: return "Waifu2x"
        }
    }

    public var descriptionText: String {
        switch self {
        case .anime4k: return "基于 Metal GPU 像素着色器管线，毫秒级实时渲染，极低功耗"
        case .waifu2x: return "基于 Apple Neural Engine / CoreML 深度卷积网络，印刷级画质重构"
        }
    }
}

// 保持向前兼容别名
public typealias UpscalerEngine = ImageUpscalerModel

// MARK: - 2. Waifu2x 10 组核心 2x 模型预设（100% 对齐原包 waifu2x.framework）

/// Waifu2x 官方 10 组 2x 超分模型（严格对应 .mlmodelc 目录名与可达阅读器原版选项）
public enum Waifu2xModel: String, Codable, CaseIterable, Identifiable {
    // 漫画 / 二次元线稿模型
    case anime_scale2x               = "up_anime_scale2x_model"
    case anime_noise0_scale2x        = "up_anime_noise0_scale2x_model"
    case anime_noise1_scale2x        = "up_anime_noise1_scale2x_model"
    case anime_noise2_scale2x        = "up_anime_noise2_scale2x_model"
    case anime_noise3_scale2x        = "up_anime_noise3_scale2x_model"

    // 照片 / 写实全彩模型
    case photo_scale2x               = "up_photo_scale2x_model"
    case photo_noise0_scale2x        = "up_photo_noise0_scale2x_model"
    case photo_noise1_scale2x        = "up_photo_noise1_scale2x_model"
    case photo_noise2_scale2x        = "up_photo_noise2_scale2x_model"
    case photo_noise3_scale2x        = "up_photo_noise3_scale2x_model"

    public var id: String { rawValue }

    /// 对齐原版可达阅读器「ImageUpscaler - Waifu2x - %@」本地化文案
    public var displayName: String {
        switch self {
        case .anime_scale2x:        return "漫画 - 放大 2 倍"
        case .anime_noise0_scale2x: return "漫画 - 放大 2 倍 - 降噪 0"
        case .anime_noise1_scale2x: return "漫画 - 放大 2 倍 - 降噪 1 (推荐)"
        case .anime_noise2_scale2x: return "漫画 - 放大 2 倍 - 降噪 2"
        case .anime_noise3_scale2x: return "漫画 - 放大 2 倍 - 降噪 3"
        case .photo_scale2x:        return "照片 - 放大 2 倍"
        case .photo_noise0_scale2x: return "照片 - 放大 2 倍 - 降噪 0"
        case .photo_noise1_scale2x: return "照片 - 放大 2 倍 - 降噪 1"
        case .photo_noise2_scale2x: return "照片 - 放大 2 倍 - 降噪 2"
        case .photo_noise3_scale2x: return "照片 - 放大 2 倍 - 降噪 3"
        }
    }

    /// 模型对应的 .mlmodelc 资源文件名
    public var modelBundleName: String {
        "\(rawValue).mlmodelc"
    }

    public var isAnime: Bool {
        rawValue.contains("anime")
    }

    public var noiseLevel: Int {
        if rawValue.contains("noise0") { return 0 }
        if rawValue.contains("noise1") { return 1 }
        if rawValue.contains("noise2") { return 2 }
        if rawValue.contains("noise3") { return 3 }
        return -1
    }
}

public typealias Waifu2xModelPreset = Waifu2xModel

// MARK: - 3. Anime4K 6 大预设与 GLSL 组合（100% 对齐原版 Anime4kConfig）

/// Anime4K 官方 6 大经典管线预设
public enum Anime4kPreset: String, Codable, CaseIterable, Identifiable {
    case AAFast = "AAFast"
    case BBFast = "BBFast"
    case CAFast = "CAFast"
    case AAHQ   = "AAHQ"
    case BBHQ   = "BBHQ"
    case CAHQ   = "CAHQ"

    public var id: String { rawValue }

    /// 对齐原版可达阅读器「ImageUpscaler - Anime4K - %@」文案
    public var displayName: String {
        switch self {
        case .AAFast: return "A + A (超分辨率 + 超分辨率)"
        case .BBFast: return "B + B (软线条超分 + 超分辨率)"
        case .CAFast: return "C + A (降噪 + 超分辨率)"
        case .AAHQ:   return "A + A (超分辨率 + 超分辨率 + 高质量)"
        case .BBHQ:   return "B + B (软线条超分 + 超分辨率 + 高质量)"
        case .CAHQ:   return "C + A (降噪 + 超分辨率 + 高质量)"
        }
    }

    /// 严格对应原版二进制中逆向出的 16 组着色器串联流
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

/// Anime4K 完整配置（对齐原版 Anime4kConfig 结构）
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

// MARK: - 4. 统一超分辨率全局/单本配置（对齐原版 ImageUpscalerConfig）

public struct ImageUpscalerConfig: Codable, Equatable, Hashable {
    /// 选用的超分引擎（Anime4K 实时或 Waifu2x 深度）
    public var model: ImageUpscalerModel
    /// Anime4K 管线预设与微调参数
    public var anime4k: Anime4kConfig
    /// Waifu2x 模型预设
    public var waifu2x: Waifu2xModel

    /// 硬上限保护阈值（防 Jetsam OOM 内存杀死）
    public static let maxDimensionThreshold: CGFloat = 2500.0

    /// Anime4K 官方进阶说明文档链接
    public static let anime4kTipURL: URL = URL(string: "https://github.com/bloc97/Anime4K/blob/master/md/GLSL_Instructions_Advanced.md")!

    public init(
        model: ImageUpscalerModel = .anime4k,
        anime4k: Anime4kConfig = Anime4kConfig(),
        waifu2x: Waifu2xModel = .anime_noise1_scale2x
    ) {
        self.model = model
        self.anime4k = anime4k
        self.waifu2x = waifu2x
    }

    public var cacheKey: String {
        switch model {
        case .anime4k:
            return "a4k_\(anime4k.cacheKey)"
        case .waifu2x:
            return "w2x_\(waifu2x.rawValue)"
        }
    }

    public var summaryText: String {
        switch model {
        case .anime4k:
            var extras: [String] = []
            if anime4k.thinLines { extras.append("细化线条") }
            if anime4k.darkenLines { extras.append("线条加黑") }
            let suffix = extras.isEmpty ? "" : " + \(extras.joined(separator: " / "))"
            return "Anime4K · \(anime4k.preset.displayName)\(suffix)"
        case .waifu2x:
            return "Waifu2x · \(waifu2x.displayName)"
        }
    }
}

// MARK: - 5. 超分推理性能评估模型

public struct UpscalePerformanceResult: Equatable {
    public let elapsedSeconds: Double
    public let originalSize: CGSize
    public let outputSize: CGSize
    public let isSkipped: Bool
    public let skipReason: String?

    public init(
        elapsedSeconds: Double,
        originalSize: CGSize,
        outputSize: CGSize,
        isSkipped: Bool = false,
        skipReason: String? = nil
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.originalSize = originalSize
        self.outputSize = outputSize
        self.isSkipped = isSkipped
        self.skipReason = skipReason
    }

    /// 对齐可达阅读器「运行时长：%@s，可放大查看细节，单击图像隐藏面板」
    public var formattedText: String {
        let secStr = String(format: "%.3f", elapsedSeconds)
        return "运行时长：\(secStr)s，可放大查看细节，单击图像隐藏面板"
    }
}
