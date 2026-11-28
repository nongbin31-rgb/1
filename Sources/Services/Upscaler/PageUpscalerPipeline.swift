import CryptoKit
import Darwin
import Foundation
import UIKit

/// 跨引擎取消感知互斥等待盒子（保证排队取消与获锁移交绝不重复 resume 或泄漏锁计数）
private final class UpscalerGateWaiter: @unchecked Sendable {
    private enum State {
        case pending
        case registered(CheckedContinuation<Bool, Never>)
        case resolved(Bool)
    }

    private let lock = NSLock()
    private var state: State = .pending

    func attach(_ continuation: CheckedContinuation<Bool, Never>) {
        var immediate: Bool?
        lock.lock()
        switch state {
        case .pending:
            state = .registered(continuation)
        case .resolved(let granted):
            immediate = granted
        case .registered:
            break
        }
        lock.unlock()

        if let immediate {
            continuation.resume(returning: immediate)
        }
    }

    /// 尝试把执行权移交给当前等待者；若其已被取消则返回 false，由调度器顺延给下一位
    func grant() -> Bool {
        var contToResume: CheckedContinuation<Bool, Never>?
        var granted = false
        lock.lock()
        switch state {
        case .pending:
            state = .resolved(true)
            granted = true
        case .registered(let cont):
            state = .resolved(true)
            contToResume = cont
            granted = true
        case .resolved:
            granted = false
        }
        lock.unlock()

        contToResume?.resume(returning: true)
        return granted
    }

    /// 尝试取消排队等待；仅当尚未获锁时返回 true
    func cancel() -> Bool {
        var contToResume: CheckedContinuation<Bool, Never>?
        var didCancel = false
        lock.lock()
        switch state {
        case .pending:
            state = .resolved(false)
            didCancel = true
        case .registered(let cont):
            state = .resolved(false)
            contToResume = cont
            didCancel = true
        case .resolved:
            didCancel = false
        }
        lock.unlock()

        contToResume?.resume(returning: false)
        return didCancel
    }
}

/// 超分运行时安全错误（用于统一拦截后台 GPU 提交、可用内存不足及硬件尺寸天花板）
public enum UpscalerSafetyError: LocalizedError {
    case backgroundRestricted
    case dimensionOverflow(width: Int, height: Int, scale: Int)
    case exceedsOutputLimit(width: Int, height: Int, scale: Int, limitPixels: Int, isHardLimit: Bool)
    case insufficientMemory(requiredMB: Int, availableMB: Int)

    public var errorDescription: String? {
        switch self {
        case .backgroundRestricted:
            return "应用已切换至后台，已安全暂停超分"
        case let .dimensionOverflow(w, h, scale):
            return "目标输出尺寸超出硬件安全上限 (\(w * scale)×\(h * scale))，已跳过超分"
        case let .exceedsOutputLimit(w, h, scale, limitPixels, isHardLimit):
            let outMP = String(format: "%.1f", Double(w) * Double(scale) * Double(h) * Double(scale) / 1_000_000.0)
            let limitMP = limitPixels / 1_000_000
            if isHardLimit {
                return "\(scale)x 输出像素约 \(outMP)M，超过设备硬件安全上限 \(limitMP)M，已跳过超分以防重启"
            }
            return "\(scale)x 输出像素约 \(outMP)M，超过安全保护上限 \(limitMP)M，已跳过超分"
        case let .insufficientMemory(requiredMB, availableMB):
            return "当前设备可用内存不足（剩余约 \(availableMB)MB，需约 \(requiredMB)MB），已跳过超分以防闪退"
        }
    }
}

/// 全局超分运行时安全守卫：
/// 1. 监听应用前后台与非活跃状态，严禁后台提交 Metal / CoreML(ANE) 计算，杜绝内核强杀与驱动重启；
/// 2. 提供跨三引擎（Anime4K Metal / Anime4K AI / Waifu2x，含预览页）统一互斥执行门闩；
/// 3. 实时探测 `os_proc_available_memory()` 剩余进程内存并做防溢出维度校验，在内存触顶前安全降级；
/// 4. 统一联动内存警告广播，第一时间清理缓存与模型权重。
public final class UpscalerRuntimeGuard: @unchecked Sendable {
    public static let shared = UpscalerRuntimeGuard()

    private typealias ProcAvailableMemoryFn = @convention(c) () -> Int
    private static let procAvailableMemoryFn: ProcAvailableMemoryFn? = {
        // RTLD_DEFAULT 在 Darwin 平台固定为 -2，免头文件依赖兼容 Xcode 16 (Swift 5.9) 与 Xcode 26 (Swift 6)
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(handle, "os_proc_available_memory") else {
            return nil
        }
        return unsafeBitCast(sym, to: ProcAvailableMemoryFn.self)
    }()

    /// 给系统 WindowServer / CoreAnimation / UIKit 预留的最低安全内存余量（字节）
    private static let safetyHeadroomBytes: Int = {
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        return memGB >= 5.5 ? 200 * 1024 * 1024 : 150 * 1024 * 1024
    }()

    private let stateLock = NSLock()
    private var appInactiveOrBackground: Bool = false
    private var memoryWarningCooldownUntil: Date?
    private var activeCancelCallbacks: [UUID: @Sendable () -> Void] = [:]

    private let gateLock = NSLock()
    private var isGateBusy: Bool = false
    private var gateWaiters: [(id: UUID, waiter: UpscalerGateWaiter)] = []

    private var observers: [NSObjectProtocol] = []

    private init() {
        Task { @MainActor [weak self] in
            let state = UIApplication.shared.applicationState
            if state == .background || state == .inactive {
                self?.setAppInactiveOrBackground(true)
            }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setAppInactiveOrBackground(true)
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setAppInactiveOrBackground(true)
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.setAppInactiveOrBackground(false)
        })
        observers.append(nc.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        })
    }

    /// 当前是否允许提交 GPU (Metal / CoreImage) 或 ANE (CoreML) 任务
    public var isGPUExecutionPermitted: Bool {
        stateLock.lock()
        let blocked = appInactiveOrBackground
        stateLock.unlock()
        return !blocked
    }

    /// 是否处于系统内存警告后的短暂冷却保护期（期间暂停后台预热并收紧重算）
    public var isInMemoryWarningCooldown: Bool {
        stateLock.lock()
        let until = memoryWarningCooldownUntil
        stateLock.unlock()
        if let until {
            return Date() < until
        }
        return false
    }

    /// 查询当前进程距离 Jetsam 红线的真实可用内存（字节；不可用时返回 nil）
    public func availableProcessMemoryBytes() -> Int? {
        guard let fn = Self.procAvailableMemoryFn else { return nil }
        let bytes = fn()
        return bytes > 0 ? bytes : nil
    }

    /// 注册在途 GPU/ANE 任务的即时中止回调（App 进入非活跃/后台时立即触发，防止继续提交命令）
    public func registerActiveCancellation(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        var shouldCancelImmediately = false
        stateLock.lock()
        if appInactiveOrBackground {
            shouldCancelImmediately = true
        } else {
            activeCancelCallbacks[token] = handler
        }
        stateLock.unlock()

        if shouldCancelImmediately {
            handler()
        }
        return token
    }

    public func unregisterActiveCancellation(_ token: UUID) {
        stateLock.lock()
        activeCancelCallbacks.removeValue(forKey: token)
        stateLock.unlock()
    }

    /// 校验输出尺寸与当前真实可用内存是否安全，防止防溢出崩溃、拉爆 WindowServer 或整机重启
    public func validateMemoryAndDimensions(
        width: Int,
        height: Int,
        scale: Int,
        bypassSizeLimit: Bool,
        workingOverheadBytes: Int = 96 * 1024 * 1024
    ) throws -> (targetWidth: Int, targetHeight: Int, targetBytes: Int) {
        guard width > 0, height > 0, scale > 0 else {
            throw UpscalerSafetyError.dimensionOverflow(width: max(width, 0), height: max(height, 0), scale: max(scale, 1))
        }

        let (targetW, overflowW) = width.multipliedReportingOverflow(by: scale)
        let (targetH, overflowH) = height.multipliedReportingOverflow(by: scale)
        guard !overflowW, !overflowH,
              targetW > 0, targetH > 0,
              targetW <= ImageUpscalerConfig.hardMaxOutputDimension,
              targetH <= ImageUpscalerConfig.hardMaxOutputDimension else {
            throw UpscalerSafetyError.dimensionOverflow(width: width, height: height, scale: scale)
        }

        let (outPixels, overflowPixels) = targetW.multipliedReportingOverflow(by: targetH)
        guard !overflowPixels, outPixels > 0 else {
            throw UpscalerSafetyError.dimensionOverflow(width: width, height: height, scale: scale)
        }

        let softLimit = ImageUpscalerConfig.maxOutputPixelCountThreshold
        let hardLimit = ImageUpscalerConfig.hardMaxOutputPixelCount
        if !bypassSizeLimit && outPixels > softLimit {
            throw UpscalerSafetyError.exceedsOutputLimit(
                width: width,
                height: height,
                scale: scale,
                limitPixels: softLimit,
                isHardLimit: false
            )
        }
        if outPixels > hardLimit {
            throw UpscalerSafetyError.exceedsOutputLimit(
                width: width,
                height: height,
                scale: scale,
                limitPixels: hardLimit,
                isHardLimit: true
            )
        }

        let (targetBytes, overflowBytes) = outPixels.multipliedReportingOverflow(by: 4)
        guard !overflowBytes, targetBytes > 0 else {
            throw UpscalerSafetyError.dimensionOverflow(width: width, height: height, scale: scale)
        }

        // 实时可用内存核查：需同时容纳 CPU 输出缓冲 + WindowServer/写盘 副本 + 运行时工作显存 + 系统安全余量
        if let available = availableProcessMemoryBytes() {
            let estimatedNeed = targetBytes * 2 + workingOverheadBytes + Self.safetyHeadroomBytes
            if available < estimatedNeed {
                let reqMB = max(1, (targetBytes * 2 + workingOverheadBytes) / (1024 * 1024))
                let availMB = max(0, available / (1024 * 1024))
                throw UpscalerSafetyError.insufficientMemory(requiredMB: reqMB, availableMB: availMB)
            }
        }

        return (targetW, targetH, targetBytes)
    }

    /// 获取跨三引擎全局唯一互斥执行槽位（支持排队期间响应 Task.cancel，需与 releaseExclusiveSlot() 成对使用）
    public func acquireExclusiveSlot() async -> Bool {
        if Task.isCancelled || !isGPUExecutionPermitted {
            return false
        }
        let acquired = await acquireGate()
        guard acquired else {
            return false
        }
        if Task.isCancelled || !isGPUExecutionPermitted {
            releaseGate()
            return false
        }
        return true
    }

    /// 释放跨三引擎全局唯一互斥执行槽位
    public func releaseExclusiveSlot() {
        releaseGate()
    }

    private func acquireGate() async -> Bool {
        if tryAcquireGateImmediately() {
            return true
        }
        if Task.isCancelled || !isGPUExecutionPermitted {
            return false
        }

        let waiterID = UUID()
        let waiter = UpscalerGateWaiter()
        let immediateGrant = enqueueGateWaiter(id: waiterID, waiter: waiter)
        if immediateGrant {
            return true
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.attach(continuation)
            }
        } onCancel: {
            if waiter.cancel() {
                self.removeGateWaiter(id: waiterID)
            }
        }
    }

    private func tryAcquireGateImmediately() -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        if !isGateBusy {
            isGateBusy = true
            return true
        }
        return false
    }

    private func enqueueGateWaiter(id: UUID, waiter: UpscalerGateWaiter) -> Bool {
        gateLock.lock()
        defer { gateLock.unlock() }
        if !isGateBusy {
            isGateBusy = true
            return true
        }
        gateWaiters.append((id: id, waiter: waiter))
        return false
    }

    private func removeGateWaiter(id: UUID) {
        gateLock.lock()
        gateWaiters.removeAll { $0.id == id }
        gateLock.unlock()
    }

    private func releaseGate() {
        while true {
            gateLock.lock()
            if gateWaiters.isEmpty {
                isGateBusy = false
                gateLock.unlock()
                return
            }
            let next = gateWaiters.removeFirst()
            gateLock.unlock()

            if next.waiter.grant() {
                return
            }
        }
    }

    private func setAppInactiveOrBackground(_ inactive: Bool) {
        var callbacksToInvoke: [@Sendable () -> Void] = []
        stateLock.lock()
        let wasInactive = appInactiveOrBackground
        appInactiveOrBackground = inactive
        if inactive && !wasInactive {
            callbacksToInvoke = Array(activeCancelCallbacks.values)
            activeCancelCallbacks.removeAll()
        }
        stateLock.unlock()

        if !callbacksToInvoke.isEmpty {
            for cb in callbacksToInvoke {
                cb()
            }
        }
    }

    private func handleMemoryWarning() {
        stateLock.lock()
        memoryWarningCooldownUntil = Date().addingTimeInterval(20)
        stateLock.unlock()

        // 统一联动释放全部超分模型、Metal 管线与原图内存缓存
        Anime4kCoreMLService.shared.clearModelCache()
        Waifu2xService.shared.clearModelCache()
        Task {
            await Anime4kService.shared.clearPipelineCache()
            await OnlineImageLoader.shared.clearMemoryCache()
        }
    }
}

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

    /// 按设备物理内存自适应调整 L1 内存缓存预算（6GB+ 机型 160MB，4GB 机型 96MB，其余 64MB）
    private static let cacheTotalCostLimit: Int = {
        let memGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        if memGB >= 5.5 {
            return 160 * 1024 * 1024
        } else if memGB >= 3.5 {
            return 96 * 1024 * 1024
        } else {
            return 64 * 1024 * 1024
        }
    }()

    /// 单张超分图入内存 L1 缓存的体积上限，避免单张超巨图长期霸占全部内存空间（超限图自动落盘至磁盘 L2 缓存）
    private static let maxSingleCachedImageCost: Int = cacheTotalCostLimit / 2

    /// 异步写盘队列允许强持有的最大暂存图片数，杜绝快速连续翻页时百兆大图在内存中无限积压
    private static let maxPendingDiskWrites: Int = 2

    /// 磁盘 L2 超分缓存上限（350MB / 180 张，高质量 JPEG 压缩后单张 4x 图仅 ~1.5~3.5MB，可轻松缓存整话来回翻页秒开）
    private static let maxDiskCacheBytes: Int64 = 350 * 1024 * 1024
    private static let maxDiskCacheFileCount: Int = 180
    private static let diskJpegQuality: CGFloat = 0.92

    private let resultCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        cache.totalCostLimit = PageUpscalerPipeline.cacheTotalCostLimit
        return cache
    }()

    /// 尚未落盘完成的超分图有限暂存池（上限 2 张；收到内存警告时立即清空并作废队列中尚未开始的写盘）
    private let diskStateLock = NSLock()
    private var pendingDiskWrites: [String: UIImage] = [:]
    private var pendingDiskWriteOrder: [String] = []
    private var diskWriteGeneration: UInt64 = 0
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
        // 确保全局前后台 GPU/ANE 门禁与内存警告联动器第一时间完成注册
        _ = UpscalerRuntimeGuard.shared

        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleMemoryWarning()
        }
    }

    private func handleMemoryWarning() {
        resultCache.removeAllObjects()
        diskStateLock.lock()
        diskWriteGeneration &+= 1
        pendingDiskWrites.removeAll()
        pendingDiskWriteOrder.removeAll()
        diskStateLock.unlock()
    }

    public func clearCache() {
        resultCache.removeAllObjects()
        diskStateLock.lock()
        diskWriteGeneration &+= 1
        pendingDiskWrites.removeAll()
        pendingDiskWriteOrder.removeAll()
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

        guard (try? UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
            width: origW,
            height: origH,
            scale: scale,
            bypassSizeLimit: config.bypassSizeLimit
        )) != nil else {
            return false
        }

        switch config.model {
        case .anime4k:
            // Anime4K 已支持安全重叠瓦片分块拼接，无需拦截单边 > 8192px
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

        // 1.5 非活跃/后台状态严禁启动 GPU/ANE 超分（但仍允许命中已有缓存）
        let origW = Int(origSize.width)
        let origH = Int(origSize.height)
        let scale = config.outputScaleFactor

        // 2. 智能跳过高清原图（仅对放大倍率 > 1 的模式生效，保留 1x 原尺寸修复功能）
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

        // 3. 防溢出尺寸保护 + 硬件天花板 + 实时可用内存守卫
        do {
            _ = try UpscalerRuntimeGuard.shared.validateMemoryAndDimensions(
                width: origW,
                height: origH,
                scale: scale,
                bypassSizeLimit: config.bypassSizeLimit
            )
        } catch {
            return ProcessedPageImage(
                image: image,
                originalSize: origSize,
                outputSize: origSize,
                elapsedMs: 0,
                appliedModel: nil,
                notice: error.localizedDescription
            )
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

        if Task.isCancelled || !UpscalerRuntimeGuard.shared.isGPUExecutionPermitted {
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
                    bypassSizeLimit: config.bypassSizeLimit,
                    progress: { [weak self] pct in
                        self?.broadcastProgress(pct, entry: entry)
                    }
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
        let expectedGen = diskWriteGeneration
        pendingDiskWrites[keyString] = image
        pendingDiskWriteOrder.removeAll { $0 == keyString }
        pendingDiskWriteOrder.append(keyString)
        while pendingDiskWriteOrder.count > Self.maxPendingDiskWrites {
            let oldestKey = pendingDiskWriteOrder.removeFirst()
            pendingDiskWrites.removeValue(forKey: oldestKey)
        }
        diskStateLock.unlock()

        let fileURL = diskFileURL(for: keyString)
        let dir = diskCacheDirectory
        let quality = Self.diskJpegQuality
        let maxBytes = Self.maxDiskCacheBytes
        let maxCount = Self.maxDiskCacheFileCount

        diskQueue.async { [weak self] in
            guard let self else { return }

            // 内存警告已触发、或该图已因连续高速翻页被新图挤出暂存窗口，直接跳过耗时的 JPEG 编码以防堆内存积压
            self.diskStateLock.lock()
            let stillValid = (self.diskWriteGeneration == expectedGen) && (self.pendingDiskWrites[keyString] === image)
            self.diskStateLock.unlock()

            if stillValid {
                // 若当前可用内存已偏紧，主动放弃写盘以避免 JPEG 编码临时缓冲引发 OOM
                let hasEnoughMemoryForEncode: Bool
                if let avail = UpscalerRuntimeGuard.shared.availableProcessMemoryBytes() {
                    hasEnoughMemoryForEncode = avail >= 180 * 1024 * 1024
                } else {
                    hasEnoughMemoryForEncode = true
                }

                if hasEnoughMemoryForEncode {
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
                }
            }

            self.diskStateLock.lock()
            if self.pendingDiskWrites[keyString] === image {
                self.pendingDiskWrites.removeValue(forKey: keyString)
                self.pendingDiskWriteOrder.removeAll { $0 == keyString }
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
