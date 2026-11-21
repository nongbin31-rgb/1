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

/// 统一页面超分调度器（对齐可达阅读器：管理 Anime4K 与 Waifu2x 执行、在途合并与近期显存级缓存）
public final class PageUpscalerPipeline: @unchecked Sendable {
    public static let shared = PageUpscalerPipeline()

    /// 按设备物理内存自适应调整缓存预算（6GB+ 机型 240MB，其余 150MB）
    private static let cacheTotalCostLimit: Int = {
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        return memGB >= 5.5 ? 240 * 1024 * 1024 : 150 * 1024 * 1024
    }()

    /// 单张超分图入缓存的体积上限，避免单张超巨图长期霸占全部缓存空间
    private static let maxSingleCachedImageCost: Int = cacheTotalCostLimit / 2

    private let resultCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = PageUpscalerPipeline.cacheTotalCostLimit
        return cache
    }()

    private let inFlightLock = NSLock()
    private var inFlightEntries: [String: InFlightUpscaleEntry] = [:]

    private init() {}

    public func clearCache() {
        resultCache.removeAllObjects()
    }

    /// 同步查询已缓存的超分成品图（专供主线程快路径与预热跳过检查使用）
    public func cachedImage(pageKey: String, config: ImageUpscalerConfig) -> UIImage? {
        let cacheKey = "\(pageKey)::\(config.cacheKey)" as NSString
        return resultCache.object(forKey: cacheKey)
    }

    /// 预判该图 2x 超分结果是否可顺利入缓存（避免后台预热为超限/不可缓存的巨图白耗算力）
    public func canCacheUpscaledOutput(for image: UIImage, config: ImageUpscalerConfig) -> Bool {
        let origSize = pixelSize(of: image)
        let origW = Int(origSize.width)
        let origH = Int(origSize.height)
        guard origW > 0, origH > 0 else { return false }

        let pixelCount = origW * origH
        if !config.bypassSizeLimit && pixelCount > ImageUpscalerConfig.maxPixelCountThreshold {
            return false
        }

        switch config.model {
        case .anime4k:
            if max(origW, origH) > ImageUpscalerConfig.maxMetalInputDimension {
                return false
            }
        case .waifu2x:
            if min(origW, origH) < Waifu2xService.minDimension {
                return false
            }
        }

        // 2x 超分后 RGBA8 显存占用（width * 2 * height * 2 * 4 = pixelCount * 16）
        let estimatedCost = pixelCount * 16
        return estimatedCost > 0 && estimatedCost <= Self.maxSingleCachedImageCost
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

        // 2. 尺寸安全保护：默认采用 1200 万总像素上限（兼容 800×8000 等条漫长图），用户开启「解除超分尺寸限制」后跳过软件限制
        let origW = Int(origSize.width)
        let origH = Int(origSize.height)
        let pixelCount = origW * origH
        if !config.bypassSizeLimit {
            guard pixelCount <= ImageUpscalerConfig.maxPixelCountThreshold else {
                let mpText = String(format: "%.1f", Double(pixelCount) / 1_000_000.0)
                let limitMP = ImageUpscalerConfig.maxPixelCountThreshold / 1_000_000
                return ProcessedPageImage(
                    image: image,
                    originalSize: origSize,
                    outputSize: origSize,
                    elapsedMs: 0,
                    appliedModel: nil,
                    notice: "总像素 \(mpText)M 超过默认 \(limitMP)M 上限，已跳过超分"
                )
            }
        }

        let keyString = "\(pageKey)::\(config.cacheKey)"
        let cacheKey = keyString as NSString
        if let cached = resultCache.object(forKey: cacheKey) {
            return ProcessedPageImage(
                image: cached,
                originalSize: origSize,
                outputSize: pixelSize(of: cached),
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
