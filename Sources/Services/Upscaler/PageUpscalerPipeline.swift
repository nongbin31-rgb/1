import CryptoKit
import Foundation
import UIKit

/// 超分执行结果（包含处理后图片及诊断统计）
public struct ProcessedPageImage {
    public let image: UIImage
    public let originalSize: CGSize
    public let outputSize: CGSize
    public let elapsedMs: Int
    public let appliedModel: ImageUpscalerModel?
    public let notice: String?

    public init(
        image: UIImage,
        originalSize: CGSize,
        outputSize: CGSize,
        elapsedMs: Int,
        appliedModel: ImageUpscalerModel?,
        notice: String? = nil
    ) {
        self.image = image
        self.originalSize = originalSize
        self.outputSize = outputSize
        self.elapsedMs = elapsedMs
        self.appliedModel = appliedModel
        self.notice = notice
    }
}

/// 原子一次性超分 Continuation 盒子（保证前台与后台预热合并复用时取消与完成绝不重复 resume）
private final class CancellableUpscaleWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case registered(CheckedContinuation<ProcessedPageImage, Never>)
        case finished(ProcessedPageImage)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func attach(_ continuation: CheckedContinuation<ProcessedPageImage, Never>) {
        var immediate: ProcessedPageImage?
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
            continuation.resume(returning: immediate)
        }
    }

    func resume(with result: ProcessedPageImage) {
        var contToResume: CheckedContinuation<ProcessedPageImage, Never>?
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

        contToResume?.resume(returning: result)
    }

    @discardableResult
    func cancel(with cancelledResult: ProcessedPageImage) -> Bool {
        var contToResume: CheckedContinuation<ProcessedPageImage, Never>?
        var didCancel = false
        lock.lock()
        switch state {
        case .pending:
            state = .finished(cancelledResult)
            didCancel = true
        case .registered(let cont):
            state = .finished(cancelledResult)
            contToResume = cont
            didCancel = true
        case .finished:
            break
        }
        lock.unlock()

        contToResume?.resume(returning: cancelledResult)
        return didCancel
    }
}

/// 在途超分任务登记项（支持前台直接承接后台预热的进度与结果，并在无等待者时即时中止）
private final class InFlightUpscaleEntry: @unchecked Sendable {
    var task: Task<Void, Never>?
    var waiters: [UUID: CancellableUpscaleWaiter] = [:]
    var progressHandlers: [UUID: @Sendable (String) -> Void] = [:]
    var lastProgress: String = ""
}

/// 统一页面超分调度器（管理 Anime4K 与 Waifu2x 执行、在途合并与近期显存级缓存）
public final class PageUpscalerPipeline: @unchecked Sendable {
    public static let shared = PageUpscalerPipeline()

    /// 按设备物理内存自适应调整缓存预算（6GB+ 机型 240MB，其余 150MB）
    private static let cacheTotalCostLimit: Int = {
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        return memGB >= 5.5 ? 240 * 1024 * 1024 : 150 * 1024 * 1024
    }()

    /// 单张超分图入内存 L1 缓存的体积上限，避免单张超巨图长期霸占全部内存空间（超限图自动落盘至磁盘 L2 缓存）
    private static let maxSingleCachedImageCost: Int = cacheTotalCostLimit / 2

    /// 磁盘 L2 超分缓存上限（350MB / 180 张，高质量 JPEG 压缩后单张 4x 图仅 ~1.5~3.5MB，可轻松缓存整话来回翻页秒开）
    private static let maxDiskCacheBytes: Int64 = 350 * 1024 * 1024
    private static let maxDiskCacheFileCount: Int = 180
    private static let diskJpegQuality: CGFloat = 0.92

    private let resultCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = PageUpscalerPipeline.cacheTotalCostLimit
        return cache
    }()

    /// 尚未落盘完成的超分图暂存池（保证 3x/4x 大图在异步写盘期间来回翻页也能 0ms 直接命中，落盘后自动释放内存）
    private let diskStateLock = NSLock()
    private var pendingDiskWrites: [String: UIImage] = [:]
    private let diskQueue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.upscaler.diskcache", qos: .utility)
    private let diskCacheDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = caches.appendingPathComponent("UpscaledPagesCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private let inFlightLock = NSLock()
    private var inFlightEntries: [String: InFlightUpscaleEntry] = [:]
    private var memoryWarningObserver: NSObjectProtocol?

    private init() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resultCache.removeAllObjects()
        }
    }

    public func clearCache() {
        resultCache.removeAllObjects()
        diskStateLock.lock()
        pendingDiskWrites.removeAll()
        diskStateLock.unlock()

        let dir = diskCacheDirectory
        diskQueue.async {
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for url in files {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// 同步查询已常驻内存的超分成品图（专供主线程 0ms 快路径使用；同时命中正在异步落盘的 3x/4x 大图）
    public func cachedImage(pageKey: String, config: ImageUpscalerConfig) -> UIImage? {
        let keyString = "\(pageKey)::\(config.cacheKey)"
        if let mem = resultCache.object(forKey: keyString as NSString) {
            return mem
        }
        diskStateLock.lock()
        let pending = pendingDiskWrites[keyString]
        diskStateLock.unlock()
        return pending
    }

    /// 快速探测该页超分成品是否已存在（内存 L1 或磁盘 L2），供预热跳过与进度条热力图使用
    public func hasCachedResult(pageKey: String, config: ImageUpscalerConfig) -> Bool {
        if cachedImage(pageKey: pageKey, config: config) != nil {
            return true
        }
        let keyString = "\(pageKey)::\(config.cacheKey)"
        return FileManager.default.fileExists(atPath: diskFileURL(for: keyString).path)
    }

    /// 预判该图超分结果是否可顺利入缓存（支持内存 L1 + 磁盘 L2，确保 Anime4K AI 2x/3x/4x 全部支持预超分）
    public func canCacheUpscaledOutput(for image: UIImage, config: ImageUpscalerConfig) -> Bool {
        let origSize = pixelSize(of: image)
        let origW = Int(origSize.width)
        let origH = Int(origSize.height)
        guard origW > 0, origH > 0 else { return false }

        let scale = config.outputScaleFactor
        if config.smartSkipMinWidth > 0 && scale > 1 && origW >= config.smartSkipMinWidth {
            return false
        }

        let pixelCount = origW * origH
        let outPixels = pixelCount * scale * scale
        guard outPixels > 0 else { return false }
        if !config.bypassSizeLimit && outPixels > ImageUpscalerConfig.maxOutputPixelCountThreshold {
            return false
        }

        switch config.model {
        case .anime4k:
            // Anime4K 已支持超长单边自动分条无缝拼接，无需拦截单边 > 8192px
            break
        case .anime4kCoreML:
            if min(origW, origH) < Anime4kCoreMLService.minDimension {
                return false
            }
        case .waifu2x:
            if min(origW, origH) < Waifu2xService.minDimension {
                return false
            }
        }

        // 所有合规超分输出均可落盘至磁盘 L2 缓存，不再受单张未压缩 RGBA 内存阈值阻断预超分
        return true
    }

    /// 对漫画单页执行超分（若命中缓存则瞬时返回；若后台正在预热同一页则直接合并承接）
    public func process(
        image: UIImage,
        pageKey: String,
        config: ImageUpscalerConfig,
        isEnabled: Bool = true,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> ProcessedPageImage {
        let origSize = pixelSize(of: image)

        // 1. 全局开关未开启则直接跳过
        guard isEnabled else {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil
            )
        }

        // 2. 智能跳过高清原图（仅对放大倍率 > 1 的模式生效，保留 1x 原尺寸修复功能）
        let origW = Int(origSize.width)
        let origH = Int(origSize.height)
        let scale = config.outputScaleFactor
        if config.smartSkipMinWidth > 0 && scale > 1 && origW >= config.smartSkipMinWidth {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil,
                notice: "原图宽度 \(origW)px 已达高清阈值，已自动跳过超分"
            )
        }

        // 3. 尺寸安全保护：按真实输出总像素上限保护（默认 4800 万输出像素 ≈ 192MB RGBA，等价 2x 时 12M 输入 / 4x 时 3M 输入）
        let outPixelCount = origW * scale * origH * scale
        if !config.bypassSizeLimit {
            guard outPixelCount > 0 && outPixelCount <= ImageUpscalerConfig.maxOutputPixelCountThreshold else {
                let mpText = String(format: "%.1f", Double(outPixelCount) / 1_000_000.0)
                let limitMP = ImageUpscalerConfig.maxOutputPixelCountThreshold / 1_000_000
                return ProcessedPageImage(
                    image: image,
                    originalSize: origSize,
                    outputSize: origSize,
                    elapsedMs: 0,
                    appliedModel: nil,
                    notice: "\(scale)x 输出像素 \(mpText)M 超过默认 \(limitMP)M 上限，已跳过超分"
                )
            }
        }

        let keyString = "\(pageKey)::\(config.cacheKey)"
        let cacheKey = keyString as NSString
        if let cached = cachedImage(pageKey: pageKey, config: config) {
            return ProcessedPageImage(
                image: cached,
                originalSize: origSize,
                outputSize: pixelSize(of: cached),
                elapsedMs: 0,
                appliedModel: config.model,
                notice: "命中缓存"
            )
        }

        // 命中磁盘 L2 缓存：几十毫秒内直接解码复用，避免来回翻页或内存警告后重复跑神经网络超分
        if let diskCached = await loadFromDiskCache(keyString: keyString) {
            guard !Task.isCancelled else {
                return ProcessedPageImage(
                    image: image,
                    originalSize: origSize,
                    outputSize: origSize,
                    elapsedMs: 0,
                    appliedModel: nil,
                    notice: nil
                )
            }
            let outSize = pixelSize(of: diskCached)
            let cost = Int(outSize.width * outSize.height * 4)
            if cost > 0 && cost <= Self.maxSingleCachedImageCost {
                resultCache.setObject(diskCached, forKey: cacheKey, cost: cost)
            }
            return ProcessedPageImage(
                image: diskCached,
                originalSize: origSize,
                outputSize: outSize,
                elapsedMs: 0,
                appliedModel: config.model,
                notice: "命中缓存"
            )
        }

        if Task.isCancelled {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil,
                notice: nil
            )
        }

        let waiterID = UUID()
        let waiter = CancellableUpscaleWaiter()
        let (entry, replayProgress) = registerOrJoinInFlight(
            keyString: keyString,
            cacheKey: cacheKey,
            image: image,
            origSize: origSize,
            config: config,
            waiterID: waiterID,
            waiter: waiter,
            progress: progress
        )

        if !replayProgress.isEmpty {
            progress?(replayProgress)
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            let cancelled = ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil,
                notice: nil
            )
            if waiter.cancel(with: cancelled) {
                self.handleWaiterCancelled(key: keyString, waiterID: waiterID, entry: entry)
            }
        }
    }

    /// 同步锁内登记或复用在途超分任务（严守 Swift @available(*, noasync) 锁规范）
    private func registerOrJoinInFlight(
        keyString: String,
        cacheKey: NSString,
        image: UIImage,
        origSize: CGSize,
        config: ImageUpscalerConfig,
        waiterID: UUID,
        waiter: CancellableUpscaleWaiter,
        progress: (@Sendable (String) -> Void)?
    ) -> (entry: InFlightUpscaleEntry, replayProgress: String) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }

        if let existing = inFlightEntries[keyString] {
            existing.waiters[waiterID] = waiter
            if let progress {
                existing.progressHandlers[waiterID] = progress
            }
            return (existing, existing.lastProgress)
        }

        let newEntry = InFlightUpscaleEntry()
        newEntry.waiters[waiterID] = waiter
        if let progress {
            newEntry.progressHandlers[waiterID] = progress
        }
        inFlightEntries[keyString] = newEntry

        newEntry.task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let result = await self.executeUpscale(
                image: image,
                origSize: origSize,
                cacheKey: cacheKey,
                keyString: keyString,
                config: config,
                entry: newEntry
            )
            self.finishInFlight(key: keyString, entry: newEntry, result: result)
        }
        return (newEntry, "")
    }

    private func executeUpscale(
        image: UIImage,
        origSize: CGSize,
        cacheKey: NSString,
        keyString: String,
        config: ImageUpscalerConfig,
        entry: InFlightUpscaleEntry
    ) async -> ProcessedPageImage {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let enhanced: UIImage
            switch config.model {
            case .anime4k:
                enhanced = try await Anime4kService.shared.enhance(
                    image: image,
                    config: config.anime4k,
                    bypassSizeLimit: config.bypassSizeLimit
                )
            case .anime4kCoreML:
                enhanced = try await Anime4kCoreMLService.shared.enhance(
                    image: image,
                    model: config.anime4kCoreML,
                    bypassSizeLimit: config.bypassSizeLimit,
                    progress: { [weak self] pct in
                        self?.broadcastProgress(pct, entry: entry)
                    }
                )
            case .waifu2x:
                enhanced = try await Waifu2xService.shared.enhance(
                    image: image,
                    model: config.waifu2x,
                    bypassSizeLimit: config.bypassSizeLimit,
                    progress: { [weak self] pct in
                        self?.broadcastProgress(pct, entry: entry)
                    }
                )
            }

            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            let outSize = pixelSize(of: enhanced)
            let cost = Int(outSize.width * outSize.height * 4)
            if cost > 0 && cost <= Self.maxSingleCachedImageCost {
                resultCache.setObject(enhanced, forKey: cacheKey, cost: cost)
            }
            storeToDiskCacheAsync(image: enhanced, keyString: keyString)

            return ProcessedPageImage(
                image: enhanced,
                originalSize: origSize,
                outputSize: outSize,
                elapsedMs: elapsedMs,
                appliedModel: config.model
            )
        } catch is CancellationError {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: elapsedMs,
                appliedModel: nil,
                notice: nil
            )
        } catch {
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: elapsedMs,
                appliedModel: nil,
                notice: error.localizedDescription
            )
        }
    }

    private func broadcastProgress(_ pct: String, entry: InFlightUpscaleEntry) {
        inFlightLock.lock()
        entry.lastProgress = pct
        let handlers = Array(entry.progressHandlers.values)
        inFlightLock.unlock()

        for handler in handlers {
            handler(pct)
        }
    }

    private func finishInFlight(key: String, entry: InFlightUpscaleEntry, result: ProcessedPageImage) {
        inFlightLock.lock()
        if inFlightEntries[key] === entry {
            inFlightEntries.removeValue(forKey: key)
        }
        let waiters = Array(entry.waiters.values)
        entry.waiters.removeAll()
        entry.progressHandlers.removeAll()
        inFlightLock.unlock()

        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func handleWaiterCancelled(key: String, waiterID: UUID, entry: InFlightUpscaleEntry) {
        var taskToCancel: Task<Void, Never>?
        inFlightLock.lock()
        entry.waiters.removeValue(forKey: waiterID)
        entry.progressHandlers.removeValue(forKey: waiterID)
        if entry.waiters.isEmpty {
            if inFlightEntries[key] === entry {
                inFlightEntries.removeValue(forKey: key)
            }
            taskToCancel = entry.task
        }
        inFlightLock.unlock()

        taskToCancel?.cancel()
    }

    // MARK: - 磁盘 L2 持久化缓存（LRU）

    private func diskFileURL(for keyString: String) -> URL {
        let digest = SHA256.hash(data: Data(keyString.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return diskCacheDirectory.appendingPathComponent("\(hex).jpg")
    }

    private func loadFromDiskCache(keyString: String) async -> UIImage? {
        let fileURL = diskFileURL(for: keyString)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            diskQueue.async {
                autoreleasepool {
                    guard let data = try? Data(contentsOf: fileURL),
                          let img = UIImage(data: data) else {
                        try? FileManager.default.removeItem(at: fileURL)
                        continuation.resume(returning: nil)
                        return
                    }
                    // 刷新修改时间作为 LRU 最近访问标记
                    try? FileManager.default.setAttributes(
                        [.modificationDate: Date()],
                        ofItemAtPath: fileURL.path
                    )
                    continuation.resume(returning: img)
                }
            }
        }
    }

    private func storeToDiskCacheAsync(image: UIImage, keyString: String) {
        diskStateLock.lock()
        pendingDiskWrites[keyString] = image
        diskStateLock.unlock()

        let fileURL = diskFileURL(for: keyString)
        let dir = diskCacheDirectory
        let quality = Self.diskJpegQuality
        let maxBytes = Self.maxDiskCacheBytes
        let maxCount = Self.maxDiskCacheFileCount

        diskQueue.async { [weak self] in
            autoreleasepool {
                let fm = FileManager.default
                if !fm.fileExists(atPath: dir.path) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                if let jpegData = image.jpegData(compressionQuality: quality) {
                    try? jpegData.write(to: fileURL, options: .atomic)
                    Self.trimDiskCacheIfNeeded(in: dir, maxBytes: maxBytes, maxCount: maxCount)
                }
            }
            guard let self else { return }
            self.diskStateLock.lock()
            if self.pendingDiskWrites[keyString] === image {
                self.pendingDiskWrites.removeValue(forKey: keyString)
            }
            self.diskStateLock.unlock()
        }
    }

    private static func trimDiskCacheIfNeeded(in directory: URL, maxBytes: Int64, maxCount: Int) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        var entries: [(url: URL, size: Int64, mtime: Date)] = []
        entries.reserveCapacity(urls.count)
        var totalSize: Int64 = 0

        for url in urls {
            guard let vals = try? url.resourceValues(forKeys: keys) else { continue }
            let size = Int64(vals.fileSize ?? 0)
            let mtime = vals.contentModificationDate ?? .distantPast
            entries.append((url, size, mtime))
            totalSize += size
        }

        guard totalSize > maxBytes || entries.count > maxCount else { return }

        entries.sort { $0.mtime < $1.mtime }
        var remainingCount = entries.count
        for entry in entries {
            if totalSize <= maxBytes && remainingCount <= maxCount {
                break
            }
            try? fm.removeItem(at: entry.url)
            totalSize -= entry.size
            remainingCount -= 1
        }
    }

    private func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            switch image.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                return CGSize(width: cg.height, height: cg.width)
            default:
                return CGSize(width: cg.width, height: cg.height)
            }
        }
        return CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    }
}
