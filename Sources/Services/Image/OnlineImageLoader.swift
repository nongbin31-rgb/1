import CryptoKit
import Foundation
import UIKit

/// 线程安全图片内存缓存封装（支持在 actor 的 nonisolated 同步快路径中零锁访问 NSCache）
private final class SendableImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage>

    init(countLimit: Int, totalCostLimit: Int) {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = countLimit
        c.totalCostLimit = totalCostLimit
        self.cache = c
    }

    func object(forKey key: NSString) -> UIImage? {
        cache.object(forKey: key)
    }

    func setObject(_ image: UIImage, forKey key: NSString, cost: Int) {
        if cost > 0 {
            cache.setObject(image, forKey: key, cost: cost)
        } else {
            cache.setObject(image, forKey: key)
        }
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

/// 原子一次性 Continuation 盒子（保证多订阅者共享下载任务时取消与完成绝不重复 resume）
private final class CancellableImageWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case registered(CheckedContinuation<UIImage, Error>)
        case finished(Result<UIImage, Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func attach(_ continuation: CheckedContinuation<UIImage, Error>) {
        var immediate: Result<UIImage, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .registered(continuation)
        case .finished(let result):
            immediate = result
        case .registered:
            break
        }
        lock.unlock()

        if let immediate {
            continuation.resume(with: immediate)
        }
    }

    func resume(with result: Result<UIImage, Error>) {
        var contToResume: CheckedContinuation<UIImage, Error>?
        lock.lock()
        switch state {
        case .pending:
            state = .finished(result)
        case .registered(let cont):
            state = .finished(result)
            contToResume = cont
        case .finished:
            break
        }
        lock.unlock()

        contToResume?.resume(with: result)
    }

    @discardableResult
    func cancel() -> Bool {
        var contToResume: CheckedContinuation<UIImage, Error>?
        var didCancel = false
        lock.lock()
        switch state {
        case .pending:
            state = .finished(.failure(CancellationError()))
            didCancel = true
        case .registered(let cont):
            state = .finished(.failure(CancellationError()))
            contToResume = cont
            didCancel = true
        case .finished:
            break
        }
        lock.unlock()

        contToResume?.resume(throwing: CancellationError())
        return didCancel
    }
}

/// 在途下载任务登记项（同一 URL 支持前台与预载共享下载；仅当全部等待者取消时中止底层 HTTP 请求）
private final class InFlightImageEntry: @unchecked Sendable {
    var task: Task<Void, Never>?
    var waiters: [UUID: CancellableImageWaiter] = [:]
}

/// 在线漫画图片异步加载与双层缓存（内存 + 磁盘），集成多图床容灾竞速与 JM 分块反混淆，同时支持 synthetic:// 测试图生成
public actor OnlineImageLoader {
    public static let shared = OnlineImageLoader()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 18
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    private let memoryCache = SendableImageCache(
        countLimit: 60,
        totalCostLimit: 160 * 1024 * 1024
    )

    private let diskDirectory: URL
    private var inFlightEntries: [String: InFlightImageEntry] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("OnlineMangaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskDirectory = dir
    }

    public func loadImage(urlString: String, headers: [String: String] = [:]) async throws -> UIImage {
        let identityKey = normalizedCacheKey(for: urlString)
        let cacheKey = identityKey as NSString
        if let memImage = memoryCache.object(forKey: cacheKey) {
            return memImage
        }

        if urlString.hasPrefix("synthetic://") {
            let synthetic = Self.renderSyntheticMangaImage(urlString: urlString)
            memoryCache.setObject(synthetic, forKey: cacheKey, cost: Self.memoryCost(of: synthetic))
            return synthetic
        }

        try Task.checkCancellation()

        let diskPath = diskFileURL(for: identityKey)
        if let data = try? Data(contentsOf: diskPath), let diskImage = UIImage(data: data) {
            let cost = max(data.count, Self.memoryCost(of: diskImage))
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: cost)
            return diskImage
        }

        try Task.checkCancellation()

        let waiterID = UUID()
        let waiter = CancellableImageWaiter()
        let entry: InFlightImageEntry

        if let existing = inFlightEntries[identityKey] {
            existing.waiters[waiterID] = waiter
            entry = existing
        } else {
            let newEntry = InFlightImageEntry()
            newEntry.waiters[waiterID] = waiter
            inFlightEntries[identityKey] = newEntry
            entry = newEntry

            newEntry.task = Task<Void, Never> {
                do {
                    let jmMeta = JmImageMeta.tryParse(urlString)
                    let candidates = await self.buildCandidateUrls(rawUrl: urlString)
                    guard !candidates.isEmpty else {
                        throw MangaSourceError.invalidURL(urlString)
                    }

                    let fetched = try await self.fetchFirstValidImage(candidates: candidates, extraHeaders: headers)
                    try Task.checkCancellation()

                    if let group = self.imageDomainGroup(for: urlString),
                       let winningHost = URL(string: fetched.winningURL)?.host {
                        await OnlineEndpointStore.shared.setHealthyImageDomain(winningHost, for: group)
                    }

                    guard let processed = JmImageDescrambler.descrambleIfNeeded(data: fetched.data, meta: jmMeta) else {
                        throw MangaSourceError.decodingFailed("响应内容不是有效的图片数据")
                    }

                    try? processed.cacheData.write(to: diskPath, options: .atomic)
                    await self.finishInFlight(
                        key: identityKey,
                        entry: newEntry,
                        result: .success(processed.image)
                    )
                } catch {
                    await self.finishInFlight(
                        key: identityKey,
                        entry: newEntry,
                        result: .failure(error)
                    )
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            if waiter.cancel() {
                Task {
                    await self.handleWaiterCancelled(key: identityKey, waiterID: waiterID, entry: entry)
                }
            }
        }
    }

    /// 后台预载入单张图片（若已在内存缓存则跳过；可随时响应 Task 取消）
    public func preloadImage(urlString: String, headers: [String: String] = [:]) async {
        guard !Task.isCancelled else { return }
        let identityKey = normalizedCacheKey(for: urlString)
        if memoryCache.object(forKey: identityKey as NSString) != nil {
            return
        }
        _ = try? await loadImage(urlString: urlString, headers: headers)
    }

    private func finishInFlight(
        key: String,
        entry: InFlightImageEntry,
        result: Result<UIImage, Error>
    ) {
        if case .success(let image) = result {
            memoryCache.setObject(image, forKey: key as NSString, cost: Self.memoryCost(of: image))
        }
        if inFlightEntries[key] === entry {
            inFlightEntries.removeValue(forKey: key)
        }
        let waiters = Array(entry.waiters.values)
        entry.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func handleWaiterCancelled(key: String, waiterID: UUID, entry: InFlightImageEntry) {
        entry.waiters.removeValue(forKey: waiterID)
        if entry.waiters.isEmpty {
            if inFlightEntries[key] === entry {
                inFlightEntries.removeValue(forKey: key)
            }
            entry.task?.cancel()
        }
    }

    public func clearAllCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        Task { @MainActor in
            ReaderThumbnailStore.shared.clearAll()
        }
    }

    /// 同步零 IO 内存缓存查询（专供主线程 Slot 快路径与预载入调度使用）
    public nonisolated func cachedMemoryImage(for urlString: String) -> UIImage? {
        let identityKey = normalizedCacheKey(for: urlString)
        return memoryCache.object(forKey: identityKey as NSString)
    }

    /// 同步快速获取已缓存的图片（优先内存，次选磁盘）
    public nonisolated func cachedImage(for urlString: String) -> UIImage? {
        let identityKey = normalizedCacheKey(for: urlString)
        if let memoryImage = memoryCache.object(forKey: identityKey as NSString) {
            return memoryImage
        }
        let diskURL = diskFileURL(for: identityKey)
        if let diskData = try? Data(contentsOf: diskURL), let diskImage = UIImage(data: diskData) {
            let cost = max(diskData.count, Self.memoryCost(of: diskImage))
            memoryCache.setObject(diskImage, forKey: identityKey as NSString, cost: cost)
            return diskImage
        }
        return nil
    }

    /// 快速判断图片是否已存在于内存或磁盘（不触发图片解码）
    public nonisolated func hasCachedImage(for urlString: String) -> Bool {
        let identityKey = normalizedCacheKey(for: urlString)
        if memoryCache.object(forKey: identityKey as NSString) != nil {
            return true
        }
        return FileManager.default.fileExists(atPath: diskFileURL(for: identityKey).path)
    }

    /// 若图片已落盘缓存，返回磁盘文件路径（供缩略图解码器通过 ImageIO 按低像素尺寸按需降采样）
    public nonisolated func cachedDiskFileURL(for urlString: String) -> URL? {
        let identityKey = normalizedCacheKey(for: urlString)
        let url = diskFileURL(for: identityKey)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func diskCacheSizeBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: diskDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        return items.reduce(0) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sum + Int64(size)
        }
    }

    public func diskCacheByteCount() -> Int64 {
        diskCacheSizeBytes()
    }

    private nonisolated func diskFileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hash)
    }

    private nonisolated static func memoryCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(1, cg.width * cg.height * 4)
        }
        let w = Int(image.size.width * image.scale)
        let h = Int(image.size.height * image.scale)
        return max(1, w * h * 4)
    }

    // MARK: - Multi-CDN Failover & URL Normalization

    private nonisolated func normalizeImageURL(_ rawUrl: String) -> String {
        var cleanUrl = rawUrl.components(separatedBy: "#").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanUrl.isEmpty else { return "" }
        if cleanUrl.hasPrefix("//") {
            let dropped = cleanUrl.drop(while: { $0 == "/" })
            cleanUrl = "https://\(dropped)"
        } else if cleanUrl.lowercased().hasPrefix("http://") || cleanUrl.lowercased().hasPrefix("https://") {
            if let range = cleanUrl.range(of: #"^https?:/+"#, options: [.regularExpression, .caseInsensitive]) {
                cleanUrl.replaceSubrange(range, with: "https://")
            }
        }
        return cleanUrl
    }

    private nonisolated func isJmImageURL(_ url: URL, rawUrl: String) -> Bool {
        let host = (url.host ?? "").lowercased()
        return host.contains("jmapiproxy")
            || host.contains("jmapinode")
            || host.contains("cdnbtd")
            || host.contains("cdnutc")
            || host.contains("cdngwc")
            || host.contains("cdnhjk")
            || rawUrl.contains("#jm=")
            || url.path.contains("/media/photos/")
            || url.path.contains("/media/albums/")
    }

    private nonisolated func isWnacgHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.contains("wnacg")
            || lower.contains("cloudwn")
            || lower.contains("wnmanga")
            || lower.contains("wnimg")
            || lower.contains("qy0.ru")
            || lower.contains("byteimg")
    }

    private nonisolated func isWnacgImageMirrorHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.contains("byteimg")
            || lower.contains("wnimg")
            || lower.contains("qy0.ru")
            || lower.contains("wnacg.download")
    }

    private nonisolated func imageDomainGroup(for rawUrl: String) -> String? {
        let clean = normalizeImageURL(rawUrl)
        if let url = URL(string: clean) {
            if isJmImageURL(url, rawUrl: rawUrl) { return "jm" }
            if let host = url.host, isWnacgHost(host) { return "wnacg" }
        } else if rawUrl.contains("#jm=") {
            return "jm"
        }
        return nil
    }

    private nonisolated func normalizedCacheKey(for rawUrl: String) -> String {
        let clean = normalizeImageURL(rawUrl)
        guard let url = URL(string: clean), !url.path.isEmpty else {
            return rawUrl
        }
        let querySuffix = url.query.map { "?\($0)" } ?? ""
        if isJmImageURL(url, rawUrl: rawUrl) {
            let frag = rawUrl.components(separatedBy: "#").dropFirst().first.map { "#\($0)" } ?? ""
            return "jm:\(url.path)\(querySuffix)\(frag)"
        }
        if let host = url.host, isWnacgImageMirrorHost(host) {
            return "wnacg:\(url.path)\(querySuffix)"
        }
        return clean
    }

    private func buildCandidateUrls(rawUrl: String) async -> [String] {
        let cleanUrl = normalizeImageURL(rawUrl)
        guard var components = URLComponents(string: cleanUrl),
              let url = components.url else {
            return cleanUrl.isEmpty ? [] : [cleanUrl]
        }

        if components.scheme?.lowercased() == "http" {
            components.scheme = "https"
        }

        let origHost = url.host ?? ""
        let isJmCover = url.path.contains("/media/albums/")
        let isJm = isJmImageURL(url, rawUrl: rawUrl)
        let group = imageDomainGroup(for: rawUrl)
        let healthyHost: String? = group != nil ? await OnlineEndpointStore.shared.healthyImageDomain(for: group!) : nil

        var hosts: [String] = []
        func addHost(_ host: String?) {
            guard let h = host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !h.isEmpty,
                  !hosts.contains(h) else { return }
            hosts.append(h)
        }

        if isJm {
            addHost(healthyHost)
            let resolvedJmImg = await JmApiClient.shared.currentImageDomain()
            addHost(resolvedJmImg)
            if origHost.contains("jmapiproxy") || origHost.contains("cdn-") {
                addHost(origHost)
            }
            for d in JmCrypto.defaultImageDomains { addHost(d) }
            addHost(origHost)
        } else {
            addHost(healthyHost)
            addHost(origHost)
        }

        if isWnacgImageMirrorHost(origHost) {
            for mirror in ["img2.qy0.ru", "img3.qy0.ru", "img2.wnimg2.cfd", "t4.wnimg2.cfd", "t3.wnimg2.cfd", "wnimg2.cfd"] {
                addHost(mirror)
            }
        }
        if origHost.contains("wnacg.download") {
            if origHost.hasPrefix("img") {
                for i in 1...6 { addHost("img\(i).wnacg.download") }
            } else if origHost.hasPrefix("t") {
                for i in 1...4 { addHost("t\(i).wnacg.download") }
            }
        }

        var pathVariants = [components.path]
        if isJmCover {
            if components.path.hasSuffix("_3x4.jpg") {
                pathVariants.append(components.path.replacingOccurrences(of: "_3x4.jpg", with: ".jpg"))
            } else if components.path.hasSuffix(".jpg") {
                pathVariants.append(components.path.replacingOccurrences(of: ".jpg", with: "_3x4.jpg"))
            }
        }

        var candidates: [String] = []
        for path in pathVariants {
            for host in hosts {
                var c = components
                c.host = host
                c.path = path
                if let candidate = c.string, !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates.isEmpty ? [cleanUrl] : candidates
    }

    private nonisolated func buildHeaders(for url: URL, extraHeaders: [String: String]) -> [String: String] {
        var merged: [String: String] = ["User-Agent": JmCrypto.defaultUserAgent]
        if let host = url.host, isWnacgHost(host) {
            merged["Referer"] = "https://www.wnacg.com/"
        }
        for (k, v) in extraHeaders where !v.isEmpty {
            merged[k] = v
        }
        return merged
    }

    private nonisolated func fetchSingleCandidate(urlString: String, extraHeaders: [String: String]) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw MangaSourceError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        for (k, v) in buildHeaders(for: url, extraHeaders: extraHeaders) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MangaSourceError.httpError(http.statusCode)
        }
        guard !data.isEmpty, UIImage(data: data) != nil else {
            throw MangaSourceError.decodingFailed("响应内容不是有效的图片数据")
        }
        return data
    }

    private func fetchFirstValidImage(
        candidates: [String],
        extraHeaders: [String: String]
    ) async throws -> (data: Data, winningURL: String) {
        if candidates.count == 1, let first = candidates.first {
            let data = try await fetchSingleCandidate(urlString: first, extraHeaders: extraHeaders)
            return (data, first)
        }

        var lastError: Error?
        var idx = 0
        let batchSize = 2
        while idx < candidates.count {
            let end = min(idx + batchSize, candidates.count)
            let batch = Array(candidates[idx..<end])

            let outcome: (data: Data?, winningURL: String?, error: Error?) = await withTaskGroup(
                of: (data: Data?, url: String, error: Error?).self
            ) { group in
                for candidate in batch {
                    group.addTask {
                        do {
                            let bytes = try await self.fetchSingleCandidate(urlString: candidate, extraHeaders: extraHeaders)
                            return (bytes, candidate, nil)
                        } catch {
                            return (nil, candidate, error)
                        }
                    }
                }

                var batchError: Error?
                for await res in group {
                    if let data = res.data {
                        group.cancelAll()
                        return (data, res.url, nil)
                    } else if let err = res.error, !(err is CancellationError) {
                        batchError = err
                    }
                }
                return (nil, nil, batchError)
            }

            if let data = outcome.data, let url = outcome.winningURL {
                return (data, url)
            }
            if let err = outcome.error {
                lastError = err
            }
            idx = end
        }

        throw lastError ?? MangaSourceError.decodingFailed("所有图片 CDN 节点均加载失败")
    }

    /// 生成带低分辨率 JPEG 压缩特征的漫画基准测试图（640x960），便于肉眼直观验证 2x 超分锐化与去噪效果
    private static func renderSyntheticMangaImage(urlString: String) -> UIImage {
        let isCover = urlString.contains("/cover/")
        let isColor = urlString.contains("color")
        let isSpeedline = urlString.contains("speedline")
        let size = isCover ? CGSize(width: 420, height: 600) : CGSize(width: 640, height: 960)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rawImage = renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            if isColor {
                let colors = [
                    UIColor(red: 0.14, green: 0.19, blue: 0.34, alpha: 1).cgColor,
                    UIColor(red: 0.89, green: 0.48, blue: 0.38, alpha: 1).cgColor,
                    UIColor(red: 0.98, green: 0.88, blue: 0.72, alpha: 1).cgColor,
                ] as CFArray
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: colors,
                    locations: [0.0, 0.55, 1.0]
                ) {
                    cg.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: 0, y: 0),
                        end: CGPoint(x: size.width, y: size.height),
                        options: []
                    )
                }
            } else {
                UIColor(white: 0.96, alpha: 1).setFill()
                cg.fill(rect)
            }

            // 漫画分镜框
            let margin: CGFloat = 24
            let panel1 = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height * 0.44)
            let panel2 = CGRect(x: margin, y: panel1.maxY + 18, width: (size.width - margin * 2 - 14) * 0.52, height: size.height * 0.44)
            let panel3 = CGRect(x: panel2.maxX + 14, y: panel1.maxY + 18, width: (size.width - margin * 2 - 14) * 0.48, height: size.height * 0.44)

            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(3.5)
            for panel in [panel1, panel2, panel3] {
                if !isColor {
                    UIColor.white.setFill()
                    cg.fill(panel)
                }
                cg.stroke(panel)
            }

            // 放射速度线（测试斜线抗锯齿和 Anime4K 线稿细化/加深）
            cg.saveGState()
            cg.clip(to: panel1)
            let center = CGPoint(x: panel1.midX, y: panel1.midY)
            cg.setStrokeColor((isColor ? UIColor.white.withAlphaComponent(0.65) : UIColor.black.withAlphaComponent(0.75)).cgColor)
            let rayCount = isSpeedline ? 96 : 48
            for i in 0..<rayCount {
                let angle = CGFloat(i) / CGFloat(rayCount) * .pi * 2
                let innerR: CGFloat = isSpeedline ? 65 : 95
                let outerR: CGFloat = max(panel1.width, panel1.height)
                cg.setLineWidth(i % 3 == 0 ? 2.2 : 1.0)
                cg.move(to: CGPoint(x: center.x + cos(angle) * innerR, y: center.y + sin(angle) * innerR))
                cg.addLine(to: CGPoint(x: center.x + cos(angle) * outerR, y: center.y + sin(angle) * outerR))
                cg.strokePath()
            }
            // 同心圆弧测试曲线重建
            cg.setStrokeColor((isColor ? UIColor.yellow : UIColor.black).cgColor)
            cg.setLineWidth(2.5)
            for radius in stride(from: 24.0, through: 88.0, by: 16.0) {
                cg.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            cg.restoreGState()

            // 网点与排线（panel2）
            cg.saveGState()
            cg.clip(to: panel2)
            cg.setFillColor(UIColor.black.withAlphaComponent(0.22).cgColor)
            for x in stride(from: panel2.minX + 6, to: panel2.maxX, by: 8) {
                for y in stride(from: panel2.minY + 6, to: panel2.maxY, by: 8) {
                    cg.fillEllipse(in: CGRect(x: x, y: y, width: 2.6, height: 2.6))
                }
            }
            cg.restoreGState()

            // 漫画对白气泡与中文文字（测试文字锐利度与振铃抑制）
            let bubbleRect = CGRect(x: panel3.minX + 16, y: panel3.minY + 26, width: panel3.width - 32, height: 150)
            UIColor.white.setFill()
            cg.fillEllipse(in: bubbleRect)
            cg.setStrokeColor(UIColor.black.cgColor)
            cg.setLineWidth(2.5)
            cg.strokeEllipse(in: bubbleRect)

            let label = isColor ? "彩漫超分测试\n640×960 → 2x" : "线稿超分测试\n请拖动滑块对比"
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor.black,
                .paragraphStyle: paragraph,
            ]
            let textRect = bubbleRect.insetBy(dx: 12, dy: 44)
            (label as NSString).draw(in: textRect, withAttributes: attrs)

            // 底部标注页面 URL，便于确认翻页
            let footAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: isColor ? UIColor.white : UIColor.darkGray,
            ]
            let tag = "ORIGIN 1x • \(urlString.replacingOccurrences(of: "synthetic://", with: ""))"
            (tag as NSString).draw(at: CGPoint(x: margin + 8, y: size.height - 26), withAttributes: footAttrs)
        }

        // 刻意做一次中低质量 JPEG 压缩，模拟真实在线漫画常见的块效应与压缩噪点，超分对比会非常明显
        if let jpegData = rawImage.jpegData(compressionQuality: 0.42),
           let compressed = UIImage(data: jpegData) {
            return compressed
        }
        return rawImage
    }
}
