import Combine
import Foundation
import ImageIO
import UIKit

/// 在线阅读器进度条扇面缩略图缓存与防抖点载协调器
/// - 优先零网络复用内存原图或磁盘缓存（通过 ImageIO 直接按目标像素尺寸硬件降采样，不占用全图内存）
/// - 对未缓存页面：快速拖动时不发请求，仅在手指悬停 >= 180ms 后静默按需预取聚焦页及左右相邻各 1 页
@MainActor
public final class ReaderThumbnailStore: ObservableObject {
    public static let shared = ReaderThumbnailStore()

    private final class SendableThumbnailCache: @unchecked Sendable {
        let storage = NSCache<NSString, UIImage>()

        init() {
            storage.countLimit = 260
            storage.totalCostLimit = 32 * 1024 * 1024
        }
    }

    @Published public private(set) var version: UInt = 0
    @Published public private(set) var inFlightURLs: Set<String> = []

    private let thumbCache = SendableThumbnailCache()
    private var localWarmingURLs: Set<String> = []
    private var hoverTask: Task<Void, Never>?
    private var lastHoverPageKey: String?

    private static let maxThumbnailPixelSize: CGFloat = 280

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
            let generated: UIImage?
            if let memoryImg {
                generated = Self.downsample(image: memoryImg, maxPixelSize: maxPixel)
            } else if let diskURL {
                generated = Self.downsampleDiskFile(at: diskURL, maxPixelSize: maxPixel)
            } else {
                generated = nil
            }

            if let generated {
                cache.storage.setObject(generated, forKey: url as NSString, cost: Self.pixelCost(of: generated))
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
        guard cachedThumbnail(for: url) == nil else { return }
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
                Self.downsample(image: fullImage, maxPixelSize: maxPixel)
            }.value

            guard !Task.isCancelled, let thumb = downsampled else { return }
            thumbCache.storage.setObject(thumb, forKey: url as NSString, cost: Self.pixelCost(of: thumb))
            version &+= 1
        } catch {
            // 悬停预览拉取失败或取消时静默回退页码卡片
        }
    }

    // MARK: - 后台降采样工具

    private nonisolated static func downsampleDiskFile(at fileURL: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions as CFDictionary) else {
            return nil
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
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .up)
    }

    private nonisolated static func downsample(image: UIImage, maxPixelSize: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let pixelW = size.width * image.scale
        let pixelH = size.height * image.scale
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
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private nonisolated static func pixelCost(of image: UIImage) -> Int {
        if let cg = image.cgImage {
            return max(1, cg.width * cg.height * 4)
        }
        return max(1, Int(image.size.width * image.size.height * image.scale * image.scale * 4))
    }
}
