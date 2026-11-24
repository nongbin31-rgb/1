import Foundation
import CoreGraphics

/// 漫画翻译引擎选择
public enum MangaTranslationEngine: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 智能默认：已填 AI Key 时走 AI 大模型；未填 Key 时 iOS 18+ 走 Apple 离线翻译，iOS 15~17 走 Bing 免费翻译
    case auto = "auto"
    /// Apple 系统原生离线翻译（iOS 18.0+，免 Key、完全免费、下载语言包后断网可用）
    case appleOffline = "appleOffline"
    /// Bing 免费在线翻译（免 Key、国内直连可用）
    case bingFree = "bingFree"
    /// Google 免费在线翻译（免 Key）
    case googleFree = "googleFree"
    /// AI 大模型翻译（OpenAI 兼容协议，支持 Gemini / 智谱 / DeepSeek / 硅基流动 / 自定义）
    case aiLLM = "aiLLM"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "智能默认（推荐）"
        case .appleOffline: return "Apple 离线翻译 (iOS 18+)"
        case .bingFree: return "Bing 免费在线"
        case .googleFree: return "Google 免费在线"
        case .aiLLM: return "AI 大模型翻译"
        }
    }

    public var shortName: String {
        switch self {
        case .auto: return "智能默认"
        case .appleOffline: return "Apple 离线"
        case .bingFree: return "Bing 免费"
        case .googleFree: return "Google 免费"
        case .aiLLM: return "AI 大模型"
        }
    }
}

/// AI 大模型服务商快捷预设（全兼容 OpenAI Chat Completions 协议）
public enum MangaTranslationAIProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case gemini = "gemini"
    case zhipu = "zhipu"
    case deepseek = "deepseek"
    case siliconflow = "siliconflow"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .zhipu: return "智谱清言（免费模型）"
        case .deepseek: return "DeepSeek"
        case .siliconflow: return "硅基流动"
        case .custom: return "自定义 OpenAI 兼容"
        }
    }

    public var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .zhipu: return "智谱"
        case .deepseek: return "DeepSeek"
        case .siliconflow: return "硅基流动"
        case .custom: return "自定义"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .zhipu: return "https://open.bigmodel.cn/api/paas/v4"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .custom: return "https://api.openai.com/v1"
        }
    }

    public var defaultModelName: String {
        switch self {
        case .gemini: return "gemini-2.5-flash"
        case .zhipu: return "glm-4-flash"
        case .deepseek: return "deepseek-chat"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .custom: return "gpt-4o-mini"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash"]
        case .zhipu:
            return ["glm-4-flash", "glm-4v-flash"]
        case .deepseek:
            return ["deepseek-chat"]
        case .siliconflow:
            return ["Qwen/Qwen2.5-7B-Instruct", "Qwen/Qwen2.5-VL-7B-Instruct"]
        case .custom:
            return ["gpt-4o-mini", "gemini-2.5-flash", "deepseek-chat"]
        }
    }

    public var supportsVisionByDefault: Bool {
        switch self {
        case .gemini, .custom:
            return true
        case .zhipu, .deepseek, .siliconflow:
            return false
        }
    }

    public var keyHelpHint: String {
        switch self {
        case .gemini:
            return "前往 aistudio.google.com/apikey 创建免费 API Key（AIza 开头），默认免费层未绑卡不会扣费。"
        case .zhipu:
            return "前往 open.bigmodel.cn 获取 API Key，glm-4-flash 支持国内直连且官方长期免费。"
        case .deepseek:
            return "前往 platform.deepseek.com 获取 API Key，上下文意译自然、单话成本极低。"
        case .siliconflow:
            return "前往 cloud.siliconflow.cn 获取 API Key，支持国内直连与多款免费轻量模型。"
        case .custom:
            return "填写任意 OpenAI 兼容接口的 Base URL（如中转站、One-API 或本地 Ollama）与模型名。"
        }
    }
}

/// 漫画原文语言设置
public enum MangaTranslationSourceLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case auto = "auto"
    case japanese = "ja"
    case english = "en"
    case korean = "ko"
    case traditionalChinese = "zh-Hant"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自动识别（日/英/韩）"
        case .japanese: return "日语"
        case .english: return "英语"
        case .korean: return "韩语"
        case .traditionalChinese: return "繁体中文"
        }
    }

    /// Apple Vision OCR 识别语言优先顺序
    public var visionRecognitionLanguages: [String] {
        switch self {
        case .auto:
            return ["ja-JP", "en-US", "ko-KR", "zh-Hant"]
        case .japanese:
            return ["ja-JP", "en-US"]
        case .english:
            return ["en-US"]
        case .korean:
            return ["ko-KR", "en-US"]
        case .traditionalChinese:
            return ["zh-Hant", "zh-Hans"]
        }
    }

    /// Apple Translation 框架源语言 BCP-47 标识（nil 表示自动识别）
    public var appleLocaleIdentifier: String? {
        switch self {
        case .auto: return nil
        case .japanese: return "ja"
        case .english: return "en"
        case .korean: return "ko"
        case .traditionalChinese: return "zh-Hant"
        }
    }

    /// Bing 翻译源语言代码（nil 表示自动识别）
    public var bingLanguageCode: String? {
        switch self {
        case .auto: return nil
        case .japanese: return "ja"
        case .english: return "en"
        case .korean: return "ko"
        case .traditionalChinese: return "zh-Hant"
        }
    }

    /// Google 翻译源语言代码
    public var googleLanguageCode: String {
        switch self {
        case .auto: return "auto"
        case .japanese: return "ja"
        case .english: return "en"
        case .korean: return "ko"
        case .traditionalChinese: return "zh-TW"
        }
    }
}

/// 漫画翻译持久化配置
public struct MangaTranslationConfig: Codable, Equatable, Sendable {
    public var engine: MangaTranslationEngine
    public var aiProvider: MangaTranslationAIProvider
    public var apiKey: String
    public var customBaseURL: String
    public var modelName: String
    /// AI 模式下是否启用视觉大模型直接识图（VLM）；默认 false（优先走本地 Vision OCR + AI 文本翻译，更快更省额度）
    public var useVLMMode: Bool
    public var sourceLanguage: MangaTranslationSourceLanguage
    /// 阅读器开启翻译后是否自动跟随翻页翻译并预翻下一页
    public var autoFollowPages: Bool

    public init(
        engine: MangaTranslationEngine = .auto,
        aiProvider: MangaTranslationAIProvider = .gemini,
        apiKey: String = "",
        customBaseURL: String = "",
        modelName: String = MangaTranslationAIProvider.gemini.defaultModelName,
        useVLMMode: Bool = false,
        sourceLanguage: MangaTranslationSourceLanguage = .auto,
        autoFollowPages: Bool = false
    ) {
        self.engine = engine
        self.aiProvider = aiProvider
        self.apiKey = apiKey
        self.customBaseURL = customBaseURL
        self.modelName = modelName
        self.useVLMMode = useVLMMode
        self.sourceLanguage = sourceLanguage
        self.autoFollowPages = autoFollowPages
    }

    public var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var hasConfiguredAIKey: Bool {
        !trimmedAPIKey.isEmpty
    }

    public var resolvedBaseURL: String {
        let custom = customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if aiProvider == .custom {
            return custom.isEmpty ? aiProvider.defaultBaseURL : custom
        }
        return custom.isEmpty ? aiProvider.defaultBaseURL : custom
    }

    public var resolvedModelName: String {
        let trimmed = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? aiProvider.defaultModelName : trimmed
    }

    /// 当前实际生效的翻译执行引擎
    public var resolvedEffectiveEngine: MangaTranslationEngine {
        switch engine {
        case .auto:
            if hasConfiguredAIKey {
                return .aiLLM
            }
            if #available(iOS 18.0, *) {
                return .appleOffline
            }
            return .bingFree
        case .appleOffline:
            if #available(iOS 18.0, *) {
                return .appleOffline
            }
            return .bingFree
        case .aiLLM:
            if hasConfiguredAIKey {
                return .aiLLM
            }
            if #available(iOS 18.0, *) {
                return .appleOffline
            }
            return .bingFree
        case .bingFree, .googleFree:
            return engine
        }
    }

    /// 供设置页展示的简明生效状态
    public var activeEngineSummary: String {
        switch resolvedEffectiveEngine {
        case .aiLLM:
            let modeLabel = useVLMMode ? "VLM 视觉直译" : "Vision OCR + 文本"
            return "\(aiProvider.shortName) · \(modeLabel)"
        case .appleOffline:
            return "Apple 离线翻译（免费）"
        case .bingFree:
            return "Bing 免费在线"
        case .googleFree:
            return "Google 免费在线"
        case .auto:
            return "智能默认"
        }
    }

    /// 缓存签名（切换引擎 / 模型 / VLM / 源语言后自然隔离缓存）
    public var cacheSignature: String {
        let eff = resolvedEffectiveEngine
        switch eff {
        case .aiLLM:
            return "ai_\(aiProvider.rawValue)_\(resolvedModelName)_\(useVLMMode ? "vlm" : "ocr")_\(sourceLanguage.rawValue)"
        default:
            return "\(eff.rawValue)_\(sourceLanguage.rawValue)"
        }
    }
}

/// 单个已翻译对话框气泡（归一化左上角坐标系 0.0...1.0）
public struct TranslatedBubble: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let originalText: String
    public let translatedText: String
    public let isVertical: Bool

    public init(
        id: String = UUID().uuidString,
        rect: CGRect,
        originalText: String,
        translatedText: String,
        isVertical: Bool
    ) {
        self.id = id
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
        self.originalText = originalText
        self.translatedText = translatedText
        self.isVertical = isVertical
    }

    public var normalizedRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 单页翻译结果缓存模型
public struct PageTranslationResult: Codable, Equatable, Sendable {
    public let pageURL: String
    public let cacheSignature: String
    public let engineLabel: String
    public let bubbles: [TranslatedBubble]
    public let createdAt: Date

    public init(
        pageURL: String,
        cacheSignature: String,
        engineLabel: String,
        bubbles: [TranslatedBubble],
        createdAt: Date = Date()
    ) {
        self.pageURL = pageURL
        self.cacheSignature = cacheSignature
        self.engineLabel = engineLabel
        self.bubbles = bubbles
        self.createdAt = createdAt
    }
}
