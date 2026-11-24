import Combine
import Foundation
import ImageIO
import UIKit

/// 在线阅读器进度条扇面缩略图缓存与防抖点载协调器
/// - 优先零网络复用内存原图或磁盘缓存（通过 ImageIO 直接按目标像素尺寸硬件降采样，不占用全图内存）
/// - 对未缓存页面：快速拖动时不发请求，仅在手指悬停 >= 180ms 后静默按需预取聚焦页及左右相邻各 1 页
/// 单页进度条预览资源（普通单页为完整缩略图；韩漫长图自动生成避留白首帧与上/中/下三格高清分镜）
public final class ReaderPageThumbnail: NSObject, @unchecked Sendable {
    public let primaryThumbnail: UIImage
    public let longStripFrames: [UIImage]?
    public let originalAspectRatio: CGFloat

    public var isLongStrip: Bool {
        if let frames = longStripFrames, !frames.isEmpty {
            return true
        }
        return false
    }

    public init(
        primaryThumbnail: UIImage,
        longStripFrames: [UIImage]? = nil,
        originalAspectRatio: CGFloat = 1.4
    ) {
        self.primaryThumbnail = primaryThumbnail
        self.longStripFrames = longStripFrames
        self.originalAspectRatio = originalAspectRatio
        super.init()
    }
}

@MainActor
public final class ReaderThumbnailStore: ObservableObject {
    public static let shared = ReaderThumbnailStore()

    private final class SendableThumbnailCache: @unchecked Sendable {
        let storage = NSCache<NSString, ReaderPageThumbnail>()

        init() {
            storage.countLimit = 220
            storage.totalCostLimit = 40 * 1024 * 1024
        }
    }

    @Published public private(set) var version: UInt = 0
    @Published public private(set) var inFlightURLs: Set<String> = []

    private let thumbCache = SendableThumbnailCache()
    private var localWarmingURLs: Set<String> = []
    private var hoverTask: Task<Void, Never>?
    private var lastHoverPageKey: String?

    private static let maxThumbnailPixelSize: CGFloat = 300
    /// 判定为韩漫/条漫长图的高宽比阈值（height / width）
    private static let longStripAspectThreshold: CGFloat = 2.0
    /// 长图缩略图基准宽度（确保宽不被压成马赛克）
    private static let longStripTargetWidth: CGFloat = 240
    /// 长图中间采样高度上限（控制临时内存峰值）
    private static let longStripMaxWorkingHeight: CGFloat = 3600
    /// 单格分镜卡片的高宽比
    private static let stripFrameAspect: CGFloat = 1.38

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thumbCache.storage.removeAllObjects()
            }
        }
    }

    public func cachedThumbnail(for urlString: String) -> UIImage? {
        thumbCache.storage.object(forKey: urlString as NSString)?.primaryThumbnail
    }

    public func cachedThumbnailAsset(for urlString: String) -> ReaderPageThumbnail? {
        thumbCache.storage.object(forKey: urlString as NSString)
    }

    public func isInFlight(for urlString: String) -> Bool {
        inFlightURLs.contains(urlString)
    }

    public func clearAll() {
        cancelHoverPrefetch()
        thumbCache.storage.removeAllObjects()
        localWarmingURLs.removeAll()
        inFlightURLs.removeAll()
        version &+= 1
    }

    public func cancelHoverPrefetch() {
        hoverTask?.cancel()
        hoverTask = nil
        lastHoverPageKey = nil
        if !inFlightURLs.isEmpty {
            inFlightURLs.removeAll()
        }
    }

    /// 当用户点击或拖动聚焦到某页时调用：
    /// 1. 立即同步/本地预热可见扇面窗口内所有已有缓存页面（零网络开销）
    /// 2. 180ms 防抖悬停后，为尚未缓存的焦点页及左右各 1 页触发轻量网络拉取
    public func scheduleHoverUpdate(pages: [MangaPage], focusIndex: Int) {
        guard pages.indices.contains(focusIndex) else {
            cancelHoverPrefetch()
            return
        }

        let focusKey = pages[focusIndex].id
        if lastHoverPageKey == focusKey, hoverTask != nil {
            return
        }
        lastHoverPageKey = focusKey

        warmLocalWindow(pages: pages, around: focusIndex, radius: 4)

        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }

            let candidateIndices = [focusIndex, focusIndex + 1, focusIndex - 1]
                .filter { pages.indices.contains($0) }

            var targetPages: [MangaPage] = []
            for idx in candidateIndices {
                let page = pages[idx]
                if self.cachedThumbnail(for: page.imageURL) != nil {
                    continue
                }
                if OnlineImageLoader.shared.hasCachedImage(for: page.imageURL) {
                    self.warmSingleLocalPage(page)
                    continue
                }
                targetPages.append(page)
            }

            guard !targetPages.isEmpty else { return }

            // 优先确保正中聚焦页第一顺位下完显示，再并发预热相邻两页
            if let primary = targetPages.first {
                await self.fetchAndGenerateThumbnail(for: primary)
            }
            guard !Task.isCancelled else { return }

            let neighbors = Array(targetPages.dropFirst())
            if !neighbors.isEmpty {
                await withTaskGroup(of: Void.self) { group in
                    for neighbor in neighbors {
                        group.addTask { [weak self] in
                            await self?.fetchAndGenerateThumbnail(for: neighbor)
                        }
                    }
                }
            }
        }
    }

    /// 零网络预热窗口内已存在于内存或磁盘的页面
    public func warmLocalWindow(pages: [MangaPage], around focusIndex: Int, radius: Int = 4) {
        guard !pages.isEmpty else { return }
        let lower = max(0, focusIndex - radius)
        let upper = min(pages.count - 1, focusIndex + radius)
        guard lower <= upper else { return }

        // 先中心再两侧排序，优先让视觉焦点最先出图
        let ordered = (lower...upper).sorted { abs($0 - focusIndex) < abs($1 - focusIndex) }
        for idx in ordered {
            warmSingleLocalPage(pages[idx])
        }
    }

    private func warmSingleLocalPage(_ page: MangaPage) {
        let url = page.imageURL
        guard !url.isEmpty,
              cachedThumbnail(for: url) == nil,
              !localWarmingURLs.contains(url) else {
            return
        }

        let memoryImg = OnlineImageLoader.shared.cachedMemoryImage(for: url)
        let diskURL = memoryImg == nil ? OnlineImageLoader.shared.cachedDiskFileURL(for: url) : nil
        guard memoryImg != nil || diskURL != nil else { return }

        localWarmingURLs.insert(url)
        let maxPixel = Self.maxThumbnailPixelSize
        let cache = thumbCache

        Task.detached(priority: .utility) { [weak self] in
            let generated: ReaderPageThumbnail?
            if let memoryImg {
                generated = Self.buildThumbnailAsset(from: memoryImg, maxPixelSize: maxPixel)
            } else if let diskURL {
                generated = Self.buildThumbnailAsset(fromDiskFile: diskURL, maxPixelSize: maxPixel)
            } else {
                generated = nil
            }

            if let generated {
                cache.storage.setObject(generated, forKey: url as NSString, cost: Self.assetPixelCost(of: generated))
            }

            await MainActor.run {
                guard let self else { return }
                self.localWarmingURLs.remove(url)
                if generated != nil {
                    self.version &+= 1
                }
            }
        }
    }

    private func fetchAndGenerateThumbnail(for page: MangaPage) async {
        let url = page.imageURL
        guard !url.isEmpty, !Task.isCancelled else { return }
        guard cachedThumbnailAsset(for: url) == nil else { return }
        guard !inFlightURLs.contains(url) else { return }

        inFlightURLs.insert(url)
        defer {
            inFlightURLs.remove(url)
        }

        do {
            let fullImage = try await OnlineImageLoader.shared.loadImage(
                urlString: url,
                headers: page.headers
            )
            guard !Task.isCancelled else { return }

            let maxPixel = Self.maxThumbnailPixelSize
            let downsampled = await Task.detached(priority: .utility) {
                Self.buildThumbnailAsset(from: fullImage, maxPixelSize: maxPixel)
            }.value

            guard !Task.isCancelled, let thumbAsset = downsampled else { return }
            thumbCache.storage.setObject(thumbAsset, forKey: url as NSString, cost: Self.assetPixelCost(of: thumbAsset))
            version &+= 1
        } catch {
            // 悬停预览拉取失败或取消时静默回退页码卡片
        }
    }

    // MARK: - 后台降采样与韩漫长图智能三格分镜切片

    private nonisolated static func buildThumbnailAsset(
        fromDiskFile fileURL: URL,
        maxPixelSize: CGFloat
    ) -> ReaderPageThumbnail? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        // 先零开销探测原图尺寸与方向，区分普通单页与韩漫长图
        let (origW, origH) = probeImageDimensions(from: source)
        let aspectRatio: CGFloat = (origW > 0 && origH > 0) ? (origH / origW) : 1.4

        if aspectRatio >= longStripAspectThreshold, origW > 0, origH > 0 {
            let targetW = min(origW, longStripTargetWidth)
            let targetH = min(longStripMaxWorkingHeight, targetW * aspectRatio)
            let decodeMaxSide = max(targetW, targetH)
            let stripOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: decodeMaxSide
            ]
            if let workingCG = CGImageSourceCreateThumbnailAtIndex(source, 0, stripOptions as CFDictionary) {
                return buildLongStripAsset(from: workingCG, originalAspect: aspectRatio)
            }
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let resolvedAspect = cgImage.width > 0 ? (CGFloat(cgImage.height) / CGFloat(cgImage.width)) : aspectRatio
        if resolvedAspect >= longStripAspectThreshold {
            return buildLongStripAsset(from: cgImage, originalAspect: resolvedAspect)
        }
        let img = UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
        return ReaderPageThumbnail(primaryThumbnail: img, longStripFrames: nil, originalAspectRatio: resolvedAspect)
    }

    private nonisolated static func buildThumbnailAsset(
        from image: UIImage,
        maxPixelSize: CGFloat
    ) -> ReaderPageThumbnail? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let pixelW = size.width * image.scale
        let pixelH = size.height * image.scale
        let aspectRatio = pixelH / max(pixelW, 1)

        if aspectRatio >= longStripAspectThreshold {
            let targetW = min(pixelW, longStripTargetWidth)
            let targetH = min(longStripMaxWorkingHeight, max(targetW * 2.0, targetW * aspectRatio))
            let workingSize = CGSize(width: max(1, floor(targetW)), height: max(1, floor(targetH)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1.0
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: workingSize, format: format)
            let resized = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: workingSize))
            }
            if let cg = resized.cgImage {
                return buildLongStripAsset(from: cg, originalAspect: aspectRatio)
            }
        }

        let longest = max(pixelW, pixelH)
        let ratio = min(1.0, maxPixelSize / longest)
        let targetSize = CGSize(
            width: max(1, floor(pixelW * ratio)),
            height: max(1, floor(pixelH * ratio))
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return ReaderPageThumbnail(primaryThumbnail: rendered, longStripFrames: nil, originalAspectRatio: aspectRatio)
    }

    /// 探测磁盘图片原始像素尺寸（自动考虑 EXIF 旋转）
    private nonisolated static func probeImageDimensions(from source: CGImageSource) -> (CGFloat, CGFloat) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let wNum = props[kCGImagePropertyPixelWidth] as? NSNumber,
              let hNum = props[kCGImagePropertyPixelHeight] as? NSNumber else {
            return (0, 0)
        }
        let w = CGFloat(wNum.doubleValue)
        let h = CGFloat(hNum.doubleValue)
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return (h, w)
        }
        return (w, h)
    }

    /// 对韩漫长图按「上 / 中 / 下」三段智能跳过纯白/纯黑留白，裁出 3 张高清分镜切片
    private nonisolated static func buildLongStripAsset(
        from workingCG: CGImage,
        originalAspect: CGFloat
    ) -> ReaderPageThumbnail {
        let w = workingCG.width
        let h = workingCG.height
        let fallbackImg = UIImage(cgImage: workingCG, scale: 1.0, orientation: .up)
        guard w >= 16, h >= 32 else {
            return ReaderPageThumbnail(primaryThumbnail: fallbackImg, longStripFrames: nil, originalAspectRatio: originalAspect)
        }

        let frameH = min(h, max(16, Int((CGFloat(w) * stripFrameAspect).rounded())))
        let maxStartY = max(0, h - frameH)
        guard maxStartY > 0 else {
            return ReaderPageThumbnail(primaryThumbnail: fallbackImg, longStripFrames: nil, originalAspectRatio: originalAspect)
        }

        // 计算极低开销的纵向画面信息密度曲线（跳过纯白/纯黑转场留白）
        let rowEnergies = computeVerticalRowEnergy(from: workingCG)
        let energyCount = rowEnergies.count

        // 上 / 中 / 下三个候选搜索区间（归一化起点范围）
        let ranges: [(Double, Double)] = [
            (0.0, 0.34),
            (0.32, 0.68),
            (0.66, 1.0)
        ]

        var frames: [UIImage] = []
        var frameScores: [Double] = []
        frames.reserveCapacity(3)
        frameScores.reserveCapacity(3)

        let windowFraction = Double(frameH) / Double(h)

        for (segIdx, range) in ranges.enumerated() {
            let idealStartFrac: Double
            switch segIdx {
            case 0: idealStartFrac = 0.0
            case 1: idealStartFrac = max(0, (1.0 - windowFraction) * 0.5)
            default: idealStartFrac = max(0, 1.0 - windowFraction)
            }

            let bestResult = findBestContentStartY(
                rowEnergies: rowEnergies,
                imageHeight: h,
                frameHeight: frameH,
                searchMinFrac: range.0,
                searchMaxFrac: range.1,
                fallbackStartFrac: idealStartFrac
            )

            let cropRect = CGRect(
                x: 0,
                y: min(max(0, bestResult.startY), maxStartY),
                width: w,
                height: frameH
            )

            if let cropped = workingCG.cropping(to: cropRect) {
                frames.append(UIImage(cgImage: cropped, scale: 1.0, orientation: .up))
                frameScores.append(bestResult.score)
            }
        }

        guard frames.count == 3 else {
            return ReaderPageThumbnail(
                primaryThumbnail: frames.first ?? fallbackImg,
                longStripFrames: frames.isEmpty ? nil : frames,
                originalAspectRatio: originalAspect
            )
        }

        // 底部微弧小卡优先用「上段」有效画面；若上段几乎是空白标题页而中段内容明显更丰富，自动改用信息量最高的切片
        let primary: UIImage
        if energyCount > 0, frameScores[0] < 4.0, frameScores[1] > frameScores[0] * 2.2 {
            primary = frames[1]
        } else {
            primary = frames[0]
        }

        return ReaderPageThumbnail(
            primaryThumbnail: primary,
            longStripFrames: frames,
            originalAspectRatio: originalAspect
        )
    }

    /// 将长图缩至极小灰度探测带（宽 24px，高 <= 240px），统计每行像素方差与垂直梯度以识别有效漫画画格
    private nonisolated static func computeVerticalRowEnergy(from cgImage: CGImage) -> [Double] {
        let probeW = 24
        let probeH = min(240, max(24, Int((CGFloat(cgImage.height) / max(CGFloat(cgImage.width), 1) * CGFloat(probeW)).rounded())))
        var gray = [UInt8](repeating: 255, count: probeW * probeH)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray,
            width: probeW,
            height: probeH,
            bitsPerComponent: 8,
            bytesPerRow: probeW,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return []
        }

        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: probeW, height: probeH))

        var energies = [Double](repeating: 0, count: probeH)
        for y in 0..<probeH {
            let rowOffset = y * probeW
            var diffSum = 0.0
            for x in 1..<probeW {
                diffSum += abs(Double(gray[rowOffset + x]) - Double(gray[rowOffset + x - 1]))
            }
            if y > 0 {
                let prevOffset = (y - 1) * probeW
                for x in 0..<probeW {
                    diffSum += abs(Double(gray[rowOffset + x]) - Double(gray[prevOffset + x])) * 0.5
                }
            }
            energies[y] = diffSum / Double(probeW)
        }
        return energies
    }

    /// 在指定纵向区间内滑动搜索信息量最高（最非纯白/纯黑留白）的窗口起始 Y 像素
    private nonisolated static func findBestContentStartY(
        rowEnergies: [Double],
        imageHeight: Int,
        frameHeight: Int,
        searchMinFrac: Double,
        searchMaxFrac: Double,
        fallbackStartFrac: Double
    ) -> (startY: Int, score: Double) {
        let maxStartY = max(0, imageHeight - frameHeight)
        let fallbackY = min(maxStartY, max(0, Int((fallbackStartFrac * Double(imageHeight)).rounded())))
        guard !rowEnergies.isEmpty, imageHeight > frameHeight else {
            return (fallbackY, 0)
        }

        let n = rowEnergies.count
        let winRows = max(1, min(n, Int((Double(frameHeight) / Double(imageHeight) * Double(n)).rounded())))
        let maxRowStart = max(0, n - winRows)

        let minRow = min(maxRowStart, max(0, Int((searchMinFrac * Double(n)).rounded())))
        let rawMaxEnd = min(n, max(minRow + winRows, Int((searchMaxFrac * Double(n)).rounded())))
        let maxRow = min(maxRowStart, max(minRow, rawMaxEnd - winRows))

        // 构建前缀和，O(1) 计算任意窗口总信息量
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n {
            prefix[i + 1] = prefix[i] + rowEnergies[i]
        }

        var bestRow = minRow
        var bestScore = -1.0
        for startRow in minRow...maxRow {
            let endRow = min(n, startRow + winRows)
            let avgScore = (prefix[endRow] - prefix[startRow]) / Double(max(1, endRow - startRow))
            if avgScore > bestScore {
                bestScore = avgScore
                bestRow = startRow
            }
        }

        // 若整个区间几乎完全空白（分数极低），退回自然均匀分布位置
        if bestScore < 1.2 {
            return (fallbackY, bestScore)
        }

        let mappedY = Int((Double(bestRow) / Double(max(1, n)) * Double(imageHeight)).rounded())
        return (min(maxStartY, max(0, mappedY)), bestScore)
    }

    private nonisolated static func assetPixelCost(of asset: ReaderPageThumbnail) -> Int {
        var total = pixelCost(of: asset.primaryThumbnail)
        if let frames = asset.longStripFrames {
            for f in frames {
                total += pixelCost(of: f)
            }
        }
        return total
    }

    private nonisolated static func pixelCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(1, cg.width * cg.height * 4)
        }
        return max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
}
