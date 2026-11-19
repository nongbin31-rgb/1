import CryptoKit
import Foundation
import UIKit

/// 在线漫画图片异步加载与双层缓存（内存 + 磁盘），同时支持 synthetic:// 超分基准测试页生成
public actor OnlineImageLoader {
    public static let shared = OnlineImageLoader()

    private let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 120 * 1024 * 1024
        return cache
    }()

    private let diskDirectory: URL
    private var inFlightTasks: [String: Task<UIImage, Error>] = [:]

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = caches.appendingPathComponent("OnlineMangaImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.diskDirectory = dir
    }

    public func loadImage(urlString: String, headers: [String: String] = [:]) async throws -> UIImage {
        let cacheKey = urlString as NSString
        if let memImage = memoryCache.object(forKey: cacheKey) {
            return memImage
        }

        if urlString.hasPrefix("synthetic://") {
            let synthetic = Self.renderSyntheticMangaImage(urlString: urlString)
            memoryCache.setObject(synthetic, forKey: cacheKey)
            return synthetic
        }

        let diskPath = diskFileURL(for: urlString)
        if let data = try? Data(contentsOf: diskPath), let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: cacheKey, cost: data.count)
            return diskImage
        }

        if let existingTask = inFlightTasks[urlString] {
            return try await existingTask.value
        }

        let task = Task<UIImage, Error> {
            guard let url = URL(string: urlString) else {
                throw MangaSourceError.invalidURL(urlString)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            for (k, v) in headers {
                request.setValue(v, forHTTPHeaderField: k)
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MangaSourceError.httpError(http.statusCode)
            }
            guard let image = UIImage(data: data) else {
                throw MangaSourceError.decodingFailed("响应内容不是有效的图片数据")
            }

            try? data.write(to: diskPath, options: .atomic)
            return image
        }

        inFlightTasks[urlString] = task
        do {
            let image = try await task.value
            inFlightTasks.removeValue(forKey: urlString)
            memoryCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            inFlightTasks.removeValue(forKey: urlString)
            throw error
        }
    }

    public func clearAllCache() {
        memoryCache.removeAllObjects()
        try? FileManager.default.removeItem(at: diskDirectory)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
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

    private func diskFileURL(for key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory.appendingPathComponent(hash)
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
