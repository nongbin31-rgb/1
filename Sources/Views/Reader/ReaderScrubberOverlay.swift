import SwiftUI
import UIKit

// MARK: - 精细调速倍率与缓存健康状态模型

/// 进度条纵向拉离时的精细调速档位
enum ReaderScrubSpeed: Equatable {
    case fast
    case medium
    case fine

    var scale: Double {
        switch self {
        case .fast:   return 1.0
        case .medium: return 0.35
        case .fine:   return 0.12
        }
    }

    var label: String {
        switch self {
        case .fast:   return "常规寻页 · 上拉更慢精调"
        case .medium: return "中速微调 (0.35x)"
        case .fine:   return "逐页精调 (0.12x)"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .fast:   return .white
        case .medium: return .yellow
        case .fine:   return .green
        }
    }

    /// 速度自适应阻尼：慢速寻页时自动施加平滑减速（长章节尤其明显），快速大幅拉动时顺滑恢复全速跨页
    func dampedDeltaPages(
        dx: CGFloat,
        usableWidth: CGFloat,
        maxIndex: Int,
        isRightToLeft: Bool
    ) -> Double {
        guard usableWidth > 0, maxIndex > 0 else { return 0 }
        let absDx = abs(dx)
        let longChapterFactor: Double = maxIndex > 40
            ? max(0.36, 1.0 - min(Double(maxIndex - 40) / 240.0, 0.64))
            : 0.72
        let u = Double(min(max((absDx - 1.2) / 9.5, 0.0), 1.0))
        let smoothBlend = u * u * (3.0 - 2.0 * u)
        let adaptiveMultiplier = longChapterFactor + (1.0 - longChapterFactor) * smoothBlend

        let deltaRatio = Double(dx / usableWidth)
        let signedRatio = isRightToLeft ? -deltaRatio : deltaRatio
        return signedRatio * Double(maxIndex) * scale * adaptiveMultiplier
    }
}

/// 进度条话数徽标格式化（多话连载显示 "3/24话"，单话作品返回 nil 避免冗余）
private func formatCompactChapterBadge(chapterIndex: Int?, totalChapters: Int) -> String? {
    guard totalChapters > 1, let idx = chapterIndex, idx >= 0, idx < totalChapters else {
        return nil
    }
    return "\(idx + 1)/\(totalChapters)话"
}

/// 单页缓存与 AI 超分就绪状态
enum ReaderPageHealthStatus: Equatable, Sendable {
    case remote
    case cached
    case upscaled
}

/// 异步扫描章节缓存与超分状态快照（避免拖动滑块期间在主线程频繁访问磁盘缓存）
@MainActor
final class ReaderPageCacheSnapshotStore: ObservableObject {
    @Published private(set) var statuses: [ReaderPageHealthStatus] = []

    private var refreshTask: Task<Void, Never>?

    func refresh(
        pages: [MangaPage],
        enableUpscaler: Bool,
        upscalerConfig: ImageUpscalerConfig
    ) {
        refreshTask?.cancel()
        guard !pages.isEmpty else {
            statuses = []
            return
        }

        let capturedPages = pages
        refreshTask = Task.detached(priority: .utility) {
            let count = capturedPages.count
            // 超长章节抽样步长控制，单次扫描不超过 120 次磁盘状态探测
            let strideStep = max(1, count / 120)
            var result = [ReaderPageHealthStatus](repeating: .remote, count: count)

            var idx = 0
            while idx < count {
                if Task.isCancelled { return }
                let page = capturedPages[idx]
                let status: ReaderPageHealthStatus
                if enableUpscaler && PageUpscalerPipeline.shared.hasCachedResult(pageKey: page.imageURL, config: upscalerConfig) {
                    status = .upscaled
                } else if OnlineImageLoader.shared.hasCachedImage(for: page.imageURL) {
                    status = .cached
                } else {
                    status = .remote
                }

                let fillEnd = min(count, idx + strideStep)
                for fillIdx in idx..<fillEnd {
                    result[fillIdx] = status
                }
                idx += strideStep
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.statuses = result
            }
        }
    }

    func status(at pageIndex: Int) -> ReaderPageHealthStatus {
        guard statuses.indices.contains(pageIndex) else { return .remote }
        return statuses[pageIndex]
    }

    /// 聚合成最多 bucketCount 个热力分段桶（优先级：upscaled > cached > remote）
    func bucketStatuses(totalPages: Int, bucketCount: Int) -> [ReaderPageHealthStatus] {
        let safeBuckets = max(1, min(totalPages, bucketCount))
        guard totalPages > 0 else { return [] }

        var buckets = [ReaderPageHealthStatus](repeating: .remote, count: safeBuckets)
        for b in 0..<safeBuckets {
            let start = (b * totalPages) / safeBuckets
            let end = max(start + 1, ((b + 1) * totalPages) / safeBuckets)
            var best: ReaderPageHealthStatus = .remote
            for p in start..<min(end, totalPages) {
                let s = status(at: p)
                if s == .upscaled {
                    best = .upscaled
                    break
                } else if s == .cached {
                    best = .cached
                }
            }
            buckets[b] = best
        }
        return buckets
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

// MARK: - 设备环境信息状态（沉浸微晶胶囊所需：实时系统时钟、电池电量与充电状态）

@MainActor
public final class ReaderDeviceInfoStore: ObservableObject {
    public static let shared = ReaderDeviceInfoStore()

    @Published public private(set) var timeString: String = ""
    @Published public private(set) var batteryPercentage: Int = 100
    @Published public private(set) var isCharging: Bool = false

    private var timer: Timer?
    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateDeviceInfo()
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDeviceInfo()
        }
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateDeviceInfo()
        }
    }

    public func startMonitoring() {
        updateDeviceInfo()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.updateDeviceInfo()
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func updateDeviceInfo() {
        timeString = timeFormatter.string(from: Date())
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            batteryPercentage = min(100, max(0, Int((level * 100).rounded())))
        }
        let state = UIDevice.current.batteryState
        isCharging = (state == .charging || state == .full)
    }

    public var batteryIconName: String {
        if isCharging {
            return "battery.100.bolt"
        }
        switch batteryPercentage {
        case 75...100: return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        case 10..<25:  return "battery.25"
        default:       return "battery.0"
        }
    }
}

// MARK: - 1. 操控态底部进度条调度容器（5 套风格统一接口）

struct ReaderActiveProgressBar: View {
    let style: ReaderProgressStyle
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    let cacheStatuses: ReaderPageCacheSnapshotStore
    var chapterIndex: Int? = nil
    var totalChapters: Int = 1
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onSpeedChanged: (ReaderScrubSpeed) -> Void
    let onScrubEnd: (Int) -> Void

    private var activeFraction: Double {
        let maxIdx = Double(max(totalPages - 1, 1))
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), maxIdx)
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    private var chapterBadge: String? {
        formatCompactChapterBadge(chapterIndex: chapterIndex, totalChapters: totalChapters)
    }

    var body: some View {
        switch style {
        case .edgeDock:
            ReaderScrubberTrackBar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                isScrubbing: isScrubbing,
                scrubFraction: scrubFraction,
                isRightToLeft: isRightToLeft,
                originAnchorIndex: originAnchorIndex,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onSpeedChanged: onSpeedChanged,
                onScrubEnd: onScrubEnd
            )
        case .foreEdge:
            ReaderForeEdgeActiveBar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                isScrubbing: isScrubbing,
                scrubFraction: scrubFraction,
                isRightToLeft: isRightToLeft,
                originAnchorIndex: originAnchorIndex,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onScrubEnd: onScrubEnd
            )
        case .vernierDial:
            ReaderVernierDialActiveBar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                isScrubbing: isScrubbing,
                scrubFraction: scrubFraction,
                isRightToLeft: isRightToLeft,
                cacheStatuses: cacheStatuses,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onScrubEnd: onScrubEnd
            )
        case .sideRail:
            sideRailSummaryRow
        case .heatmapSeg:
            ReaderHeatmapActiveBar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                isScrubbing: isScrubbing,
                scrubFraction: scrubFraction,
                isRightToLeft: isRightToLeft,
                originAnchorIndex: originAnchorIndex,
                cacheStatuses: cacheStatuses,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onScrubEnd: onScrubEnd
            )
        case .microCapsule:
            ReaderMicroCapsuleActiveBar(
                totalPages: totalPages,
                currentPageIndex: currentPageIndex,
                isScrubbing: isScrubbing,
                scrubFraction: scrubFraction,
                isRightToLeft: isRightToLeft,
                originAnchorIndex: originAnchorIndex,
                cacheStatuses: cacheStatuses,
                chapterIndex: chapterIndex,
                totalChapters: totalChapters,
                onScrubBegin: onScrubBegin,
                onScrubChanged: onScrubChanged,
                onSpeedChanged: onSpeedChanged,
                onScrubEnd: onScrubEnd
            )
        }
    }

    private var sideRailSummaryRow: some View {
        let maxIdx = max(totalPages - 1, 1)
        let pct = Int(((Double(displayedPageIndex) / Double(maxIdx)) * 100).rounded())
        return HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                if let chapterBadge {
                    Text(chapterBadge)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.82))
                    Text("·")
                        .font(.caption.bold())
                        .foregroundStyle(.white.opacity(0.45))
                }
                Text("第 \(displayedPageIndex + 1) / \(totalPages) 页")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text("· \(pct)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.68))
            }

            Spacer()

            Text("拖动右侧纵轨寻页")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.10), in: Capsule())
        .frame(height: 36)
    }
}

// MARK: - 风格 6：沉浸微晶胶囊激活态控制舱（大字页码指示 + 缓存感知槽底 + 纵向拉离精调 + 原位回弹锚点）

struct ReaderMicroCapsuleActiveBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    let cacheStatuses: ReaderPageCacheSnapshotStore
    var chapterIndex: Int? = nil
    var totalChapters: Int = 1
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onSpeedChanged: (ReaderScrubSpeed) -> Void
    let onScrubEnd: (Int) -> Void

    @State private var isDragging = false
    @State private var lastTranslationX: CGFloat = 0
    @State private var currentFraction: Double = 0
    @State private var activeSpeed: ReaderScrubSpeed = .fast
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    private var maxIndex: Int {
        max(totalPages - 1, 1)
    }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    private var chapterBadge: String? {
        formatCompactChapterBadge(chapterIndex: chapterIndex, totalChapters: totalChapters)
    }

    var body: some View {
        let pct = Int(((Double(displayedPageIndex) / Double(maxIndex)) * 100).rounded())
        VStack(spacing: 6) {
            // 顶层：大字等宽微晶指示条与回弹锚点
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.white.opacity(isScrubbing ? 0.95 : 0.65))
                        .frame(width: 5.5, height: 5.5)
                        .scaleEffect(isScrubbing ? 1.3 : 1.0)
                        .animation(.easeInOut(duration: 0.2), value: isScrubbing)
                    if let chapterBadge {
                        Text(chapterBadge)
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                        Text("·")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Text("第 \(displayedPageIndex + 1) / \(totalPages) 页")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("· \(pct)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .liquidGlassCapsule()
                .environment(\.colorScheme, .dark)

                Spacer()

                if let anchor = originAnchorIndex, abs(displayedPageIndex - anchor) > 4 {
                    Button {
                        onScrubEnd(anchor)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9.5, weight: .bold))
                            Text("回 P\(anchor + 1)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(.white)
                        .liquidGlassCapsule(interactive: true)
                        .environment(\.colorScheme, .dark)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }

            // 中层：触控滑轨
            trackCanvas
                .frame(height: 32)
        }
    }

    private var trackCanvas: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = geo.size.height
            let thumbDiameter: CGFloat = isScrubbing ? 24 : 18
            let thumbRadius = thumbDiameter * 0.5
            let usableWidth = max(width - thumbDiameter, 1)

            let logicalRatio = CGFloat(activeFraction / Double(maxIndex))
            let visualRatio = isRightToLeft ? (1.0 - logicalRatio) : logicalRatio
            let thumbCenterX = thumbRadius + visualRatio * usableWidth
            let trackHeight: CGFloat = isScrubbing ? 7.5 : 5.5

            ZStack(alignment: .leading) {
                // 透明扩展触摸感应热区
                Color.clear
                    .contentShape(Rectangle())

                // 槽底多段缓存微槽（去除蓝色进度条，保持通透极简轨道）
                let bucketCount = min(totalPages, 36)
                let buckets = cacheStatuses.bucketStatuses(totalPages: totalPages, bucketCount: bucketCount)
                HStack(spacing: 2) {
                    ForEach(0..<buckets.count, id: \.self) { idx in
                        let status = buckets[idx]
                        Capsule()
                            .fill(bucketFillColor(status))
                            .frame(height: trackHeight)
                    }
                }
                .frame(width: width)
                .position(x: width * 0.5, y: height * 0.5)

                // 灵动滑块 Thumb（纯白玻璃感滑块，无蓝点/蓝条）
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: Color.black.opacity(0.35), radius: 4, y: 1.5)
                    .position(x: thumbCenterX, y: height * 0.5)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let targetFraction: Double
                        if !isDragging {
                            feedbackGenerator.prepare()
                            isDragging = true
                            lastTranslationX = value.translation.width
                            currentFraction = activeFraction
                            activeSpeed = .fast
                            lastHapticPageIndex = displayedPageIndex
                            onSpeedChanged(.fast)
                            onScrubBegin(activeFraction)
                            targetFraction = activeFraction
                        } else {
                            // 纵向拉离检视调速档位
                            let verticalLift = value.translation.height
                            let nextSpeed: ReaderScrubSpeed
                            if verticalLift < -72 {
                                nextSpeed = .fine
                            } else if verticalLift < -34 {
                                nextSpeed = .medium
                            } else {
                                nextSpeed = .fast
                            }

                            if nextSpeed != activeSpeed {
                                activeSpeed = nextSpeed
                                onSpeedChanged(nextSpeed)
                                feedbackGenerator.selectionChanged()
                            }

                            let dx = value.translation.width - lastTranslationX
                            lastTranslationX = value.translation.width
                            let deltaPages = nextSpeed.dampedDeltaPages(
                                dx: dx,
                                usableWidth: usableWidth,
                                maxIndex: maxIndex,
                                isRightToLeft: isRightToLeft
                            )
                            targetFraction = min(max(currentFraction + deltaPages, 0), Double(maxIndex))
                            currentFraction = targetFraction
                        }
                        onScrubChanged(targetFraction)

                        let targetIndex = min(max(Int(targetFraction.rounded()), 0), max(totalPages - 1, 0))
                        if targetIndex != lastHapticPageIndex {
                            lastHapticPageIndex = targetIndex
                            feedbackGenerator.selectionChanged()
                        }
                    }
                    .onEnded { _ in
                        isDragging = false
                        lastTranslationX = 0
                        activeSpeed = .fast
                        onSpeedChanged(.fast)
                        let finalIndex = min(max(Int(currentFraction.rounded()), 0), max(totalPages - 1, 0))
                        onScrubEnd(finalIndex)
                    }
            )
        }
    }

    private func bucketFillColor(_ status: ReaderPageHealthStatus) -> Color {
        switch status {
        case .remote:
            return Color.white.opacity(0.18)
        case .cached:
            return Color.white.opacity(0.34)
        case .upscaled:
            return Color.white.opacity(0.52)
        }
    }
}

// MARK: - 风格 1：灵动纸缘微轨滑条（支持纵向拉离 1.0x -> 0.5x -> 0.25x 精细调速）

struct ReaderScrubberTrackBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    var onSpeedChanged: ((ReaderScrubSpeed) -> Void)? = nil
    let onScrubEnd: (Int) -> Void

    @State private var isDragging = false
    @State private var trackedFraction: Double = 0
    @State private var lastTranslationX: CGFloat = 0
    @State private var activeSpeed: ReaderScrubSpeed = .fast
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    private var maxIndex: Int {
        max(totalPages - 1, 1)
    }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    var body: some View {
        HStack(spacing: 10) {
            if isRightToLeft {
                endpointTotalLabel
                trackCanvas
                activePageLabel
            } else {
                activePageLabel
                trackCanvas
                endpointTotalLabel
            }
        }
        .frame(height: 36)
    }

    private var activePageLabel: some View {
        HStack(spacing: 3) {
            if isRightToLeft {
                Image(systemName: "arrow.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text("\(displayedPageIndex + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(minWidth: 32, alignment: isRightToLeft ? .leading : .trailing)
    }

    private var endpointTotalLabel: some View {
        Text("\(totalPages)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .frame(minWidth: 28, alignment: isRightToLeft ? .trailing : .leading)
    }

    private var trackCanvas: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = geo.size.height
            let thumbDiameter: CGFloat = isScrubbing ? 26 : 20
            let thumbRadius = thumbDiameter * 0.5
            let usableWidth = max(width - thumbDiameter, 1)

            let logicalRatio = CGFloat(activeFraction / Double(maxIndex))
            let visualRatio = isRightToLeft ? (1.0 - logicalRatio) : logicalRatio
            let thumbCenterX = thumbRadius + visualRatio * usableWidth
            let trackHeight: CGFloat = isScrubbing ? 8.5 : 6.5

            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())

                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: width, height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .position(x: width * 0.5, y: height * 0.5)

                let fillWidth: CGFloat = isRightToLeft
                    ? max(thumbDiameter * 0.5, width - thumbCenterX)
                    : max(thumbDiameter * 0.5, thumbCenterX)
                let fillCenterX: CGFloat = isRightToLeft
                    ? width - fillWidth * 0.5
                    : fillWidth * 0.5

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: min(width, fillWidth), height: trackHeight)
                    .position(x: fillCenterX, y: height * 0.5)

                if let anchor = originAnchorIndex, anchor >= 0, anchor < totalPages {
                    let anchorLogical = CGFloat(Double(anchor) / Double(maxIndex))
                    let anchorVisual = isRightToLeft ? (1.0 - anchorLogical) : anchorLogical
                    let anchorCenterX = thumbRadius + anchorVisual * usableWidth

                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .position(x: anchorCenterX, y: height * 0.5)
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.38), radius: isScrubbing ? 5 : 3, y: 1.5)
                    .position(x: thumbCenterX, y: height * 0.5)
                    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isScrubbing)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let currentRatio = CGFloat(Double(currentPageIndex) / Double(maxIndex))
                        let currentVisual = isRightToLeft ? (1.0 - currentRatio) : currentRatio
                        let restThumbCenterX = thumbRadius + currentVisual * usableWidth

                        let nextFraction: Double
                        if !isDragging {
                            feedbackGenerator.prepare()
                            lastHapticPageIndex = currentPageIndex
                            isDragging = true
                            lastTranslationX = value.translation.width
                            activeSpeed = .fast
                            onSpeedChanged?(.fast)

                            if abs(value.startLocation.x - restThumbCenterX) <= 26 {
                                nextFraction = Double(currentPageIndex)
                            } else {
                                nextFraction = fractionForTouchX(
                                    value.location.x,
                                    thumbRadius: thumbRadius,
                                    usableWidth: usableWidth
                                )
                            }
                            trackedFraction = nextFraction
                            onScrubBegin(nextFraction)
                        } else {
                            let liftDistance = -value.translation.height
                            let nextSpeed: ReaderScrubSpeed
                            if liftDistance > 92 {
                                nextSpeed = .fine
                            } else if liftDistance > 42 {
                                nextSpeed = .medium
                            } else {
                                nextSpeed = .fast
                            }
                            if nextSpeed != activeSpeed {
                                activeSpeed = nextSpeed
                                feedbackGenerator.selectionChanged()
                                onSpeedChanged?(nextSpeed)
                            }

                            let dx = value.translation.width - lastTranslationX
                            lastTranslationX = value.translation.width
                            let deltaPages = nextSpeed.dampedDeltaPages(
                                dx: dx,
                                usableWidth: usableWidth,
                                maxIndex: maxIndex,
                                isRightToLeft: isRightToLeft
                            )
                            nextFraction = min(max(trackedFraction + deltaPages, 0), Double(maxIndex))
                            trackedFraction = nextFraction
                        }

                        let targetIdx = Int(nextFraction.rounded())
                        if let prevHaptic = lastHapticPageIndex, prevHaptic != targetIdx {
                            feedbackGenerator.selectionChanged()
                            lastHapticPageIndex = targetIdx
                        }

                        onScrubChanged(nextFraction)
                    }
                    .onEnded { _ in
                        let finalFraction = isDragging ? trackedFraction : Double(currentPageIndex)
                        let finalIndex = min(max(Int(finalFraction.rounded()), 0), max(totalPages - 1, 0))
                        isDragging = false
                        lastTranslationX = 0
                        activeSpeed = .fast
                        lastHapticPageIndex = nil
                        onSpeedChanged?(.fast)
                        onScrubEnd(finalIndex)
                    }
            )
        }
    }

    private func fractionForTouchX(_ touchX: CGFloat, thumbRadius: CGFloat, usableWidth: CGFloat) -> Double {
        let clampedX = min(max(touchX - thumbRadius, 0), usableWidth)
        let visualRatio = clampedX / usableWidth
        let logicalRatio = isRightToLeft ? (1.0 - visualRatio) : visualRatio
        return min(max(Double(logicalRatio) * Double(maxIndex), 0), Double(maxIndex))
    }
}

// MARK: - 风格 2：纸书切口厚度（拇指拨页叶阵）

private struct ReaderForeEdgeActiveBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Int) -> Void

    @State private var isDragging = false
    @State private var trackedFraction: Double = 0
    @State private var lastTranslationX: CGFloat = 0
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private let leafCount = 34

    private var maxIndex: Int { max(totalPages - 1, 1) }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    var body: some View {
        let logicalRatio = activeFraction / Double(maxIndex)
        let visualRatio = isRightToLeft ? (1.0 - logicalRatio) : logicalRatio
        let activeLeaf = Int((visualRatio * Double(leafCount - 1)).rounded())

        HStack(spacing: 10) {
            if isRightToLeft {
                Text("\(totalPages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(minWidth: 26, alignment: .trailing)
            } else {
                Text("\(displayedPageIndex + 1)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, alignment: .trailing)
            }

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<leafCount, id: \.self) { idx in
                        let isRead = isRightToLeft ? (idx >= activeLeaf) : (idx <= activeLeaf)
                        let dist = abs(idx - activeLeaf)
                        let leafHeight: CGFloat = dist == 0 ? (isScrubbing ? 34 : 30) : (dist == 1 ? 24 : (dist == 2 ? 19 : 13))
                        let leafColor: Color = dist == 0
                            ? Color(red: 0.96, green: 0.36, blue: 0.28)
                            : (isRead ? Color(red: 0.96, green: 0.80, blue: 0.52).opacity(0.82) : Color.white.opacity(0.24))

                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(leafColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: leafHeight)
                    }
                }
                .frame(width: width, height: 36, alignment: .bottom)
                .overlay(alignment: .topLeading) {
                    if let anchor = originAnchorIndex, anchor >= 0, anchor < totalPages {
                        let anchorLogical = CGFloat(Double(anchor) / Double(maxIndex))
                        let anchorVisual = isRightToLeft ? (1.0 - anchorLogical) : anchorLogical
                        Circle()
                            .fill(Color.white)
                            .frame(width: 5, height: 5)
                            .offset(x: max(0, min(width - 5, anchorVisual * width - 2.5)), y: 2)
                    }
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            let nextFraction: Double
                            if !isDragging {
                                let clamped = min(max(value.location.x / width, 0), 1)
                                let logical = isRightToLeft ? (1.0 - clamped) : clamped
                                let tappedFraction = min(max(Double(logical) * Double(maxIndex), 0), Double(maxIndex))
                                feedbackGenerator.prepare()
                                lastHapticPageIndex = currentPageIndex
                                isDragging = true
                                lastTranslationX = value.translation.width
                                trackedFraction = tappedFraction
                                nextFraction = tappedFraction
                                onScrubBegin(nextFraction)
                            } else {
                                let liftDistance = -value.translation.height
                                let speed: ReaderScrubSpeed = liftDistance > 84 ? .fine : (liftDistance > 38 ? .medium : .fast)
                                let dx = value.translation.width - lastTranslationX
                                lastTranslationX = value.translation.width
                                let deltaPages = speed.dampedDeltaPages(
                                    dx: dx,
                                    usableWidth: width,
                                    maxIndex: maxIndex,
                                    isRightToLeft: isRightToLeft
                                )
                                nextFraction = min(max(trackedFraction + deltaPages, 0), Double(maxIndex))
                                trackedFraction = nextFraction
                            }

                            let targetIdx = Int(nextFraction.rounded())
                            if let prev = lastHapticPageIndex, prev != targetIdx {
                                feedbackGenerator.selectionChanged()
                                lastHapticPageIndex = targetIdx
                            }
                            onScrubChanged(nextFraction)
                        }
                        .onEnded { _ in
                            let finalFraction = isDragging ? trackedFraction : Double(currentPageIndex)
                            let finalIndex = min(max(Int(finalFraction.rounded()), 0), max(totalPages - 1, 0))
                            isDragging = false
                            lastTranslationX = 0
                            lastHapticPageIndex = nil
                            onScrubEnd(finalIndex)
                        }
                )
            }
            .frame(height: 36)

            if isRightToLeft {
                Text("\(displayedPageIndex + 1)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(minWidth: 26, alignment: .leading)
            } else {
                Text("\(totalPages)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(minWidth: 26, alignment: .leading)
            }
        }
        .frame(height: 36)
    }
}

// MARK: - 风格 3：精密游标卡尺（Canvas 可视窗刻度尺 + 单手任意位拨动）

private struct ReaderVernierDialActiveBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    @ObservedObject var cacheStatuses: ReaderPageCacheSnapshotStore
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Int) -> Void

    @State private var isDragging = false
    @State private var dragStartFraction: Double = 0
    @State private var trackedFraction: Double = 0
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()
    private let tickSpacing: CGFloat = 22.0

    private var maxIndex: Int { max(totalPages - 1, 1) }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("P\(displayedPageIndex + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(minWidth: 38, alignment: .trailing)

            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                let height = geo.size.height

                ZStack {
                    Canvas { context, size in
                        let centerX = size.width * 0.5
                        let bottomY = size.height - 4
                        let centerLogical = activeFraction
                        let halfVisiblePages = Int(ceil((size.width * 0.5) / tickSpacing)) + 2
                        let centerIdx = Int(centerLogical.rounded())
                        let lower = max(0, centerIdx - halfVisiblePages)
                        let upper = min(totalPages - 1, centerIdx + halfVisiblePages)

                        if lower <= upper {
                            for idx in lower...upper {
                                let deltaPages = CGFloat(Double(idx) - centerLogical)
                                let visualDelta = isRightToLeft ? -deltaPages : deltaPages
                                let x = centerX + visualDelta * tickSpacing
                                guard x >= -6, x <= size.width + 6 else { continue }

                                let distRatio = min(1.0, abs(x - centerX) / max(centerX, 1))
                                let edgeFade = max(0.08, 1.0 - pow(distRatio, 1.75))
                                let isMajor = (idx + 1) % 10 == 0 || idx == 0 || idx == totalPages - 1
                                let isCurrent = idx == centerIdx
                                let barH: CGFloat = isMajor ? 18 : 10
                                let barW: CGFloat = isMajor ? 1.8 : 1.2

                                let tickColor: Color = isCurrent
                                    ? Color.white
                                    : Color.white.opacity((isMajor ? 0.78 : 0.30) * edgeFade)

                                let barRect = CGRect(
                                    x: x - barW * 0.5,
                                    y: bottomY - barH,
                                    width: barW,
                                    height: barH
                                )
                                context.fill(Path(roundedRect: barRect, cornerRadius: 1), with: .color(tickColor))

                                let status = cacheStatuses.status(at: idx)
                                if status != .remote {
                                    let dotColor: Color = status == .upscaled
                                        ? Color.white.opacity(0.85)
                                        : Color.white.opacity(0.45)
                                    let dotRect = CGRect(x: x - 1.75, y: bottomY - barH - 5.5, width: 3.5, height: 3.5)
                                    context.fill(Path(ellipseIn: dotRect), with: .color(dotColor.opacity(edgeFade)))
                                }
                            }
                        }
                    }

                    // 固定中心读数指针
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2.5, height: height - 4)
                        .shadow(color: Color.white.opacity(0.55), radius: 3)
                }
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if !isDragging {
                                feedbackGenerator.prepare()
                                lastHapticPageIndex = currentPageIndex
                                isDragging = true
                                dragStartFraction = Double(currentPageIndex)
                                trackedFraction = dragStartFraction
                                onScrubBegin(dragStartFraction)
                            } else {
                                let deltaPages = Double(-value.translation.width / tickSpacing)
                                let signedDelta = isRightToLeft ? -deltaPages : deltaPages
                                let next = min(max(dragStartFraction + signedDelta, 0), Double(maxIndex))
                                trackedFraction = next

                                let targetIdx = Int(next.rounded())
                                if let prev = lastHapticPageIndex, prev != targetIdx {
                                    feedbackGenerator.selectionChanged()
                                    lastHapticPageIndex = targetIdx
                                }
                                onScrubChanged(next)
                            }
                        }
                        .onEnded { _ in
                            let finalFraction = isDragging ? trackedFraction : Double(currentPageIndex)
                            let finalIndex = min(max(Int(finalFraction.rounded()), 0), max(totalPages - 1, 0))
                            isDragging = false
                            lastHapticPageIndex = nil
                            onScrubEnd(finalIndex)
                        }
                )
            }
            .frame(height: 34)

            Text("/ \(totalPages)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .frame(minWidth: 34, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .liquidGlassCapsule(interactive: true)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - 风格 5：缓冲与 AI 2x 超分热力分段轨

private struct ReaderHeatmapActiveBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    @ObservedObject var cacheStatuses: ReaderPageCacheSnapshotStore
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Int) -> Void

    @State private var isDragging = false
    @State private var trackedFraction: Double = 0
    @State private var lastTranslationX: CGFloat = 0
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    private var maxIndex: Int { max(totalPages - 1, 1) }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    var body: some View {
        let buckets = cacheStatuses.bucketStatuses(totalPages: totalPages, bucketCount: 38)
        let logicalRatio = CGFloat(activeFraction / Double(maxIndex))
        let visualRatio = isRightToLeft ? (1.0 - logicalRatio) : logicalRatio

        VStack(spacing: 4) {
            HStack(spacing: 10) {
                if isRightToLeft {
                    Text("\(totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(minWidth: 26, alignment: .trailing)
                } else {
                    Text("\(displayedPageIndex + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 26, alignment: .trailing)
                }

                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    let height = geo.size.height
                    let thumbDiameter: CGFloat = isScrubbing ? 24 : 18
                    let thumbRadius = thumbDiameter * 0.5
                    let usableWidth = max(width - thumbDiameter, 1)
                    let thumbCenterX = thumbRadius + visualRatio * usableWidth

                    ZStack(alignment: .leading) {
                        HStack(spacing: 1.5) {
                            ForEach(0..<buckets.count, id: \.self) { visualIdx in
                                let logicalBucket = isRightToLeft ? (buckets.count - 1 - visualIdx) : visualIdx
                                let status = buckets[logicalBucket]
                                let repPage = (logicalBucket * totalPages) / max(buckets.count, 1)
                                let isRead = repPage <= displayedPageIndex

                                let cellColor: Color = {
                                    switch status {
                                    case .upscaled:
                                        return Color(red: 0.72, green: 0.36, blue: 0.98).opacity(isRead ? 1.0 : 0.52)
                                    case .cached:
                                        return Color.green.opacity(isRead ? 0.95 : 0.45)
                                    case .remote:
                                        return isRead ? Color.accentColor : Color.white.opacity(0.22)
                                    }
                                }()

                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(cellColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: isScrubbing ? 10 : 8)
                            }
                        }
                        .padding(2)
                        .background(Color.black.opacity(0.28), in: Capsule())

                        if let anchor = originAnchorIndex, anchor >= 0, anchor < totalPages {
                            let anchorLogical = CGFloat(Double(anchor) / Double(maxIndex))
                            let anchorVisual = isRightToLeft ? (1.0 - anchorLogical) : anchorLogical
                            let anchorX = thumbRadius + anchorVisual * usableWidth

                            Circle()
                                .fill(Color.white)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
                                .position(x: anchorX, y: height * 0.5)
                        }

                        Circle()
                            .fill(Color.white)
                            .frame(width: thumbDiameter, height: thumbDiameter)
                            .shadow(color: .black.opacity(0.42), radius: 3, y: 1)
                            .position(x: thumbCenterX, y: height * 0.5)
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                let next: Double
                                if !isDragging {
                                    let clampedX = min(max(value.location.x - thumbRadius, 0), usableWidth)
                                    let vRatio = clampedX / usableWidth
                                    let lRatio = isRightToLeft ? (1.0 - vRatio) : vRatio
                                    let tapped = min(max(Double(lRatio) * Double(maxIndex), 0), Double(maxIndex))
                                    feedbackGenerator.prepare()
                                    lastHapticPageIndex = currentPageIndex
                                    isDragging = true
                                    lastTranslationX = value.translation.width
                                    trackedFraction = tapped
                                    next = tapped
                                    onScrubBegin(next)
                                } else {
                                    let liftDistance = -value.translation.height
                                    let speed: ReaderScrubSpeed = liftDistance > 84 ? .fine : (liftDistance > 38 ? .medium : .fast)
                                    let dx = value.translation.width - lastTranslationX
                                    lastTranslationX = value.translation.width
                                    let deltaPages = speed.dampedDeltaPages(
                                        dx: dx,
                                        usableWidth: usableWidth,
                                        maxIndex: maxIndex,
                                        isRightToLeft: isRightToLeft
                                    )
                                    next = min(max(trackedFraction + deltaPages, 0), Double(maxIndex))
                                    trackedFraction = next
                                }

                                let targetIdx = Int(next.rounded())
                                if let prev = lastHapticPageIndex, prev != targetIdx {
                                    feedbackGenerator.selectionChanged()
                                    lastHapticPageIndex = targetIdx
                                }
                                onScrubChanged(next)
                            }
                            .onEnded { _ in
                                let finalFraction = isDragging ? trackedFraction : Double(currentPageIndex)
                                let finalIndex = min(max(Int(finalFraction.rounded()), 0), max(totalPages - 1, 0))
                                isDragging = false
                                lastTranslationX = 0
                                lastHapticPageIndex = nil
                                onScrubEnd(finalIndex)
                            }
                    )
                }
                .frame(height: 24)

                if isRightToLeft {
                    Text("\(displayedPageIndex + 1)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 26, alignment: .leading)
                } else {
                    Text("\(totalPages)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(minWidth: 26, alignment: .leading)
                }
            }

            HStack(spacing: 12) {
                heatmapLegendItem(color: Color(red: 0.72, green: 0.36, blue: 0.98), text: "2x 超分")
                heatmapLegendItem(color: .green, text: "已缓存")
                heatmapLegendItem(color: .white.opacity(0.32), text: "待加载")
                Spacer()
                let pct = Int(((Double(displayedPageIndex) / Double(maxIndex)) * 100).rounded())
                Text("\(pct)%")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 40)
    }

    private func heatmapLegendItem(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
        }
    }
}

// MARK: - 2. 沉浸阅读态极简进度层 + 侧边隐形纵轨

struct ReaderAmbientProgressOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var deviceInfo = ReaderDeviceInfoStore.shared

    let style: ReaderProgressStyle
    let showChrome: Bool
    let showAmbientProgress: Bool
    let isScrubbing: Bool
    let totalPages: Int
    let currentPageIndex: Int
    let isRightToLeft: Bool
    let readerBackground: ReaderBackground
    let safeAreaInsets: UIEdgeInsets
    var chapterTitle: String = ""
    var chapterIndex: Int? = nil
    var totalChapters: Int = 1
    let onSideRailScrubBegin: (Double) -> Void
    let onSideRailScrubChanged: (Double) -> Void
    let onSideRailScrubEnd: (Int) -> Void

    @State private var isDraggingSideRail = false
    @State private var sideRailFraction: Double = 0
    @State private var lastSideRailHapticIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    private var chapterBadge: String? {
        formatCompactChapterBadge(chapterIndex: chapterIndex, totalChapters: totalChapters)
    }

    private var isDarkCanvas: Bool {
        switch readerBackground {
        case .dark, .immersive:
            return true
        case .light, .texture:
            return false
        case .followSystem:
            return colorScheme == .dark
        }
    }

    private var primaryInk: Color {
        isDarkCanvas ? Color.white.opacity(0.72) : Color.black.opacity(0.56)
    }

    private var trackInk: Color {
        isDarkCanvas ? Color.white.opacity(0.18) : Color.black.opacity(0.13)
    }

    private var maxIndex: Int { max(totalPages - 1, 1) }

    var body: some View {
        if totalPages > 1 {
            if style == .sideRail {
                if showAmbientProgress || showChrome || isDraggingSideRail {
                    sideEdgeVerticalRail
                }
            } else if showAmbientProgress && !showChrome && !isScrubbing {
                bottomAmbientView
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var bottomAmbientView: some View {
        let ratio = min(max(Double(currentPageIndex) / Double(maxIndex), 0), 1)
        let pct = Int((ratio * 100).rounded())
        let bottomPad = max(safeAreaInsets.bottom, 10) + 6

        VStack {
            Spacer()

            switch style {
            case .edgeDock:
                let leftEdgeText = isRightToLeft
                    ? "\(pct)% · 剩 \(totalPages - currentPageIndex - 1) 页"
                    : (chapterBadge.map { "\($0) · 第 \(currentPageIndex + 1) 页" } ?? "第 \(currentPageIndex + 1) 页")
                let rightEdgeText = isRightToLeft
                    ? (chapterBadge.map { "\(currentPageIndex + 1) / \(totalPages) · \($0)" } ?? "\(currentPageIndex + 1) / \(totalPages)")
                    : "\(pct)% · \(totalPages) 页"

                VStack(spacing: 4) {
                    HStack {
                        Text(leftEdgeText)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(primaryInk)
                        Spacer()
                        Text(rightEdgeText)
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(primaryInk)
                    }

                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let fillW = max(3, w * ratio)
                        ZStack(alignment: isRightToLeft ? .trailing : .leading) {
                            Capsule().fill(trackInk)
                            Capsule()
                                .fill(Color.accentColor.opacity(isDarkCanvas ? 0.90 : 0.85))
                                .frame(width: fillW)
                        }
                    }
                    .frame(height: 2.5)
                }
                .padding(.horizontal, max(safeAreaInsets.left, safeAreaInsets.right, 18))
                .padding(.bottom, bottomPad)

            case .foreEdge:
                let visualRatio = isRightToLeft ? (1.0 - ratio) : ratio
                let foreEdgeLabel: String = {
                    if let chapterBadge {
                        return isRightToLeft ? "← 翻阅方向 · \(chapterBadge)" : "\(chapterBadge) · 翻阅方向 →"
                    }
                    return isRightToLeft ? "← 翻阅方向" : "翻阅方向 →"
                }()

                VStack(spacing: 4) {
                    HStack {
                        Text(foreEdgeLabel)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(primaryInk)
                        Spacer()
                        Text("P\(currentPageIndex + 1) / \(totalPages)")
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(primaryInk)
                    }

                    GeometryReader { geo in
                        let w = max(geo.size.width, 1)
                        let fillW = w * ratio
                        let ribbonX = min(max(3, visualRatio * w), w - 3)
                        ZStack(alignment: isRightToLeft ? .trailing : .leading) {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(trackInk)

                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(
                                    isDarkCanvas
                                        ? Color.white.opacity(0.38)
                                        : Color(red: 0.62, green: 0.48, blue: 0.30).opacity(0.55)
                                )
                                .frame(width: max(2, fillW))
                        }
                        .overlay(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .fill(Color(red: 0.88, green: 0.28, blue: 0.22))
                                .frame(width: 5, height: 10)
                                .offset(x: ribbonX - 2.5, y: -2)
                        }
                    }
                    .frame(height: 6)
                }
                .padding(.horizontal, max(safeAreaInsets.left, safeAreaInsets.right, 22))
                .padding(.bottom, bottomPad)

            case .vernierDial:
                HStack(spacing: 6) {
                    if let chapterBadge {
                        Text(chapterBadge)
                            .opacity(0.75)
                        Text("·")
                            .opacity(0.45)
                    }
                    Text("P\(currentPageIndex + 1) / \(totalPages)")
                    Text("·")
                        .opacity(0.45)
                    Text("\(pct)%")
                }
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .foregroundStyle(isDarkCanvas ? Color.white.opacity(0.90) : Color.black.opacity(0.80))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .liquidGlassCapsule()
                .environment(\.colorScheme, isDarkCanvas ? .dark : .light)
                .padding(.bottom, bottomPad)

            case .heatmapSeg:
                let segCount = 6
                let pagesPerSeg = Double(totalPages) / Double(segCount)
                HStack(spacing: 3) {
                    ForEach(0..<segCount, id: \.self) { visualIdx in
                        let segIdx = isRightToLeft ? (segCount - 1 - visualIdx) : visualIdx
                        let start = Double(segIdx) * pagesPerSeg
                        let end = Double(segIdx + 1) * pagesPerSeg
                        let localFill = min(1.0, max(0.0, (Double(currentPageIndex + 1) - start) / max(end - start, 1)))

                        GeometryReader { geo in
                            let w = max(geo.size.width, 1)
                            ZStack(alignment: isRightToLeft ? .trailing : .leading) {
                                Capsule().fill(trackInk)
                                if localFill > 0 {
                                    Capsule()
                                        .fill(Color.accentColor.opacity(0.88))
                                        .frame(width: max(2, w * localFill))
                                }
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(.horizontal, max(safeAreaInsets.left, safeAreaInsets.right, 16))
                .padding(.bottom, bottomPad)

            case .sideRail:
                EmptyView()

            case .microCapsule:
                let isLastPage = (currentPageIndex + 1 >= totalPages)
                let isLastChapter = (chapterIndex ?? 0) + 1 >= totalChapters
                let statusText: String = {
                    if let chapterBadge {
                        if isLastPage {
                            return isLastChapter ? "\(chapterBadge) · 已读完" : "\(chapterBadge) · 本话完"
                        }
                        return chapterBadge
                    }
                    return isLastPage ? "已读完" : (chapterTitle.isEmpty ? "第 \(currentPageIndex + 1) 页" : chapterTitle)
                }()
                let fgPrimary = isDarkCanvas ? Color.white.opacity(0.92) : Color.black.opacity(0.84)
                let fgSecondary = isDarkCanvas ? Color.white.opacity(0.76) : Color.black.opacity(0.68)
                let fgDot = isDarkCanvas ? Color.white.opacity(0.36) : Color.black.opacity(0.28)

                HStack(spacing: 5) {
                    Text(statusText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(fgSecondary)
                        .lineLimit(1)

                    Text("·")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fgDot)

                    Text("\(currentPageIndex + 1)/\(totalPages)")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(fgPrimary)

                    Text("·")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fgDot)

                    Text(deviceInfo.timeString.isEmpty ? "00:00" : deviceInfo.timeString)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(fgPrimary)

                    Text("·")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(fgDot)

                    HStack(spacing: 3) {
                        Image(systemName: deviceInfo.batteryIconName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(deviceInfo.isCharging ? Color.green : fgSecondary)
                        Text("\(deviceInfo.batteryPercentage)%")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(fgPrimary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .liquidGlassCapsule()
                .environment(\.colorScheme, isDarkCanvas ? .dark : .light)
                .padding(.bottom, bottomPad)
            }
        }
    }

    private var sideEdgeVerticalRail: some View {
        let activeFrac = isDraggingSideRail ? sideRailFraction : Double(currentPageIndex)
        let ratio = min(max(activeFrac / Double(maxIndex), 0), 1)
        let activeIdx = min(max(Int(activeFrac.rounded()), 0), totalPages - 1)
        let pct = Int((ratio * 100).rounded())
        let expanded = isDraggingSideRail || showChrome

        return HStack {
            Spacer()
            GeometryReader { geo in
                let railHeight = max(geo.size.height, 40)
                let knobY = ratio * railHeight
                let bubbleY = min(max(24, knobY), railHeight - 24)

                ZStack(alignment: .trailing) {
                    // 窄热区：右缘 24pt，配合 minimumDistance: 4 不误抢单页点按翻页
                    Color.clear
                        .frame(width: 24, height: railHeight)
                        .contentShape(Rectangle())

                    ZStack(alignment: .top) {
                        Capsule()
                            .fill(expanded ? Color.white.opacity(0.24) : trackInk)
                            .frame(width: expanded ? 6.5 : 3.5, height: railHeight)

                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: expanded ? 6.5 : 3.5, height: max(4, knobY))

                        Capsule()
                            .fill(expanded ? Color.white : Color.accentColor)
                            .frame(width: expanded ? 14 : 9, height: expanded ? 28 : 18)
                            .overlay(
                                Capsule()
                                    .stroke(expanded ? Color.accentColor : Color.white, lineWidth: 1.4)
                            )
                            .shadow(color: .black.opacity(0.28), radius: 3, y: 1)
                            .offset(y: min(max(0, knobY - (expanded ? 14 : 9)), railHeight - (expanded ? 28 : 18)))
                    }
                    .padding(.trailing, 4)
                }
                .overlay(alignment: .topTrailing) {
                    if isDraggingSideRail {
                        HStack(spacing: 5) {
                            if let chapterBadge {
                                Text(chapterBadge)
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.82))
                                Text("·")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white.opacity(0.42))
                            }
                            Text("P\(activeIdx + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.white)
                            Text("/ \(totalPages) · \(pct)%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.white.opacity(0.75))
                        }
                        .fixedSize()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .liquidGlassCapsule()
                        .environment(\.colorScheme, .dark)
                        .offset(x: -32, y: bubbleY - 15)
                        .allowsHitTesting(false)
                    }
                }
                .highPriorityGesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .local)
                        .onChanged { value in
                            let clamped = min(max(value.location.y / railHeight, 0), 1)
                            let next = min(max(Double(clamped) * Double(maxIndex), 0), Double(maxIndex))
                            if !isDraggingSideRail {
                                feedbackGenerator.prepare()
                                lastSideRailHapticIndex = currentPageIndex
                                isDraggingSideRail = true
                                sideRailFraction = next
                                onSideRailScrubBegin(next)
                            } else {
                                sideRailFraction = next
                                onSideRailScrubChanged(next)
                            }

                            let targetIdx = Int(next.rounded())
                            if let prev = lastSideRailHapticIndex, prev != targetIdx {
                                feedbackGenerator.selectionChanged()
                                lastSideRailHapticIndex = targetIdx
                            }
                        }
                        .onEnded { _ in
                            let finalIndex = min(max(Int(sideRailFraction.rounded()), 0), max(totalPages - 1, 0))
                            isDraggingSideRail = false
                            lastSideRailHapticIndex = nil
                            onSideRailScrubEnd(finalIndex)
                        }
                )
            }
            .frame(width: 28)
            .padding(.top, max(safeAreaInsets.top, 20) + 74)
            .padding(.bottom, max(safeAreaInsets.bottom, 20) + 92)
            .padding(.trailing, max(safeAreaInsets.right, 2))
        }
    }
}

// MARK: - 3. 全屏微弧扇面预览蒙层

/// 拖动进度条时展开的全屏预览浮层（半透暗幕 + 顶部精细调速提示 + 居中高清预映/页码胶囊 + 微弧扇面缩略图卡片流）
struct ReaderScrubberPreviewOverlay: View {
    let pages: [MangaPage]
    let scrubFraction: Double
    let originIndex: Int
    let returnAnchorIndex: Int?
    let isRightToLeft: Bool
    let upscalerConfig: ImageUpscalerConfig
    let enableUpscaler: Bool
    let bottomReservedHeight: CGFloat
    var progressStyle: ReaderProgressStyle = .edgeDock
    var scrubSpeed: ReaderScrubSpeed = .fast
    @ObservedObject var thumbnailStore: ReaderThumbnailStore

    private var targetIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(Int(scrubFraction.rounded()), 0), pages.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let cardWidth: CGFloat = isLandscape
                ? min(max(geo.size.height * 0.22, 68), 88)
                : min(max(geo.size.width * 0.275, 90), 118)
            let cardHeight = cardWidth * 1.40
            let stripHeight = cardHeight + 48

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.46),
                        Color.black.opacity(0.62),
                        Color.black.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    if progressStyle == .edgeDock {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(scrubSpeed.indicatorColor)
                                .frame(width: 6, height: 6)
                            Text(scrubSpeed.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5.5)
                        .background(Color.black.opacity(0.76), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
                        .padding(.top, isLandscape ? 16 : 62)
                    }

                    Spacer(minLength: 14)

                    centerPreviewHUD(availableSize: geo.size, isLandscape: isLandscape)

                    Spacer(minLength: isLandscape ? 10 : 20)

                    arcThumbnailStrip(
                        containerWidth: geo.size.width,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight
                    )
                    .frame(height: stripHeight)
                    .padding(.bottom, bottomReservedHeight)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func centerPreviewHUD(availableSize: CGSize, isLandscape: Bool) -> some View {
        let _ = thumbnailStore.version
        if pages.indices.contains(targetIndex) {
            let page = pages[targetIndex]
            let thumbAsset = thumbnailStore.cachedThumbnailAsset(for: page.imageURL)
            let thumb = thumbAsset?.primaryThumbnail
            let stripFrames = thumbAsset?.longStripFrames
            let isLongStrip = (stripFrames?.count ?? 0) >= 3
            let isAtOrigin = (targetIndex == originIndex)
            let isUpscaled = enableUpscaler && PageUpscalerPipeline.shared.hasCachedResult(pageKey: page.imageURL, config: upscalerConfig)
            let isLocallyCached = thumb != nil || OnlineImageLoader.shared.hasCachedImage(for: page.imageURL)
            let isHoverLoading = thumbnailStore.isInFlight(for: page.imageURL)

            VStack(spacing: isLandscape ? 8 : 14) {
                if let stripFrames, stripFrames.count >= 3 {
                    longStripFilmstripPreview(
                        frames: Array(stripFrames.prefix(3)),
                        availableSize: availableSize,
                        isLandscape: isLandscape
                    )
                } else if let thumb {
                    let maxPreviewHeight: CGFloat = isLandscape
                        ? max(96, availableSize.height * 0.30)
                        : min(230, availableSize.height * 0.27)
                    let aspect = thumb.size.height > 0 ? (thumb.size.width / thumb.size.height) : 0.71
                    let previewHeight = maxPreviewHeight
                    let previewWidth = min(availableSize.width * 0.56, previewHeight * aspect)

                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: max(90, previewWidth), height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
                }

                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("第 \(targetIndex + 1) 页")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("/ \(pages.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                        if isLongStrip {
                            Text("长图")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.78), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        if isAtOrigin {
                            Circle()
                                .fill(Color.white.opacity(0.75))
                                .frame(width: 6, height: 6)
                            Text("当前阅读位置 · 松手不跳转")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        } else if isUpscaled {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("已超分 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                        } else if isLocallyCached {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("已缓存 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                        } else if isHoverLoading {
                            ProgressView()
                                .scaleEffect(0.65)
                                .tint(.white)
                            Text("正在载入预览 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.88))
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.42))
                                .frame(width: 6, height: 6)
                            Text("在线页面 · 停顿加载预览或松手跳转")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    if let anchor = returnAnchorIndex, anchor != targetIndex, anchor != originIndex {
                        Text("返回原点：第 \(anchor + 1) 页")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.68))
                            .padding(.top, 1)
                    } else if !isAtOrigin {
                        Text("起跳前：第 \(originIndex + 1) 页")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.68))
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .liquidGlassRoundedRect(cornerRadius: 16)
            }
            .padding(.horizontal, 24)
        }
    }

    /// 韩漫长图专用「上 / 中 / 下」三格分镜胶片预览条（按宽高清采样 + 自动避开纯白/纯黑留白）
    private func longStripFilmstripPreview(
        frames: [UIImage],
        availableSize: CGSize,
        isLandscape: Bool
    ) -> some View {
        let labels = ["上", "中", "下"]
        let maxHeight: CGFloat = isLandscape
            ? max(88, min(126, availableSize.height * 0.28))
            : max(124, min(176, availableSize.height * 0.22))
        let maxTotalWidth = min(availableSize.width - 44, isLandscape ? 380 : 340)
        let spacing: CGFloat = 6
        let outerPadding: CGFloat = 7
        let frameW = min(maxHeight / 1.38, max(64, (maxTotalWidth - outerPadding * 2 - spacing * 2) / 3.0))
        let frameH = frameW * 1.38

        return HStack(spacing: spacing) {
            ForEach(0..<min(frames.count, 3), id: \.self) { idx in
                ZStack(alignment: .bottomLeading) {
                    Image(uiImage: frames[idx])
                        .resizable()
                        .scaledToFill()
                        .frame(width: frameW, height: frameH)
                        .clipped()

                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.62)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 24)

                    Text(labels[idx])
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.black.opacity(0.52), in: Capsule())
                        .padding(.leading, 5)
                        .padding(.bottom, 5)
                }
                .frame(width: frameW, height: frameH)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.20), lineWidth: 0.7)
                )
            }
        }
        .padding(outerPadding)
        .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 1.0)
        )
        .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
    }

    @ViewBuilder
    private func arcThumbnailStrip(
        containerWidth: CGFloat,
        cardWidth: CGFloat,
        cardHeight: CGFloat
    ) -> some View {
        let _ = thumbnailStore.version
        let lower = max(0, targetIndex - 4)
        let upper = min(pages.count - 1, targetIndex + 4)

        ZStack {
            if lower <= upper {
                ForEach(lower...upper, id: \.self) { idx in
                    let page = pages[idx]
                    let delta = CGFloat(idx) - CGFloat(scrubFraction)
                    let visualDelta = isRightToLeft ? -delta : delta
                    let absDelta = abs(visualDelta)

                    let xOffset = visualDelta * (cardWidth * 0.70)
                    let yOffset = pow(absDelta, 1.60) * 11.0
                    let angle = Angle.degrees(Double(visualDelta) * 4.0)
                    let scale = max(0.84, 1.06 - absDelta * 0.105)
                    let cardOpacity = max(0.0, 1.0 - max(0, absDelta - 2.85) * 0.65)
                    let isSelected = (idx == targetIndex)

                    let thumb = thumbnailStore.cachedThumbnail(for: page.imageURL)
                    let isDiskOrMemCached = thumb != nil || OnlineImageLoader.shared.hasCachedImage(for: page.imageURL)
                    let isFetching = thumbnailStore.isInFlight(for: page.imageURL)

                    arcCardView(
                        pageIndex: idx,
                        thumbnail: thumb,
                        isDiskOrMemCached: isDiskOrMemCached,
                        isFetching: isFetching,
                        isSelected: isSelected,
                        isOrigin: idx == originIndex,
                        width: cardWidth,
                        height: cardHeight
                    )
                    .scaleEffect(scale)
                    .rotationEffect(angle, anchor: .bottom)
                    .offset(x: xOffset, y: yOffset)
                    .opacity(cardOpacity)
                    .zIndex(100.0 - Double(absDelta) * 10.0)
                }
            }
        }
        .frame(width: containerWidth, height: cardHeight + 36)
        .clipped()
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.90), value: scrubFraction)
    }

    @ViewBuilder
    private func arcCardView(
        pageIndex: Int,
        thumbnail: UIImage?,
        isDiskOrMemCached: Bool,
        isFetching: Bool,
        isSelected: Bool,
        isOrigin: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.14))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Text("\(pageIndex + 1)")
                        .font(.system(size: max(18, width * 0.24), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(isSelected ? 0.55 : 0.30))

                    if isFetching {
                        ProgressView()
                            .scaleEffect(0.70)
                            .tint(.white.opacity(0.85))
                    } else if isDiskOrMemCached {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: width, height: height)
                .background(
                    LinearGradient(
                        colors: [Color(white: 0.20), Color(white: 0.13)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            VStack {
                HStack {
                    if isOrigin {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 6, height: 6)
                            .padding(6)
                    }
                    Spacer()
                }
                Spacer()
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 30)

                    Text("\(pageIndex + 1)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.90))
                        .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                        .padding(.bottom, 5)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 2.0 : 0.8
                )
        )
        .shadow(
            color: .black.opacity(isSelected ? 0.55 : 0.32),
            radius: isSelected ? 12 : 6,
            y: isSelected ? 6 : 3
        )
    }
}

// MARK: - 4. 跳走后的返回原点锚点胶囊

/// 通过进度条跨页跳转后显示的快捷回跳胶囊，支持一键回到跳走前阅读页或手动收起
struct ReaderReturnAnchorPill: View {
    let anchorPageIndex: Int
    let onReturn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onReturn) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("回到第 \(anchorPageIndex + 1) 页")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.8, height: 14)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .liquidGlassCapsule(interactive: true)
    }
}
