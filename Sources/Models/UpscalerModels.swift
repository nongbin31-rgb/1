import CoreGraphics
import Foundation

// MARK: - 1. 核心引擎分类（ImageUpscalerModel）

/// 超分模型大类
public enum ImageUpscalerModel: String, Codable, CaseIterable, Identifiable {
    case anime4k = "anime4k"
    case anime4kCoreML = "anime4kCoreML"
    case waifu2x = "waifu2x"

    public var id: String { rawValue }

    /// 画质增强引擎显示名称
    public var displayName: String {
        switch self {
        case .anime4k: return "Anime4K"
        case .anime4kCoreML: return "Anime4K AI"
        case .waifu2x: return "Waifu2x"
        }
    }

    public var descriptionText: String {
        switch self {
        case .anime4k:
            return "基于 Metal GPU 像素着色器管线，毫秒级实时渲染，极低功耗，支持超长条漫自动分条无缝拼接"
        case .anime4kCoreML:
            return "基于 Apple Neural Engine / CoreML 的轻量化 Anime4K 神经网络，支持 1x 修复、2x/4x 预设与 GAN 强锐化"
        case .waifu2x:
            return "基于 Apple Neural Engine / CoreML 深度卷积网络，印刷级 2x 无损放大与降噪"
        }
    }
}

// 保持向前兼容别名
public typealias UpscalerEngine = ImageUpscalerModel

// MARK: - 2. Waifu2x 10 组核心 2x 模型预设（100% 对齐原包 waifu2x.framework）

/// Waifu2x 官方 10 组 2x 超分模型（对应 .mlmodelc 目录名）
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

    /// Waifu2x 模型本地化文案
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

    /// Anime4K 模型本地化文案
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

// MARK: - 3.5 Anime4K CoreML 神经网络模型预设（ANE 轻量化 1x/2x/3x/4x & GAN）

/// Anime4K CoreML 预编译神经网络模型（对应 Resources/Anime4K_CoreML/*.mlmodelc）
public enum Anime4kCoreMLModel: String, Codable, CaseIterable, Identifiable {
    // 2x 完整管线预设（与 GLSL 同款配方，运行于 ANE 神经网络）
    case perset2x_a_a_fast = "perset2x_a_a_fast"
    case perset2x_a_a_hq   = "perset2x_a_a_hq"
    case perset2x_b_b_fast = "perset2x_b_b_fast"
    case perset2x_b_b_hq   = "perset2x_b_b_hq"
    case perset2x_c_a_fast = "perset2x_c_a_fast"
    case perset2x_c_a_hq   = "perset2x_c_a_hq"

    // GAN 对抗生成强锐化超分（2x / 3x / 4x）
    case model_sr_m_gan    = "model_sr_m_gan"
    case model_sr_l_gan    = "model_sr_l_gan"
    case model_sr_vl_gan   = "model_sr_vl_gan"
    case model_sr_ul_gan   = "model_sr_ul_gan"
    case model_sr_uul_gan  = "model_sr_uul_gan"

    // 4x 一步到位超分预设（适合超低清扫描老漫）
    case perset4x_a_a_fast = "perset4x_a_a_fast"
    case perset4x_a_a_hq   = "perset4x_a_a_hq"
    case perset4x_b_b_fast = "perset4x_b_b_fast"
    case perset4x_b_b_hq   = "perset4x_b_b_hq"
    case perset4x_c_a_fast = "perset4x_c_a_fast"
    case perset4x_c_a_hq   = "perset4x_c_a_hq"

    // 2x 降噪超分 & 1x 原尺寸画质修复
    case model_sr_denoise_m    = "model_sr_denoise_m"
    case model_sr_denoise_ul   = "model_sr_denoise_ul"
    case model_restore_m       = "model_restore_m"
    case model_restore_ul      = "model_restore_ul"
    case model_restore_soft_ul = "model_restore_soft_ul"

    public var id: String { rawValue }

    /// 精确输出放大倍率（严格对齐模型 MIL 输出张量 128 / 256 / 384 / 512）
    public var scaleFactor: Int {
        switch self {
        case .model_restore_m, .model_restore_ul, .model_restore_soft_ul:
            return 1
        case .perset2x_a_a_fast, .perset2x_a_a_hq,
             .perset2x_b_b_fast, .perset2x_b_b_hq,
             .perset2x_c_a_fast, .perset2x_c_a_hq,
             .model_sr_m_gan,
             .model_sr_denoise_m, .model_sr_denoise_ul:
            return 2
        case .model_sr_l_gan, .model_sr_vl_gan:
            return 3
        case .model_sr_ul_gan, .model_sr_uul_gan,
             .perset4x_a_a_fast, .perset4x_a_a_hq,
             .perset4x_b_b_fast, .perset4x_b_b_hq,
             .perset4x_c_a_fast, .perset4x_c_a_hq:
            return 4
        }
    }

    public var displayName: String {
        switch self {
        case .perset2x_a_a_fast:     return "2x · A+A 高速 (推荐)"
        case .perset2x_a_a_hq:       return "2x · A+A 高质量"
        case .perset2x_b_b_fast:     return "2x · B+B 软线条高速"
        case .perset2x_b_b_hq:       return "2x · B+B 软线条高质量"
        case .perset2x_c_a_fast:     return "2x · C+A 降噪高速"
        case .perset2x_c_a_hq:       return "2x · C+A 降噪高质量"
        case .model_sr_m_gan:        return "GAN 2x · 均衡锐化 (M)"
        case .model_sr_l_gan:        return "GAN 3x · 高清锐化 (L)"
        case .model_sr_vl_gan:       return "GAN 3x · 超清锐化 (VL)"
        case .model_sr_ul_gan:       return "GAN 4x · 旗舰锐化 (UL)"
        case .model_sr_uul_gan:      return "GAN 4x · 终极锐化 (UUL)"
        case .perset4x_a_a_fast:     return "4x · A+A 高速"
        case .perset4x_a_a_hq:       return "4x · A+A 高质量"
        case .perset4x_b_b_fast:     return "4x · B+B 软线条高速"
        case .perset4x_b_b_hq:       return "4x · B+B 软线条高质量"
        case .perset4x_c_a_fast:     return "4x · C+A 降噪高速"
        case .perset4x_c_a_hq:       return "4x · C+A 降噪高质量"
        case .model_sr_denoise_m:    return "2x · 轻量降噪超分 (M)"
        case .model_sr_denoise_ul:   return "2x · 深度降噪超分 (UL)"
        case .model_restore_m:       return "1x · 原尺寸去糊修复 (M)"
        case .model_restore_ul:      return "1x · 原尺寸旗舰修复 (UL)"
        case .model_restore_soft_ul: return "1x · 原尺寸柔化修复 (Soft UL)"
        }
    }

    public var modelBundleName: String {
        "\(rawValue).mlmodelc"
    }
}

/// 智能跳过高清原图宽度阈值（原图宽度达标时自动跳过放大超分，省电省内存）
public enum UpscalerSmartSkipThreshold: Int, Codable, CaseIterable, Identifiable {
    case disabled = 0
    case width1600 = 1600
    case width2000 = 2000
    case width2400 = 2400

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .disabled:  return "关闭（全部执行）"
        case .width1600: return "宽 ≥ 1600px 自动跳过"
        case .width2000: return "宽 ≥ 2000px 自动跳过"
        case .width2400: return "宽 ≥ 2400px 自动跳过"
        }
    }
}

// MARK: - 4. 统一超分辨率全局/单本配置（对齐原版 ImageUpscalerConfig）

public struct ImageUpscalerConfig: Codable, Equatable, Hashable {
    /// 选用的超分引擎（Anime4K Metal / Anime4K CoreML / Waifu2x CoreML）
    public var model: ImageUpscalerModel
    /// Anime4K Metal 管线预设与微调参数
    public var anime4k: Anime4kConfig
    /// Anime4K CoreML 神经网络模型预设
    public var anime4kCoreML: Anime4kCoreMLModel
    /// Waifu2x 模型预设
    public var waifu2x: Waifu2xModel
    /// 是否解除超分尺寸限制（默认关闭：按输出总像素智能保护；开启后跳过软件尺寸拦截）
    public var bypassSizeLimit: Bool
    /// 智能跳过高清原图宽度阈值（0 表示关闭；非 0 时原图宽度 ≥ 阈值且放大倍率 > 1 则自动跳过超分）
    public var smartSkipMinWidth: Int

    /// 默认最大允许输入总像素（2x 引擎等价 1200 万输入像素）
    public static let maxPixelCountThreshold: Int = 12_000_000

    /// 默认最大允许输出总像素（4800 万输出像素 ≈ 192MB RGBA8，兼容 2x 12M 输入、4x 3M 输入、1x 48M 输入，防 Jetsam OOM）
    public static let maxOutputPixelCountThreshold: Int = 48_000_000

    /// Anime4K / Metal 单次 2x 纹理输入单边硬件上限（超过此单边将自动启用重叠分条无缝拼接）
    public static let maxMetalInputDimension: Int = 8192

    /// Anime4K 官方进阶说明文档链接
    public static let anime4kTipURL: URL = URL(string: "https://github.com/bloc97/Anime4K/blob/master/md/GLSL_Instructions_Advanced.md")!

    private enum CodingKeys: String, CodingKey {
        case model
        case anime4k
        case anime4kCoreML
        case waifu2x
        case bypassSizeLimit
        case smartSkipMinWidth
    }

    public init(
        model: ImageUpscalerModel = .anime4k,
        anime4k: Anime4kConfig = Anime4kConfig(),
        anime4kCoreML: Anime4kCoreMLModel = .perset2x_a_a_fast,
        waifu2x: Waifu2xModel = .anime_noise1_scale2x,
        bypassSizeLimit: Bool = false,
        smartSkipMinWidth: Int = 0
    ) {
        self.model = model
        self.anime4k = anime4k
        self.anime4kCoreML = anime4kCoreML
        self.waifu2x = waifu2x
        self.bypassSizeLimit = bypassSizeLimit
        self.smartSkipMinWidth = smartSkipMinWidth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decodeIfPresent(ImageUpscalerModel.self, forKey: .model) ?? .anime4k
        self.anime4k = try container.decodeIfPresent(Anime4kConfig.self, forKey: .anime4k) ?? Anime4kConfig()
        self.anime4kCoreML = try container.decodeIfPresent(Anime4kCoreMLModel.self, forKey: .anime4kCoreML) ?? .perset2x_a_a_fast
        self.waifu2x = try container.decodeIfPresent(Waifu2xModel.self, forKey: .waifu2x) ?? .anime_noise1_scale2x
        self.bypassSizeLimit = try container.decodeIfPresent(Bool.self, forKey: .bypassSizeLimit) ?? false
        self.smartSkipMinWidth = try container.decodeIfPresent(Int.self, forKey: .smartSkipMinWidth) ?? 0
    }

    /// 当前所选引擎与模型的实际输出倍率（1x / 2x / 3x / 4x）
    public var outputScaleFactor: Int {
        switch model {
        case .anime4k:
            return 2
        case .anime4kCoreML:
            return anime4kCoreML.scaleFactor
        case .waifu2x:
            return 2
        }
    }

    public var cacheKey: String {
        switch model {
        case .anime4k:
            return "a4k_\(anime4k.cacheKey)"
        case .anime4kCoreML:
            return "a4kml_\(anime4kCoreML.rawValue)"
        case .waifu2x:
            return "w2x_\(waifu2x.rawValue)"
        }
    }

    /// 视图重载标识（含尺寸限制与智能跳过阈值，切换时立即触发页面重新评估是否执行超分）
    public var reloadKey: String {
        "\(cacheKey)_b\(bypassSizeLimit ? 1 : 0)_s\(smartSkipMinWidth)"
    }

    public var summaryText: String {
        switch model {
        case .anime4k:
            var extras: [String] = []
            if anime4k.thinLines { extras.append("细化线条") }
            if anime4k.darkenLines { extras.append("线条加黑") }
            let suffix = extras.isEmpty ? "" : " + \(extras.joined(separator: " / "))"
            return "Anime4K · \(anime4k.preset.displayName)\(suffix)"
        case .anime4kCoreML:
            return "Anime4K AI · \(anime4kCoreML.displayName)"
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

    /// 超分面板耗时与手势说明文案
    public var formattedText: String {
        let secStr = String(format: "%.3f", elapsedSeconds)
        return "运行时长：\(secStr)s，可放大查看细节，单击图像隐藏面板"
    }
}
