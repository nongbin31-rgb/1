import Foundation
import SwiftUI
import UIKit

/// 可持久化的 sRGB 染纸颜色（兼容 iOS 15+，不依赖 iOS 17+ Color.resolve）
public struct FilterRGBColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(max(red, 0.0), 1.0)
        self.green = min(max(green, 0.0), 1.0)
        self.blue = min(max(blue, 0.0), 1.0)
    }

    public static let warmPaper    = FilterRGBColor(red: 0.98, green: 0.94, blue: 0.84)
    public static let sageGreen    = FilterRGBColor(red: 0.86, green: 0.94, blue: 0.86)
    public static let coolInk      = FilterRGBColor(red: 0.91, green: 0.94, blue: 0.98)
    public static let vintageSepia = FilterRGBColor(red: 0.95, green: 0.88, blue: 0.75)

    public static let presets: [(name: String, color: FilterRGBColor)] = [
        ("暖纸", .warmPaper),
        ("护眼绿", .sageGreen),
        ("水墨蓝", .coolInk),
        ("复古纸", .vintageSepia)
    ]

    public var swiftUIColor: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }

    public init(swiftUIColor: Color) {
        let uiColor = UIColor(swiftUIColor)
        var r: CGFloat = 1.0
        var g: CGFloat = 1.0
        var b: CGFloat = 1.0
        var a: CGFloat = 1.0
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            self.init(red: Double(r), green: Double(g), blue: Double(b))
        } else if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let converted = uiColor.cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
                  let comps = converted.components, comps.count >= 3 {
            self.init(red: Double(comps[0]), green: Double(comps[1]), blue: Double(comps[2]))
        } else {
            self = .warmPaper
        }
    }

    public var cacheToken: String {
        String(format: "%02x%02x%02x", Int(round(red * 255)), Int(round(green * 255)), Int(round(blue * 255)))
    }
}

/// 画面滤镜类型枚举（严格对齐漫画阅读器滤镜规范）
public enum ImageFilterType: String, CaseIterable, Identifiable, Codable, Sendable {
    case grayscale   // 黑白
    case gamma       // 伽马校正
    case sharpen     // 锐化
    case tone        // 色调
    case shadow      // 阴影

    public var id: String { rawValue }

    /// 主标题
    public var title: String {
        switch self {
        case .grayscale: return "黑白"
        case .gamma: return "伽马校正"
        case .sharpen: return "锐化"
        case .tone: return "色调"
        case .shadow: return "阴影"
        }
    }

    /// 副标题说明（截图一致）
    public var subtitle: String {
        switch self {
        case .grayscale: return "(彩图变黑白)"
        case .gamma: return "(改善图片发灰)"
        case .sharpen: return "(提升画面清晰度)"
        case .tone: return ""
        case .shadow: return ""
        }
    }

    /// 完整显示文本
    public var fullDisplayName: String {
        if subtitle.isEmpty {
            return title
        } else {
            return "\(title) \(subtitle)"
        }
    }

    /// SF Symbol 系统图标名
    public var systemIcon: String {
        switch self {
        case .grayscale: return "circle.hexagongrid.fill"
        case .gamma: return "gauge.with.needle"
        case .sharpen: return "chevron.up.chevron.down"
        case .tone: return "slider.horizontal.3"
        case .shadow: return "mountain.2"
        }
    }
}

/// 单个滤镜的精细参数配置
public struct ImageFilterItemConfig: Codable, Equatable, Sendable {
    public var type: ImageFilterType
    public var isEnabled: Bool

    // 黑白参数: 去色强度 0.0 ~ 1.0 + 独立对比度 0.5 ~ 2.0 (默认 1.12 保持黑白分明)
    public var grayscaleIntensity: Double = 1.0
    public var grayscaleContrast: Double = 1.12

    // 伽马校正参数: 0.2 ~ 3.0 (1.0 为原始，>1.0 压暗发灰线条，推荐 1.3)
    public var gammaValue: Double = 1.3

    // 锐化参数: 0.0 ~ 2.0 (提升线条边缘对比，推荐 0.8)
    public var sharpnessValue: Double = 0.8

    // 色调参数: 冷暖 -1.0 ~ +1.0 + 饱和度 0.0 ~ 2.0 + 可选护眼染纸色
    public var toneTemperature: Double = 0.2
    public var toneSaturation: Double = 1.0
    public var toneTintEnabled: Bool = false
    public var toneTintColor: FilterRGBColor = .warmPaper

    // 阴影调节: -1.0 (深邃暗部) ~ +1.0 (提亮暗部细节)，0.0 为默认
    public var shadowAmount: Double = -0.2

    private enum CodingKeys: String, CodingKey {
        case type
        case isEnabled
        case grayscaleIntensity
        case grayscaleContrast
        case gammaValue
        case sharpnessValue
        case toneTemperature
        case toneSaturation
        case toneTintEnabled
        case toneTintColor
        case shadowAmount
    }

    public init(
        type: ImageFilterType,
        isEnabled: Bool = false,
        grayscaleIntensity: Double = 1.0,
        grayscaleContrast: Double = 1.12,
        gammaValue: Double = 1.3,
        sharpnessValue: Double = 0.8,
        toneTemperature: Double = 0.2,
        toneSaturation: Double = 1.0,
        toneTintEnabled: Bool = false,
        toneTintColor: FilterRGBColor = .warmPaper,
        shadowAmount: Double = -0.2
    ) {
        self.type = type
        self.isEnabled = isEnabled
        self.grayscaleIntensity = grayscaleIntensity
        self.grayscaleContrast = grayscaleContrast
        self.gammaValue = gammaValue
        self.sharpnessValue = sharpnessValue
        self.toneTemperature = toneTemperature
        self.toneSaturation = toneSaturation
        self.toneTintEnabled = toneTintEnabled
        self.toneTintColor = toneTintColor
        self.shadowAmount = shadowAmount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decode(ImageFilterType.self, forKey: .type)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        let intensity = try container.decodeIfPresent(Double.self, forKey: .grayscaleIntensity) ?? 1.0
        self.grayscaleIntensity = intensity
        // 旧版配置未存 grayscaleContrast 时按旧公式 1.0 + 0.12 * intensity 平滑迁移
        self.grayscaleContrast = try container.decodeIfPresent(Double.self, forKey: .grayscaleContrast) ?? (1.0 + 0.12 * intensity)
        self.gammaValue = try container.decodeIfPresent(Double.self, forKey: .gammaValue) ?? 1.3
        self.sharpnessValue = try container.decodeIfPresent(Double.self, forKey: .sharpnessValue) ?? 0.8
        self.toneTemperature = try container.decodeIfPresent(Double.self, forKey: .toneTemperature) ?? 0.2
        self.toneSaturation = try container.decodeIfPresent(Double.self, forKey: .toneSaturation) ?? 1.0
        self.toneTintEnabled = try container.decodeIfPresent(Bool.self, forKey: .toneTintEnabled) ?? false
        self.toneTintColor = try container.decodeIfPresent(FilterRGBColor.self, forKey: .toneTintColor) ?? .warmPaper
        self.shadowAmount = try container.decodeIfPresent(Double.self, forKey: .shadowAmount) ?? -0.2
    }

    public static func `default`(for type: ImageFilterType) -> ImageFilterItemConfig {
        ImageFilterItemConfig(type: type, isEnabled: false)
    }
}

/// 阅读器全局画面滤镜配置
public struct ImageFilterConfig: Codable, Equatable, Sendable {
    /// 滤镜总开关
    public var isGlobalEnabled: Bool = true

    /// 用户当前已启用的滤镜顺序列表（有序执行滤镜链）
    public var activeFilterTypes: [ImageFilterType] = []

    /// 各滤镜具体参数映射字典
    public var itemConfigs: [ImageFilterType: ImageFilterItemConfig] = [:]

    public init(
        isGlobalEnabled: Bool = true,
        activeFilterTypes: [ImageFilterType] = [],
        itemConfigs: [ImageFilterType: ImageFilterItemConfig] = [:]
    ) {
        self.isGlobalEnabled = isGlobalEnabled
        self.activeFilterTypes = activeFilterTypes
        self.itemConfigs = itemConfigs
    }

    /// 获取特定滤镜的配置（若无则返回默认值）
    public func config(for type: ImageFilterType) -> ImageFilterItemConfig {
        itemConfigs[type] ?? ImageFilterItemConfig.default(for: type)
    }

    /// 更新特定滤镜的配置
    public mutating func updateConfig(_ config: ImageFilterItemConfig) {
        itemConfigs[config.type] = config
    }

    /// 启用某个滤镜
    public mutating func enableFilter(_ type: ImageFilterType) {
        if !activeFilterTypes.contains(type) {
            activeFilterTypes.append(type)
        }
        var item = config(for: type)
        item.isEnabled = true
        itemConfigs[type] = item
    }

    /// 禁用某个滤镜
    public mutating func disableFilter(_ type: ImageFilterType) {
        activeFilterTypes.removeAll(where: { $0 == type })
        var item = config(for: type)
        item.isEnabled = false
        itemConfigs[type] = item
    }

    /// 是否有任何滤镜实际生效
    public var hasActiveFilters: Bool {
        isGlobalEnabled && !activeFilterTypes.isEmpty
    }

    /// 当前处于未启用状态的滤镜列表（按标准顺序排列）
    public var inactiveFilterTypes: [ImageFilterType] {
        ImageFilterType.allCases.filter { !activeFilterTypes.contains($0) }
    }

    /// 默认初始配置（全滤镜预注册为未启用）
    public static func defaultConfig() -> ImageFilterConfig {
        var map: [ImageFilterType: ImageFilterItemConfig] = [:]
        for type in ImageFilterType.allCases {
            map[type] = ImageFilterItemConfig.default(for: type)
        }
        return ImageFilterConfig(
            isGlobalEnabled: true,
            activeFilterTypes: [],
            itemConfigs: map
        )
    }

    /// 用于缓存快速命中比对的唯一 Hash Key
    public var cacheSignature: String {
        guard hasActiveFilters else { return "none" }
        return activeFilterTypes.map { type in
            let c = config(for: type)
            switch type {
            case .grayscale:
                return "gray_\(String(format: "%.2f_c%.2f", c.grayscaleIntensity, c.grayscaleContrast))"
            case .gamma:
                return "gamma_\(String(format: "%.2f", c.gammaValue))"
            case .sharpen:
                return "sharp_\(String(format: "%.2f", c.sharpnessValue))"
            case .tone:
                let tintPart = c.toneTintEnabled ? "_m\(c.toneTintColor.cacheToken)" : ""
                return "tone_\(String(format: "%.2f_s%.2f", c.toneTemperature, c.toneSaturation))\(tintPart)"
            case .shadow:
                return "shadow_\(String(format: "%.2f", c.shadowAmount))"
            }
        }.joined(separator: "-")
    }
}
