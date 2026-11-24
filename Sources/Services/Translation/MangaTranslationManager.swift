import CryptoKit
import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Translation)
import Translation
#endif

/// 漫画翻译错误类型
public enum MangaTranslationError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case imageUnavailable
    case noTextDetected
    case appleTranslationUnavailable
    case networkFailed(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "尚未配置 AI API Key"
        case .invalidEndpoint:
            return "翻译接口地址格式无效"
        case .imageUnavailable:
            return "当前页面图片尚未加载完成"
        case .noTextDetected:
            return "本页未识别到需要翻译的文字"
        case .appleTranslationUnavailable:
            return "当前系统不支持 Apple 离线翻译（需 iOS 18+）"
        case .networkFailed(let msg):
            return msg
        case .decodingFailed(let msg):
            return msg
        }
    }
}

/// 漫画翻译全局调度器（支持 Apple 离线 / Bing 免费 / Google 免费 / AI OpenAI 兼容文本与 VLM 视觉直译）
@MainActor
public final class MangaTranslationManager: ObservableObject {
    public static let shared = MangaTranslationManager()

    private static let configStorageKey = "keda_online_manga_translation_config_v1"

    @Published public var config: MangaTranslationConfig {
        didSet {
            saveConfig()
            if oldValue.cacheSignature != config.cacheSignature {
                #if canImport(UIKit)
                renderedCache.removeAllObjects()
                #endif
                pageResults.removeAll()
                loadDiskCacheIntoMemoryIndex()
            }
        }
    }

    /// 阅读器内是否开启译文图层显示（默认关闭，用户点击「译」按钮开启）
    @Published public var isOverlayVisible: Bool = false
    /// 当前内存中已就绪的译文结果（key = pageURL）
    @Published public private(set) var pageResults: [String: PageTranslationResult] = [:]
    /// 正在翻译中的页面 URL 集合
    @Published public private(set) var translatingPageURLs: Set<String> = []
    /// 已落盘缓存的总页数
    @Published public private(set) var cachedDiskPageCount: Int = 0
    /// 驱动 iOS 18+ SwiftUI `.translationTask` 桥接执行的触发令牌
    @Published internal var appleBridgeTriggerID: UUID?

    private let cacheDirectory: URL
    #if canImport(UIKit)
    private let renderedCache = NSCache<NSString, UIImage>()
    #endif
    private var inFlightTasks: [String: Task<PageTranslationResult, Error>] = [:]

    // Bing 临时 Token 缓存
    private var bingAuthToken: String?
    private var bingAuthExpiry: Date = .distantPast

    // Apple iOS 18+ TranslationSession 桥接队列（串行执行，避免并发冲突）
    private var isAppleBridgeMounted: Bool = false
    private var applePendingTexts: [String] = []
    private var applePendingSourceLang: MangaTranslationSourceLanguage = .auto
    private var appleContinuation: CheckedContinuation<[String], Error>?

    private init() {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDirectory = cachesDir.appendingPathComponent("MangaTranslations", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)

        if let data = UserDefaults.standard.data(forKey: Self.configStorageKey),
           let decoded = try? JSONDecoder().decode(MangaTranslationConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = MangaTranslationConfig()
        }

        #if canImport(UIKit)
        renderedCache.countLimit = 16
        #endif

        refreshDiskCacheCount()
    }

    // MARK: - Persistence & Cache

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configStorageKey)
        }
    }

    public func hasResult(for pageURL: String) -> Bool {
        if let existing = pageResults[pageURL], existing.cacheSignature == config.cacheSignature {
            return true
        }
        return loadDiskResult(for: pageURL, signature: config.cacheSignature) != nil
    }

    public func isTranslating(_ pageURL: String) -> Bool {
        translatingPageURLs.contains(pageURL)
    }

    /// 清除所有本地翻译缓存与内存合成图
    public func clearAllCache() {
        inFlightTasks.values.forEach { $0.cancel() }
        inFlightTasks.removeAll()
        pageResults.removeAll()
        translatingPageURLs.removeAll()
        #if canImport(UIKit)
        renderedCache.removeAllObjects()
        #endif

        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        cachedDiskPageCount = 0
    }

    public func refreshDiskCacheCount() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        cachedDiskPageCount = files.filter { $0.pathExtension.lowercased() == "json" }.count
    }

    private func loadDiskCacheIntoMemoryIndex() {
        refreshDiskCacheCount()
    }

    private func diskFileURL(for pageURL: String, signature: String) -> URL {
        let raw = "\(pageURL)::\(signature)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).json")
    }

    private func loadDiskResult(for pageURL: String, signature: String) -> PageTranslationResult? {
        let url = diskFileURL(for: pageURL, signature: signature)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PageTranslationResult.self, from: data),
              decoded.cacheSignature == signature else {
            return nil
        }
        return decoded
    }

    private func saveDiskResult(_ result: PageTranslationResult) {
        let url = diskFileURL(for: result.pageURL, signature: result.cacheSignature)
        if let data = try? JSONEncoder().encode(result) {
            try? data.write(to: url, options: .atomic)
            refreshDiskCacheCount()
        }
    }

    // MARK: - Display Image Resolution (Zero-Offset Lossless Overlay)

    #if canImport(UIKit)
    /// 返回应展示的页面图片：未开启译文或无译文时返回原图；开启译文且命中结果时返回高清气泡合成图
    public func resolvedDisplayImage(for pageURL: String, baseImage: UIImage) -> UIImage {
        guard isOverlayVisible else { return baseImage }

        let signature = config.cacheSignature
        let result: PageTranslationResult?
        if let mem = pageResults[pageURL], mem.cacheSignature == signature {
            result = mem
        } else if let disk = loadDiskResult(for: pageURL, signature: signature) {
            result = disk
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.pageResults[pageURL] == nil {
                    self.pageResults[pageURL] = disk
                }
            }
        } else {
            result = nil
        }

        guard let result, !result.bubbles.isEmpty else {
            return baseImage
        }

        let pxW = baseImage.cgImage?.width ?? Int(baseImage.size.width * baseImage.scale)
        let pxH = baseImage.cgImage?.height ?? Int(baseImage.size.height * baseImage.scale)
        let renderKey = "\(pageURL)::\(signature)::\(pxW)x\(pxH)::\(result.bubbles.count)" as NSString

        if let cached = renderedCache.object(forKey: renderKey) {
            return cached
        }

        let rendered = MangaBubbleOverlayRenderer.render(baseImage: baseImage, bubbles: result.bubbles)
        renderedCache.setObject(rendered, forKey: renderKey)
        return rendered
    }
    #endif

    // MARK: - Public Translation API

    #if canImport(UIKit)
    /// 翻译指定漫画页（自动命中内存/磁盘缓存、合并重复并发请求）
    @discardableResult
    public func translatePage(
        page: MangaPage,
        image: UIImage? = nil,
        forceRefresh: Bool = false
    ) async throws -> PageTranslationResult {
        let pageURL = page.imageURL
        let activeConfig = self.config
        let signature = activeConfig.cacheSignature

        if !forceRefresh {
            if let existing = pageResults[pageURL], existing.cacheSignature == signature {
                return existing
            }
            if let disk = loadDiskResult(for: pageURL, signature: signature) {
                pageResults[pageURL] = disk
                return disk
            }
        }

        let taskKey = "\(pageURL)::\(signature)"
        if !forceRefresh, let running = inFlightTasks[taskKey] {
            return try await running.value
        }

        translatingPageURLs.insert(pageURL)

        let task = Task<PageTranslationResult, Error> { @MainActor in
            defer {
                self.translatingPageURLs.remove(pageURL)
                self.inFlightTasks.removeValue(forKey: taskKey)
            }

            // 1. 获取原图（优先内存缓存或传入图，否则从加载器拉取）
            let sourceImage: UIImage
            if let passed = image {
                sourceImage = passed
            } else if let mem = OnlineImageLoader.shared.cachedMemoryImage(for: pageURL) {
                sourceImage = mem
            } else {
                sourceImage = try await OnlineImageLoader.shared.loadImage(urlString: pageURL, headers: page.headers)
            }

            let effectiveEngine = activeConfig.resolvedEffectiveEngine
            let bubbles: [TranslatedBubble]
            let engineLabel: String

            // 2. 分引擎执行识别与翻译
            switch effectiveEngine {
            case .aiLLM:
                if activeConfig.useVLMMode {
                    if let vlmBubbles = try? await Self.translateViaVLM(image: sourceImage, config: activeConfig),
                       !vlmBubbles.isEmpty {
                        bubbles = vlmBubbles
                        engineLabel = "\(activeConfig.aiProvider.shortName) VLM"
                    } else {
                        // VLM 未返回有效坐标框时自动无缝回退到 Vision OCR + AI 文本翻译
                        let detected = try await MangaVisionOCR.recognizeBubbles(
                            in: sourceImage,
                            sourceLanguage: activeConfig.sourceLanguage
                        )
                        guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                        let translatedTexts = try await Self.translateTextsViaOpenAI(
                            texts: detected.map(\.text),
                            config: activeConfig
                        )
                        bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts)
                        engineLabel = "\(activeConfig.aiProvider.shortName) OCR"
                    }
                } else {
                    let detected = try await MangaVisionOCR.recognizeBubbles(
                        in: sourceImage,
                        sourceLanguage: activeConfig.sourceLanguage
                    )
                    guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                    let translatedTexts = try await Self.translateTextsViaOpenAI(
                        texts: detected.map(\.text),
                        config: activeConfig
                    )
                    bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts)
                    engineLabel = "\(activeConfig.aiProvider.shortName)"
                }

            case .appleOffline:
                let detected = try await MangaVisionOCR.recognizeBubbles(
                    in: sourceImage,
                    sourceLanguage: activeConfig.sourceLanguage
                )
                guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                let translatedTexts = try await self.translateTextsViaAppleWithFallback(
                    texts: detected.map(\.text),
                    sourceLanguage: activeConfig.sourceLanguage
                )
                bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts.texts)
                engineLabel = translatedTexts.engineLabel

            case .bingFree:
                let detected = try await MangaVisionOCR.recognizeBubbles(
                    in: sourceImage,
                    sourceLanguage: activeConfig.sourceLanguage
                )
                guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                let translatedTexts = try await self.translateTextsViaBing(
                    texts: detected.map(\.text),
                    sourceLanguage: activeConfig.sourceLanguage
                )
                bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts)
                engineLabel = "Bing 免费"

            case .googleFree:
                let detected = try await MangaVisionOCR.recognizeBubbles(
                    in: sourceImage,
                    sourceLanguage: activeConfig.sourceLanguage
                )
                guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                let translatedTexts = try await Self.translateTextsViaGoogle(
                    texts: detected.map(\.text),
                    sourceLanguage: activeConfig.sourceLanguage
                )
                bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts)
                engineLabel = "Google 免费"

            case .auto:
                let detected = try await MangaVisionOCR.recognizeBubbles(
                    in: sourceImage,
                    sourceLanguage: activeConfig.sourceLanguage
                )
                guard !detected.isEmpty else { throw MangaTranslationError.noTextDetected }
                let translatedTexts = try await self.translateTextsViaBing(
                    texts: detected.map(\.text),
                    sourceLanguage: activeConfig.sourceLanguage
                )
                bubbles = Self.zipBubbles(detected: detected, translated: translatedTexts)
                engineLabel = "Bing 免费"
            }

            let result = PageTranslationResult(
                pageURL: pageURL,
                cacheSignature: signature,
                engineLabel: engineLabel,
                bubbles: bubbles,
                createdAt: Date()
            )
            self.pageResults[pageURL] = result
            self.renderedCache.removeAllObjects()
            self.saveDiskResult(result)
            return result
        }

        inFlightTasks[taskKey] = task
        return try await task.value
    }

    /// 静默预翻译下一页（不抛错、不打断阅读）
    public func prefetchTranslationIfNeeded(page: MangaPage) {
        guard isOverlayVisible, config.autoFollowPages else { return }
        guard !hasResult(for: page.imageURL), !isTranslating(page.imageURL) else { return }
        Task {
            _ = try? await translatePage(page: page)
        }
    }
    #endif

    /// 测试当前 AI 配置连通性（用于设置页「测试连接」按钮）
    public func testAIConnection() async -> (ok: Bool, message: String) {
        let cfg = self.config
        guard cfg.hasConfiguredAIKey else {
            return (false, "请先填写 API Key")
        }
        let start = Date()
        do {
            let reply = try await Self.translateTextsViaOpenAI(
                texts: ["こんにちは"],
                config: cfg
            )
            let ms = Int((Date().timeIntervalSince(start) * 1000).rounded())
            let sample = reply.first ?? ""
            return (true, "连接成功（\(ms) ms）· 样例：\(sample)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - Apple Translation Bridge (iOS 18.0+)

    internal func setAppleBridgeMounted(_ mounted: Bool) {
        isAppleBridgeMounted = mounted
        if !mounted, let cont = appleContinuation {
            appleContinuation = nil
            applePendingTexts = []
            cont.resume(throwing: MangaTranslationError.appleTranslationUnavailable)
        }
    }

    internal func consumeApplePendingBatch() -> (texts: [String], sourceLanguage: MangaTranslationSourceLanguage)? {
        guard !applePendingTexts.isEmpty else { return nil }
        return (applePendingTexts, applePendingSourceLang)
    }

    internal func completeAppleBatch(result: Result<[String], Error>) {
        guard let cont = appleContinuation else { return }
        appleContinuation = nil
        applePendingTexts = []
        switch result {
        case .success(let translated):
            cont.resume(returning: translated)
        case .failure(let err):
            cont.resume(throwing: err)
        }
    }

    private func translateTextsViaAppleWithFallback(
        texts: [String],
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> (texts: [String], engineLabel: String) {
        #if canImport(Translation)
        if #available(iOS 18.0, *), isAppleBridgeMounted {
            do {
                let translated = try await runAppleBridgeBatch(texts: texts, sourceLanguage: sourceLanguage)
                return (translated, "Apple 离线")
            } catch {
                // 若系统离线语言包未下载/用户取消/暂不可用，降级到 Bing 免费在线翻译
                let fallback = try await translateTextsViaBing(texts: texts, sourceLanguage: sourceLanguage)
                return (fallback, "Bing 免费")
            }
        }
        #endif
        let fallback = try await translateTextsViaBing(texts: texts, sourceLanguage: sourceLanguage)
        return (fallback, "Bing 免费")
    }

    private func runAppleBridgeBatch(
        texts: [String],
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> [String] {
        // 等待前一批 Apple 翻译完成（简单串行防冲突）
        var waitCycles = 0
        while appleContinuation != nil && waitCycles < 100 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waitCycles += 1
        }
        guard appleContinuation == nil else {
            throw MangaTranslationError.networkFailed("系统翻译正忙，请稍后重试")
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.applePendingTexts = texts
            self.applePendingSourceLang = sourceLanguage
            self.appleContinuation = continuation
            self.appleBridgeTriggerID = UUID()
        }
    }

    // MARK: - Bing Free Translation (No Key, Direct Access)

    private func fetchBingAuthToken() async throws -> String {
        if let token = bingAuthToken, Date() < bingAuthExpiry {
            return token
        }
        guard let url = URL(string: "https://edge.microsoft.com/translate/auth") else {
            throw MangaTranslationError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw MangaTranslationError.networkFailed("Bing 免费翻译鉴权失败，请检查网络或切换引擎")
        }
        self.bingAuthToken = token
        self.bingAuthExpiry = Date().addingTimeInterval(7 * 60)
        return token
    }

    private func translateTextsViaBing(
        texts: [String],
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let token = try await fetchBingAuthToken()

        var urlString = "https://api-edge.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans"
        if let fromCode = sourceLanguage.bingLanguageCode {
            urlString += "&from=\(fromCode)"
        }
        guard let url = URL(string: urlString) else {
            throw MangaTranslationError.invalidEndpoint
        }

        let payload = texts.map { ["Text": $0] }
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            if code == 401 {
                self.bingAuthToken = nil
                self.bingAuthExpiry = .distantPast
            }
            throw MangaTranslationError.networkFailed("Bing 翻译请求失败（HTTP \(code)）")
        }

        guard let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MangaTranslationError.decodingFailed("Bing 翻译响应解析失败")
        }

        var output: [String] = []
        output.reserveCapacity(texts.count)
        for idx in 0..<texts.count {
            if idx < items.count,
               let translations = items[idx]["translations"] as? [[String: Any]],
               let first = translations.first,
               let translated = first["text"] as? String {
                output.append(translated)
            } else {
                output.append(texts[idx])
            }
        }
        return output
    }

    // MARK: - Google Free Translation (No Key)

    private nonisolated static func translateTextsViaGoogle(
        texts: [String],
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        let separator = "\n[[[MANGA_SEP]]]\n"
        let merged = texts.joined(separator: separator)
        if let joinedTranslated = try? await googleTranslateSingleString(merged, sl: sourceLanguage.googleLanguageCode) {
            let parts = joinedTranslated.components(separatedBy: "[[[MANGA_SEP]]]")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == texts.count {
                return parts
            }
        }

        // 兜底：逐条并发翻译
        var results = Array(repeating: "", count: texts.count)
        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (idx, text) in texts.enumerated() {
                group.addTask {
                    let translated = try await googleTranslateSingleString(text, sl: sourceLanguage.googleLanguageCode)
                    return (idx, translated)
                }
            }
            for try await (idx, translated) in group {
                results[idx] = translated
            }
        }
        return results
    }

    private nonisolated static func googleTranslateSingleString(_ text: String, sl: String) async throws -> String {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comps?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "sl", value: sl),
            URLQueryItem(name: "tl", value: "zh-CN"),
            URLQueryItem(name: "q", value: text),
        ]
        guard let url = comps?.url else {
            throw MangaTranslationError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MangaTranslationError.networkFailed("Google 免费翻译失败（HTTP \(code)），国内网络请切换 Bing 或 AI 引擎")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [[Any]] else {
            throw MangaTranslationError.decodingFailed("Google 翻译响应格式异常")
        }
        let translated = sentences.compactMap { $0.first as? String }.joined()
        return translated.isEmpty ? text : translated
    }

    // MARK: - OpenAI-Compatible AI Translation (Text Mode)

    private nonisolated static func buildChatCompletionsURL(baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { throw MangaTranslationError.invalidEndpoint }
        if !trimmed.lowercased().hasSuffix("/chat/completions") {
            trimmed += "/chat/completions"
        }
        guard let url = URL(string: trimmed) else {
            throw MangaTranslationError.invalidEndpoint
        }
        return url
    }

    private nonisolated static func translateTextsViaOpenAI(
        texts: [String],
        config: MangaTranslationConfig
    ) async throws -> [String] {
        guard config.hasConfiguredAIKey else {
            throw MangaTranslationError.missingAPIKey
        }
        let url = try buildChatCompletionsURL(baseURL: config.resolvedBaseURL)

        let itemsPayload: [[String: Any]] = texts.enumerated().map { idx, text in
            ["id": idx, "text": text]
        }
        let inputJSONData = try JSONSerialization.data(withJSONObject: itemsPayload)
        let inputJSONString = String(data: inputJSONData, encoding: .utf8) ?? "[]"

        let systemPrompt = """
        你是一名资深专业漫画汉化组翻译。请结合同一页内所有气泡的对话上下文，将每条漫画台词意译为自然、地道、简练的简体中文口语（贴合二次元语气，不要生硬机翻）。
        严格只返回一个合法 JSON 数组，不要包含任何解释、前后缀或 Markdown 以外的内容。
        返回格式严格为：[{"id":0,"translation":"中文译文"},{"id":1,"translation":"中文译文"}]，条数和 id 必须与输入一一对应。
        """

        let body: [String: Any] = [
            "model": config.resolvedModelName,
            "temperature": 0.25,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "请翻译以下同一页漫画的对话气泡（源语言：\(config.sourceLanguage.displayName)）：\n\(inputJSONString)"]
            ]
        ]

        let rawContent = try await sendOpenAIRequest(url: url, apiKey: config.trimmedAPIKey, body: body, timeout: 45)
        let parsedMap = parseIndexedTranslationsJSON(rawContent)

        var output: [String] = []
        output.reserveCapacity(texts.count)
        for idx in 0..<texts.count {
            if let hit = parsedMap[idx], !hit.isEmpty {
                output.append(hit)
            } else {
                output.append(texts[idx])
            }
        }
        return output
    }

    // MARK: - OpenAI-Compatible Vision LLM Translation (VLM Direct Mode)

    #if canImport(UIKit)
    private nonisolated static func translateViaVLM(
        image: UIImage,
        config: MangaTranslationConfig
    ) async throws -> [TranslatedBubble] {
        guard config.hasConfiguredAIKey else {
            throw MangaTranslationError.missingAPIKey
        }
        let url = try buildChatCompletionsURL(baseURL: config.resolvedBaseURL)
        guard let jpegData = encodeVLMJPEG(from: image, maxLongEdge: 1440, quality: 0.78) else {
            throw MangaTranslationError.imageUnavailable
        }
        let dataURL = "data:image/jpeg;base64,\(jpegData.base64EncodedString())"

        let prompt = """
        请识别这页漫画中的所有对话气泡/旁白框文字，并结合画面情景意译为自然地道的简体中文。
        请严格只输出一个 JSON 数组，不要输出任何额外解释文字。每个元素格式如下：
        {"box":[ymin,xmin,ymax,xmax],"text":"原文","translation":"简体中文译文"}
        其中 box 为 0 到 1000 之间的整数归一化坐标（左上角为 [0,0]，右下角为 [1000,1000]），紧密包裹气泡内的文字区域。如果本页没有任何台词文字，请返回 []。
        """

        let body: [String: Any] = [
            "model": config.resolvedModelName,
            "temperature": 0.2,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        ["type": "image_url", "image_url": ["url": dataURL]]
                    ]
                ]
            ]
        ]

        let rawContent = try await sendOpenAIRequest(url: url, apiKey: config.trimmedAPIKey, body: body, timeout: 60)
        return parseVLMBubblesJSON(rawContent)
    }

    private nonisolated static func encodeVLMJPEG(from image: UIImage, maxLongEdge: CGFloat, quality: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }
        let longEdge = max(size.width, size.height)
        if longEdge <= maxLongEdge {
            return image.jpegData(compressionQuality: quality)
        }
        let scale = maxLongEdge / longEdge
        let targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
    #endif

    private nonisolated static func sendOpenAIRequest(
        url: URL,
        apiKey: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MangaTranslationError.networkFailed("AI 接口无有效响应")
        }

        guard (200...299).contains(http.statusCode) else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MangaTranslationError.networkFailed("API Key 无效或无权限（HTTP \(http.statusCode)）")
            }
            if http.statusCode == 429 {
                throw MangaTranslationError.networkFailed("请求频率或免费额度已达上限（HTTP 429），请稍后重试")
            }
            let brief = extractAPIErrorMessage(from: data) ?? String(errBody.prefix(120))
            throw MangaTranslationError.networkFailed("AI 请求失败（HTTP \(http.statusCode)）：\(brief)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MangaTranslationError.decodingFailed("AI 响应中未找到有效译文内容")
        }
        return content
    }

    private nonisolated static func extractAPIErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
            return msg
        }
        if let msg = obj["message"] as? String {
            return msg
        }
        return nil
    }

    // MARK: - Robust JSON Extraction Helpers

    private nonisolated static func extractJSONArrayData(from raw: String) -> Data? {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = cleaned.firstIndex(of: "["),
              let end = cleaned.lastIndex(of: "]"),
              start <= end else {
            return nil
        }
        let slice = String(cleaned[start...end])
        return slice.data(using: .utf8)
    }

    private nonisolated static func parseIndexedTranslationsJSON(_ raw: String) -> [Int: String] {
        guard let jsonData = extractJSONArrayData(from: raw),
              let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return [:]
        }
        var map: [Int: String] = [:]
        for (fallbackIdx, item) in arr.enumerated() {
            let idVal: Int
            if let intID = item["id"] as? Int {
                idVal = intID
            } else if let strID = item["id"] as? String, let parsed = Int(strID) {
                idVal = parsed
            } else {
                idVal = fallbackIdx
            }
            let translated = (item["translation"] as? String)
                ?? (item["zh"] as? String)
                ?? (item["translated"] as? String)
                ?? (item["text"] as? String)
                ?? ""
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                map[idVal] = cleaned
            }
        }
        return map
    }

    private nonisolated static func parseVLMBubblesJSON(_ raw: String) -> [TranslatedBubble] {
        guard let jsonData = extractJSONArrayData(from: raw),
              let arr = try? JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]] else {
            return []
        }
        var bubbles: [TranslatedBubble] = []
        for item in arr {
            guard let translation = (item["translation"] as? String ?? item["zh"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !translation.isEmpty else {
                continue
            }
            let original = (item["text"] as? String ?? item["original"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let rawBox = (item["box"] as? [Any]) ?? (item["box_2d"] as? [Any]) ?? []
            let nums: [Double] = rawBox.compactMap { v in
                if let d = v as? Double { return d }
                if let i = v as? Int { return Double(i) }
                if let n = v as? NSNumber { return n.doubleValue }
                return nil
            }
            guard nums.count == 4 else { continue }

            // 兼容 0...1000 或 0...1 两种归一化尺度
            let scale: Double = (nums.max() ?? 0) > 1.5 ? 1000.0 : 1.0
            let ymin = max(0, min(1, nums[0] / scale))
            let xmin = max(0, min(1, nums[1] / scale))
            let ymax = max(0, min(1, nums[2] / scale))
            let xmax = max(0, min(1, nums[3] / scale))
            let w = xmax - xmin
            let h = ymax - ymin
            guard w >= 0.015, h >= 0.015, w <= 0.95, h <= 0.95 else { continue }

            bubbles.append(
                TranslatedBubble(
                    rect: CGRect(x: xmin, y: ymin, width: w, height: h),
                    originalText: original,
                    translatedText: translation,
                    isVertical: h > w * 1.25
                )
            )
        }
        return bubbles
    }

    private nonisolated static func zipBubbles(
        detected: [DetectedTextBubble],
        translated: [String]
    ) -> [TranslatedBubble] {
        detected.enumerated().map { idx, bubble in
            let zh = idx < translated.count ? translated[idx] : bubble.text
            return TranslatedBubble(
                rect: bubble.rect,
                originalText: bubble.text,
                translatedText: zh,
                isVertical: bubble.isVertical
            )
        }
    }
}

// MARK: - Apple iOS 18+ Translation Bridge ViewModifier (Xcode 16 & Xcode 26 Safe)

public extension View {
    /// 挂载到 ReaderView 根视图上，在 iOS 18+ 环境下承接 Apple 原生系统离线翻译会话
    @ViewBuilder
    func attachAppleTranslationBridge() -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            self.modifier(AppleTranslationBridgeModifier())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct AppleTranslationBridgeModifier: ViewModifier {
    @ObservedObject private var manager = MangaTranslationManager.shared
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onAppear {
                manager.setAppleBridgeMounted(true)
            }
            .onDisappear {
                manager.setAppleBridgeMounted(false)
            }
            .onChange(of: manager.appleBridgeTriggerID) { _ in
                guard let batch = manager.consumeApplePendingBatch() else { return }
                let sourceLocale: Locale.Language? = batch.sourceLanguage.appleLocaleIdentifier.map {
                    Locale.Language(identifier: $0)
                }
                let targetLocale = Locale.Language(identifier: "zh-Hans")
                if var existing = configuration,
                   existing.source == sourceLocale,
                   existing.target == targetLocale {
                    existing.invalidate()
                    configuration = existing
                } else {
                    configuration = TranslationSession.Configuration(
                        source: sourceLocale,
                        target: targetLocale
                    )
                }
            }
            .translationTask(configuration) { session in
                guard let batch = await MainActor.run(body: { manager.consumeApplePendingBatch() }) else {
                    return
                }
                let requests = batch.texts.enumerated().map { idx, text in
                    TranslationSession.Request(sourceText: text, clientIdentifier: "\(idx)")
                }
                do {
                    let responses = try await session.translations(from: requests)
                    var ordered = batch.texts
                    for response in responses {
                        if let cid = response.clientIdentifier,
                           let idx = Int(cid),
                           ordered.indices.contains(idx) {
                            ordered[idx] = response.targetText
                        }
                    }
                    await MainActor.run {
                        manager.completeAppleBatch(result: .success(ordered))
                    }
                } catch {
                    await MainActor.run {
                        manager.completeAppleBatch(result: .failure(error))
                    }
                }
            }
    }
}
#endif
