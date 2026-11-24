import CoreGraphics
import Foundation
import Vision
#if canImport(UIKit)
import UIKit
#endif

/// OCR 聚类产出的单个原文对话气泡（归一化左上角坐标系 0...1）
public struct DetectedTextBubble: Sendable {
    public let rect: CGRect
    public let text: String
    public let isVertical: Bool

    public init(rect: CGRect, text: String, isVertical: Bool) {
        self.rect = rect
        self.text = text
        self.isVertical = isVertical
    }
}

#if canImport(UIKit)
/// 基于 Apple 原生 Vision 的漫画文字识别与竖排/横排气泡聚类引擎（iOS 15 ~ iOS 26 全兼容）
public enum MangaVisionOCR {
    private struct RawLine {
        let rect: CGRect      // 归一化左上角坐标系 0...1
        let text: String
        let isVertical: Bool
    }

    public static func recognizeBubbles(
        in image: UIImage,
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> [DetectedTextBubble] {
        guard let cgImage = normalizedCGImage(from: image) else {
            return []
        }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = sourceLanguage.visionRecognitionLanguages
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = (sourceLanguage == .auto)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            try handler.perform([request])

            let observations = request.results ?? []
            var rawLines: [RawLine] = []
            rawLines.reserveCapacity(observations.count)

            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, !shouldIgnoreNoiseText(text) else { continue }

                // Vision 坐标原点在左下角，转换为左上角原点归一化坐标
                let box = obs.boundingBox
                let topLeftRect = CGRect(
                    x: max(0, min(1, box.origin.x)),
                    y: max(0, min(1, 1.0 - box.origin.y - box.size.height)),
                    width: max(0, min(1, box.size.width)),
                    height: max(0, min(1, box.size.height))
                )

                // 忽略极微小的杂点（例如网点误识别）
                guard topLeftRect.width >= 0.008 || topLeftRect.height >= 0.008 else { continue }
                guard topLeftRect.width * topLeftRect.height >= 0.00009 else { continue }

                let charCount = text.count
                let aspect = topLeftRect.height / max(topLeftRect.width, 0.0001)
                let isVertical = (charCount >= 2 && aspect > 1.22) || (charCount == 1 && containsCJK(text) && aspect > 1.35)
                rawLines.append(RawLine(rect: topLeftRect, text: text, isVertical: isVertical))
            }

            return clusterLinesIntoBubbles(rawLines)
        }.value
    }

    // MARK: - Bubble Clustering (Vertical Japanese + Horizontal Dialog)

    private static func clusterLinesIntoBubbles(_ lines: [RawLine]) -> [DetectedTextBubble] {
        guard !lines.isEmpty else { return [] }
        let n = lines.count
        var parent = Array(0..<n)

        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var cur = x
            while parent[cur] != r {
                let next = parent[cur]
                parent[cur] = r
                cur = next
            }
            return r
        }

        func unite(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for i in 0..<n {
            for j in (i + 1)..<n {
                if shouldMerge(lines[i], lines[j]) {
                    unite(i, j)
                }
            }
        }

        var groups: [Int: [RawLine]] = [:]
        for i in 0..<n {
            groups[find(i), default: []].append(lines[i])
        }

        var bubbles: [DetectedTextBubble] = []
        bubbles.reserveCapacity(groups.count)

        for (_, group) in groups {
            let verticalVotes = group.filter(\.isVertical).count
            let cjkVotes = group.filter { containsCJK($0.text) }.count
            let groupIsVertical = verticalVotes * 2 >= group.count
                || (cjkVotes == group.count && group.count > 1 && isHorizontallyDistributed(group))

            let sorted: [RawLine]
            if groupIsVertical {
                // 日漫竖排气泡：从右到左，同列从上到下
                sorted = group.sorted { a, b in
                    let colThreshold = max(a.rect.width, b.rect.width) * 0.55
                    if abs(a.rect.midX - b.rect.midX) > colThreshold {
                        return a.rect.midX > b.rect.midX
                    }
                    return a.rect.minY < b.rect.minY
                }
            } else {
                // 常规横排气泡：从上到下，同行从左到右
                sorted = group.sorted { a, b in
                    let rowThreshold = max(a.rect.height, b.rect.height) * 0.55
                    if abs(a.rect.midY - b.rect.midY) > rowThreshold {
                        return a.rect.minY < b.rect.minY
                    }
                    return a.rect.minX < b.rect.minX
                }
            }

            var unionRect = sorted[0].rect
            for line in sorted.dropFirst() {
                unionRect = unionRect.union(line.rect)
            }

            let joinedText = joinLines(sorted.map(\.text), isVertical: groupIsVertical)
            guard !joinedText.isEmpty, !shouldIgnoreNoiseText(joinedText) else { continue }

            bubbles.append(
                DetectedTextBubble(
                    rect: unionRect,
                    text: joinedText,
                    isVertical: groupIsVertical
                )
            )
        }

        // 按整体阅读顺序排序（大致从上到下，同行从右到左）
        bubbles.sort { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 0.14 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.midX > rhs.rect.midX
        }
        return bubbles
    }

    private static func shouldMerge(_ a: RawLine, _ b: RawLine) -> Bool {
        let ra = a.rect
        let rb = b.rect

        // 水平与垂直方向上的间隙（重叠时为负）
        let hGap = max(0, max(ra.minX, rb.minX) - min(ra.maxX, rb.maxX))
        let vGap = max(0, max(ra.minY, rb.minY) - min(ra.maxY, rb.maxY))

        let vOverlap = min(ra.maxY, rb.maxY) - max(ra.minY, rb.minY)
        let hOverlap = min(ra.maxX, rb.maxX) - max(ra.minX, rb.minX)

        // 竖排相邻列（同一日漫气泡里的多列竖排字）
        let likelyVerticalPair = a.isVertical || b.isVertical || (containsCJK(a.text) && containsCJK(b.text))
        if likelyVerticalPair {
            let maxColWidth = max(ra.width, rb.width)
            let minHeight = min(ra.height, rb.height)
            // 相邻两列水平距离小于 1.55 倍单列宽，且垂直方向明显重叠或极接近
            if hGap <= max(maxColWidth * 1.55, 0.028) && (vOverlap > -0.022 || vGap <= minHeight * 0.35) {
                // 避免合并跨越两个完全不同气泡的超大矩形
                let union = ra.union(rb)
                if union.width <= 0.42 && union.height <= 0.55 {
                    return true
                }
            }
            // 同列上下断开的两段竖排字
            if hOverlap > min(ra.width, rb.width) * 0.35 && vGap <= max(maxColWidth * 1.4, 0.026) {
                return true
            }
        }

        // 横排相邻行（英语/韩漫/横排中文气泡）
        let maxRowHeight = max(ra.height, rb.height)
        if vGap <= max(maxRowHeight * 1.35, 0.020) && (hOverlap > -0.025 || hGap <= maxRowHeight * 1.2) {
            let union = ra.union(rb)
            if union.width <= 0.65 && union.height <= 0.45 {
                return true
            }
        }

        return false
    }

    private static func isHorizontallyDistributed(_ group: [RawLine]) -> Bool {
        guard group.count >= 2 else { return false }
        var union = group[0].rect
        for line in group.dropFirst() { union = union.union(line.rect) }
        let avgW = group.reduce(0.0) { $0 + $1.rect.width } / Double(group.count)
        let avgH = group.reduce(0.0) { $0 + $1.rect.height } / Double(group.count)
        return union.width > avgW * 1.6 && avgH >= avgW * 0.85
    }

    private static func joinLines(_ texts: [String], isVertical: Bool) -> String {
        guard !texts.isEmpty else { return "" }
        if isVertical {
            return texts.joined()
        }
        var output = ""
        for part in texts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if output.isEmpty {
                output = trimmed
            } else if containsCJK(String(output.suffix(1))) || containsCJK(String(trimmed.prefix(1))) {
                output += trimmed
            } else {
                output += " " + trimmed
            }
        }
        return output
    }

    private static func shouldIgnoreNoiseText(_ text: String) -> Bool {
        let stripped = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return true }
        // 过滤纯页码数字（如 "12" / "004"）和纯标点符号
        let alnum = stripped.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if alnum.isEmpty {
            return true
        }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0xAC00...0xD7AF).contains(v)
                || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func normalizedCGImage(from image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.cgImage
    }
}

/// 高精度无损气泡译文渲染器（按原图分辨率边缘取色遮盖 + 自适应字号居中排版）
public enum MangaBubbleOverlayRenderer {
    public static func render(
        baseImage: UIImage,
        bubbles: [TranslatedBubble]
    ) -> UIImage {
        guard !bubbles.isEmpty else { return baseImage }

        let pixelWidth: CGFloat
        let pixelHeight: CGFloat
        if let cg = baseImage.cgImage {
            pixelWidth = CGFloat(cg.width)
            pixelHeight = CGFloat(cg.height)
        } else {
            pixelWidth = baseImage.size.width * baseImage.scale
            pixelHeight = baseImage.size.height * baseImage.scale
        }
        guard pixelWidth > 16, pixelHeight > 16 else { return baseImage }

        let canvasSize = CGSize(width: pixelWidth, height: pixelHeight)
        let sampler = BubbleBackgroundSampler(image: baseImage)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)

        return renderer.image { ctx in
            let cgCtx = ctx.cgContext
            baseImage.draw(in: CGRect(origin: .zero, size: canvasSize))

            for bubble in bubbles {
                let text = bubble.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                let rawRect = CGRect(
                    x: CGFloat(bubble.x) * pixelWidth,
                    y: CGFloat(bubble.y) * pixelHeight,
                    width: CGFloat(bubble.width) * pixelWidth,
                    height: CGFloat(bubble.height) * pixelHeight
                )
                guard rawRect.width >= 6, rawRect.height >= 6 else { continue }

                // 适度外扩覆盖原文残留笔画，并给中文留出舒适内边距
                let padX = max(rawRect.width * 0.14, pixelWidth * 0.008)
                let padY = max(rawRect.height * 0.12, pixelHeight * 0.006)
                var boxRect = rawRect.insetBy(dx: -padX, dy: -padY)

                // 如果框极细长（例如单列竖排日文转为横排中文），适当拉宽以提高中文可读性
                let minReadableWidth = min(pixelWidth * 0.24, max(rawRect.width * 1.75, pixelWidth * 0.075))
                if bubble.isVertical && boxRect.width < minReadableWidth && text.count >= 4 {
                    let expand = (minReadableWidth - boxRect.width) * 0.5
                    boxRect = boxRect.insetBy(dx: -expand, dy: 0)
                }

                // 限制在画布安全范围内
                let canvasBounds = CGRect(origin: .zero, size: canvasSize).insetBy(dx: 4, dy: 4)
                boxRect = boxRect.intersection(canvasBounds)
                guard boxRect.width >= 16, boxRect.height >= 16 else { continue }

                // 采样气泡周边真实底色，自动适配白底对话框与黑底独白框
                let bgSample = sampler.sampleBackgroundColor(around: bubble.normalizedRect)
                let isDarkBubble = bgSample.luminance < 0.44
                let fillColor: UIColor = isDarkBubble
                    ? bgSample.color.withAlphaComponent(0.95)
                    : bgSample.color.withAlphaComponent(0.96)
                let textColor: UIColor = isDarkBubble ? .white : UIColor(white: 0.08, alpha: 1.0)
                let borderColor: UIColor = isDarkBubble
                    ? UIColor.white.withAlphaComponent(0.14)
                    : UIColor.black.withAlphaComponent(0.08)

                let cornerRadius = min(min(boxRect.width, boxRect.height) * 0.26, 22)
                let roundedPath = UIBezierPath(roundedRect: boxRect, cornerRadius: cornerRadius)

                cgCtx.saveGState()
                // 柔和外阴影/羽化边缘，使遮罩自然融入气泡纸面
                cgCtx.setShadow(
                    offset: .zero,
                    blur: max(3, min(boxRect.width, boxRect.height) * 0.06),
                    color: fillColor.cgColor
                )
                fillColor.setFill()
                roundedPath.fill()
                cgCtx.restoreGState()

                borderColor.setStroke()
                roundedPath.lineWidth = max(1.0, pixelWidth * 0.0012)
                roundedPath.stroke()

                // 文本绘制区域（留出内边距）
                let insetX = max(boxRect.width * 0.08, 4)
                let insetY = max(boxRect.height * 0.08, 4)
                let textArea = boxRect.insetBy(dx: insetX, dy: insetY)
                guard textArea.width >= 8, textArea.height >= 8 else { continue }

                let (font, paragraphStyle, textHeight) = fitChineseFont(
                    for: text,
                    in: textArea.size,
                    canvasWidth: pixelWidth
                )

                let drawRect = CGRect(
                    x: textArea.minX,
                    y: textArea.minY + max(0, (textArea.height - textHeight) * 0.5),
                    width: textArea.width,
                    height: min(textArea.height, textHeight + 2)
                )

                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                    .paragraphStyle: paragraphStyle
                ]

                (text as NSString).draw(
                    with: drawRect,
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attributes,
                    context: nil
                )
            }
        }
    }

    private static func fitChineseFont(
        for text: String,
        in size: CGSize,
        canvasWidth: CGFloat
    ) -> (UIFont, NSParagraphStyle, CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5

        let maxFontSize = max(14, min(canvasWidth * 0.044, size.height * 0.72, 62))
        let minFontSize = max(9, min(canvasWidth * 0.015, 13))

        var low = minFontSize
        var high = maxFontSize
        var bestSize = minFontSize
        var bestHeight = size.height

        let nsText = text as NSString
        let constraint = CGSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)

        for _ in 0..<9 {
            let mid = (low + high) * 0.5
            let font = UIFont.systemFont(ofSize: mid, weight: .semibold)
            paragraph.lineSpacing = max(1.0, mid * 0.10)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .paragraphStyle: paragraph
            ]
            let measured = nsText.boundingRect(
                with: constraint,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs,
                context: nil
            )
            if ceil(measured.height) <= size.height && ceil(measured.width) <= size.width + 1 {
                bestSize = mid
                bestHeight = ceil(measured.height)
                low = mid
            } else {
                high = mid
            }
        }

        let finalFont = UIFont.systemFont(ofSize: bestSize, weight: .semibold)
        paragraph.lineSpacing = max(1.0, bestSize * 0.10)
        return (finalFont, paragraph, bestHeight)
    }
}

/// 轻量级气泡背景像素采样器（缩略至 160px 宽进行快速边缘取色，单页耗时 < 1.5ms）
private final class BubbleBackgroundSampler {
    private let width: Int
    private let height: Int
    private let pixels: [UInt8]

    init(image: UIImage) {
        guard let cg = image.cgImage else {
            self.width = 0
            self.height = 0
            self.pixels = []
            return
        }

        let targetW = min(160, max(16, cg.width))
        let aspect = CGFloat(cg.height) / max(CGFloat(cg.width), 1)
        let targetH = max(16, Int((CGFloat(targetW) * aspect).rounded()))

        var buffer = [UInt8](repeating: 255, count: targetW * targetH * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        if let context = CGContext(
            data: &buffer,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) {
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
            self.width = targetW
            self.height = targetH
            self.pixels = buffer
        } else {
            self.width = 0
            self.height = 0
            self.pixels = []
        }
    }

    func sampleBackgroundColor(around normalizedRect: CGRect) -> (color: UIColor, luminance: CGFloat) {
        guard width > 0, height > 0 else {
            return (.white, 1.0)
        }

        let minX = normalizedRect.minX
        let maxX = normalizedRect.maxX
        let minY = normalizedRect.minY
        let maxY = normalizedRect.maxY
        let midX = normalizedRect.midX
        let midY = normalizedRect.midY
        let marginX = max(normalizedRect.width * 0.08, 0.008)
        let marginY = max(normalizedRect.height * 0.08, 0.006)

        let points: [(CGFloat, CGFloat)] = [
            (minX - marginX, midY),
            (maxX + marginX, midY),
            (midX, minY - marginY),
            (midX, maxY + marginY),
            (minX - marginX, minY - marginY),
            (maxX + marginX, minY - marginY),
            (minX - marginX, maxY + marginY),
            (maxX + marginX, maxY + marginY),
        ]

        var samples: [(r: CGFloat, g: CGFloat, b: CGFloat, lum: CGFloat)] = []
        for (nx, ny) in points {
            let px = min(max(Int((nx * CGFloat(width - 1)).rounded()), 0), width - 1)
            let py = min(max(Int((ny * CGFloat(height - 1)).rounded()), 0), height - 1)
            let idx = (py * width + px) * 4
            let r = CGFloat(pixels[idx]) / 255.0
            let g = CGFloat(pixels[idx + 1]) / 255.0
            let b = CGFloat(pixels[idx + 2]) / 255.0
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            samples.append((r, g, b, lum))
        }

        // 按亮度排序取中位样本（忽略压到黑线/网点的极端采样点）
        samples.sort { $0.lum < $1.lum }
        let chosen = samples[min(samples.count - 1, Int(Double(samples.count) * 0.62))]
        if chosen.lum > 0.85 {
            // 常规浅白漫画气泡，保持干净统一的柔白色
            let cleanColor = UIColor(
                red: min(1.0, chosen.r * 0.4 + 0.6),
                green: min(1.0, chosen.g * 0.4 + 0.6),
                blue: min(1.0, chosen.b * 0.4 + 0.6),
                alpha: 1.0
            )
            return (cleanColor, chosen.lum)
        }
        return (UIColor(red: chosen.r, green: chosen.g, blue: chosen.b, alpha: 1.0), chosen.lum)
    }
}
#endif
