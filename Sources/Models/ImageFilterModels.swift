import Foundation
import SwiftUI

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

    // 黑白参数: 0.0 ~ 1.0 (去色强度)
    public var grayscaleIntensity: Double = 1.0

    // 伽马校正参数: 0.3 ~ 2.5 (1.0为原始，>1.0压暗深色去灰，推荐1.3)
    public var gammaValue: Double = 1.3

    // 锐化参数: 0.1 ~ 2.0 (提升线条边缘对比，推荐0.8)
    public var sharpnessValue: Double = 0.8

    // 色调冷暖: -1.0 (偏冷/水墨) ~ +1.0 (偏暖/护眼羊皮纸)，0.0为中性原色
    public var toneTemperature: Double = 0.2

    // 阴影调节: -1.0 (深邃暗部) ~ +1.0 (提亮暗部细节)，0.0为默认
    public var shadowAmount: Double = -0.2

    public init(
        type: ImageFilterType,
        isEnabled: Bool = false,
        grayscaleIntensity: Double = 1.0,
        gammaValue: Double = 1.3,
        sharpnessValue: Double = 0.8,
        toneTemperature: Double = 0.2,
        shadowAmount: Double = -0.2
    ) {
        self.type = type
        self.isEnabled = isEnabled
        self.grayscaleIntensity = grayscaleIntensity
        self.gammaValue = gammaValue
        self.sharpnessValue = sharpnessValue
        self.toneTemperature = toneTemperature
        self.shadowAmount = shadowAmount
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
                return "gray_\(String(format: "%.2f", c.grayscaleIntensity))"
            case .gamma:
                return "gamma_\(String(format: "%.2f", c.gammaValue))"
            case .sharpen:
                return "sharp_\(String(format: "%.2f", c.sharpnessValue))"
            case .tone:
                return "tone_\(String(format: "%.2f", c.toneTemperature))"
            case .shadow:
                return "shadow_\(String(format: "%.2f", c.shadowAmount))"
            }
        }.joined(separator: "-")
    }
}
