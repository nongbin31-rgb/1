import CoreGraphics
import CoreImage
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
///
/// 采用三阶段融合扫描，重点攻克 Apple Vision 在复杂漫画网点背景下对日漫竖排小字漏检的问题：
/// 1. 显式多语种基准全图扫描（关闭干扰竖排检测的 automaticallyDetectsLanguage）；
/// 2. 轻量级灰度连通域气泡检测 + 原图高清裁切放大 + 纯白安全边距精识；
/// 3. 2×2 重叠高密分块补扫（覆盖灰底/无框旁白/彩漫等非白底区域）+ IoU/包含关系去重 + 气泡约束聚类。
public enum MangaVisionOCR {
    private struct RawLine {
        let rect: CGRect      // 归一化左上角坐标系 0...1
        let text: String
        let isVertical: Bool
        let confidence: Float
        let sourcePriority: Int // 2 = 气泡高清裁切, 1 = 重叠网格分块, 0 = 全图基准
        let bubbleHintIndex: Int?
    }

    private struct BubbleCandidate {
        let rect: CGRect // 归一化左上角坐标系 0...1
        let inkRatio: Double
    }

    private static let sharedCIContext: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    /// 当前系统与 Vision Revision 实际支持的精确识别语种集合（进程内只查询一次，兼容 iOS 15 ~ iOS 26）
    private static let supportedAccurateLanguages: Set<String> = {
        let probe = VNRecognizeTextRequest()
        if #available(iOS 16.0, *) {
            probe.revision = VNRecognizeTextRequestRevision3
        }
        probe.recognitionLevel = .accurate
        if let supported = try? probe.supportedRecognitionLanguages(), !supported.isEmpty {
            return Set(supported)
        }
        return []
    }()

    public static func recognizeBubbles(
        in image: UIImage,
        sourceLanguage: MangaTranslationSourceLanguage
    ) async throws -> [DetectedTextBubble] {
        guard let cgImage = normalizedCGImage(from: image) else {
            return []
        }

        return try await Task.detached(priority: .userInitiated) {
            let languages = effectiveRecognitionLanguages(for: sourceLanguage)
            var collectedLines: [RawLine] = []

            // 阶段 1：检测白底/亮底漫画对话气泡候选区域（耗时约 5~12ms）
            let bubbleCandidates = detectLightBubbleCandidates(in: cgImage)

            // 阶段 2：优先对每个气泡候选区域做原图高清裁切 + 放大 + 补白边精识（彻底剥离背景网点干扰）
            for (idx, candidate) in bubbleCandidates.enumerated() {
                try Task.checkCancellation()
                let cropLines = recognizeInSubregion(
                    cgImage: cgImage,
                    normalizedROI: candidate.rect,
                    languages: languages,
                    minTargetLongEdge: 760,
                    maxTargetLongEdge: 1120,
                    whiteBorderPixels: 28,
                    enhanceContrast: false,
                    sourcePriority: 2,
                    bubbleHintIndex: idx
                )
                if !cropLines.isEmpty {
                    collectedLines.append(contentsOf: cropLines)
                } else {
                    // 气泡内含明显墨水字但常规识别未命中时，对裁切块做对比度拉伸 + 锐化二次精识
                    let boostedLines = recognizeInSubregion(
                        cgImage: cgImage,
                        normalizedROI: candidate.rect,
                        languages: languages,
                        minTargetLongEdge: 880,
                        maxTargetLongEdge: 1200,
                        whiteBorderPixels: 32,
                        enhanceContrast: true,
                        sourcePriority: 2,
                        bubbleHintIndex: idx
                    )
                    collectedLines.append(contentsOf: boostedLines)
                }
            }

            // 阶段 3：整页基准扫描（捕获大标题、跨框字、黑底白字独白框等）
            try Task.checkCancellation()
            let fullPageLines = recognizeOnCGImage(
                cgImage,
                languages: languages,
                minimumTextHeight: 0.008,
                sourcePriority: 0,
                bubbleHintIndex: nil
            )
            collectedLines.append(contentsOf: fullPageLines)

            // 阶段 4：2×2 重叠网格高密补扫（提升非白底气泡、灰底旁白框、全彩条漫与细小竖排字的召回率）
            let tileROIs = buildOverlapTileROIs(width: cgImage.width, height: cgImage.height)
            for roi in tileROIs {
                try Task.checkCancellation()
                let tileLines = recognizeInSubregion(
                    cgImage: cgImage,
                    normalizedROI: roi,
                    languages: languages,
                    minTargetLongEdge: 1000,
                    maxTargetLongEdge: 1400,
                    whiteBorderPixels: 16,
                    enhanceContrast: false,
                    sourcePriority: 1,
                    bubbleHintIndex: nil
                )
                collectedLines.append(contentsOf: tileLines)
            }

            // 若前述全部通道召回极少（如扫描偏灰/低对比度漫画），对全图做一次对比度增强兜底补扫
            if collectedLines.count <= 1 {
                try Task.checkCancellation()
                if let boostedFull = makeContrastBoostedCGImage(from: cgImage) {
                    let fallbackLines = recognizeOnCGImage(
                        boostedFull,
                        languages: languages,
                        minimumTextHeight: 0.007,
                        sourcePriority: 0,
                        bubbleHintIndex: nil
                    )
                    collectedLines.append(contentsOf: fallbackLines)
                }
            }

            // 为全图/分块命中的文字补充归属气泡提示，便于聚类边界对齐
            let hintedLines = assignBubbleHints(to: collectedLines, candidates: bubbleCandidates)
            // 多通道结果去重（优先保留气泡高清裁切与更高置信度/更完整文本）
            let dedupedLines = deduplicateLines(hintedLines)
            // 竖排/横排并查集聚类 + 孤立噪点剔除
            return clusterLinesIntoBubbles(dedupedLines, bubbleCandidates: bubbleCandidates)
        }.value
    }

    // MARK: - Vision Recognition Core

    /// 显式指定识别语言顺序并关闭 automaticallyDetectsLanguage，避免 iOS 16+ 自动语种探测跳过日漫竖排假名；
    /// 同时按当前系统实际支持的语种过滤，避免 iOS 15（Vision Revision 2 不支持 ja-JP / ko-KR）传非法语种抛错返回空结果
    private static func effectiveRecognitionLanguages(for sourceLanguage: MangaTranslationSourceLanguage) -> [String] {
        let preferred: [String]
        switch sourceLanguage {
        case .auto:
            preferred = ["ja-JP", "zh-Hant", "ko-KR", "en-US"]
        case .japanese:
            preferred = ["ja-JP", "en-US"]
        case .english:
            preferred = ["en-US"]
        case .korean:
            preferred = ["ko-KR", "en-US"]
        case .traditionalChinese:
            preferred = ["zh-Hant", "zh-Hans"]
        }
        return filterSupportedLanguages(preferred)
    }

    private static func filterSupportedLanguages(_ preferred: [String]) -> [String] {
        guard !supportedAccurateLanguages.isEmpty else {
            return preferred
        }
        let filtered = preferred.filter { supportedAccurateLanguages.contains($0) }
        if !filtered.isEmpty {
            return filtered
        }
        let fallback = ["zh-Hant", "zh-Hans", "en-US"].filter { supportedAccurateLanguages.contains($0) }
        return fallback.isEmpty ? ["en-US"] : fallback
    }

    private static func buildOverlapTileROIs(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let aspect = Double(height) / Double(width)
        // 超长条漫（高宽比 > 2.2）采用纵向重叠分段，常规单页采用 2×2 重叠网格
        if aspect > 2.2 {
            let rows = min(5, max(3, Int(ceil(aspect / 1.1))))
            let step = 1.0 / Double(rows)
            let overlap = 0.08
            var rois: [CGRect] = []
            for r in 0..<rows {
                let y0 = max(0.0, Double(r) * step - (r > 0 ? overlap : 0))
                let y1 = min(1.0, Double(r + 1) * step + (r + 1 < rows ? overlap : 0))
                rois.append(CGRect(x: 0, y: y0, width: 1.0, height: max(0.05, y1 - y0)))
            }
            return rois
        }

        // 标准 2×2 重叠切片（每块 58% × 58%，16% 重叠防气泡被中缝切开）
        return [
            CGRect(x: 0.00, y: 0.00, width: 0.58, height: 0.58),
            CGRect(x: 0.42, y: 0.00, width: 0.58, height: 0.58),
            CGRect(x: 0.00, y: 0.42, width: 0.58, height: 0.58),
            CGRect(x: 0.42, y: 0.42, width: 0.58, height: 0.58),
        ]
    }

    private static func recognizeInSubregion(
        cgImage: CGImage,
        normalizedROI: CGRect,
        languages: [String],
        minTargetLongEdge: CGFloat,
        maxTargetLongEdge: CGFloat,
        whiteBorderPixels: CGFloat,
        enhanceContrast: Bool,
        sourcePriority: Int,
        bubbleHintIndex: Int?
    ) -> [RawLine] {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)
        guard imgW > 16, imgH > 16 else { return [] }

        let cropX = max(0, floor(normalizedROI.minX * imgW))
        let cropY = max(0, floor(normalizedROI.minY * imgH))
        let cropMaxX = min(imgW, ceil(normalizedROI.maxX * imgW))
        let cropMaxY = min(imgH, ceil(normalizedROI.maxY * imgH))
        let cropW = cropMaxX - cropX
        let cropH = cropMaxY - cropY
        guard cropW >= 24, cropH >= 24 else { return [] }

        let pixelRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        let actualNormROI = CGRect(
            x: cropX / imgW,
            y: cropY / imgH,
            width: cropW / imgW,
            height: cropH / imgH
        )

        return autoreleasepool {
            guard let cropped = cgImage.cropping(to: pixelRect) else { return [] }

            let longEdge = max(cropW, cropH)
            let scaleFactor: CGFloat
            if longEdge < minTargetLongEdge {
                scaleFactor = min(3.0, minTargetLongEdge / longEdge)
            } else if longEdge > maxTargetLongEdge {
                scaleFactor = maxTargetLongEdge / longEdge
            } else {
                scaleFactor = 1.0
            }

            let scaledW = max(1, (cropW * scaleFactor).rounded())
            let scaledH = max(1, (cropH * scaleFactor).rounded())
            let border = whiteBorderPixels
            let canvasW = scaledW + border * 2
            let canvasH = scaledH + border * 2

            guard let prepared = prepareSubregionCGImage(
                from: cropped,
                scaledSize: CGSize(width: scaledW, height: scaledH),
                border: border,
                enhanceContrast: enhanceContrast
            ) else {
                return []
            }

            let localLines = recognizeOnCGImage(
                prepared,
                languages: languages,
                minimumTextHeight: 0.015,
                sourcePriority: sourcePriority,
                bubbleHintIndex: bubbleHintIndex
            )

            // 将带白边的子图归一化坐标精准映射回整页归一化坐标 [0, 1]
            let contentNormX = border / canvasW
            let contentNormY = border / canvasH
            let contentNormW = scaledW / canvasW
            let contentNormH = scaledH / canvasH

            var mapped: [RawLine] = []
            mapped.reserveCapacity(localLines.count)

            for line in localLines {
                let lx0 = max(0, min(1, (line.rect.minX - contentNormX) / contentNormW))
                let ly0 = max(0, min(1, (line.rect.minY - contentNormY) / contentNormH))
                let lx1 = max(0, min(1, (line.rect.maxX - contentNormX) / contentNormW))
                let ly1 = max(0, min(1, (line.rect.maxY - contentNormY) / contentNormH))
                let lw = lx1 - lx0
                let lh = ly1 - ly0
                guard lw > 0.005, lh > 0.005 else { continue }

                let globalRect = CGRect(
                    x: actualNormROI.minX + lx0 * actualNormROI.width,
                    y: actualNormROI.minY + ly0 * actualNormROI.height,
                    width: lw * actualNormROI.width,
                    height: lh * actualNormROI.height
                )

                // 重新用全图物理比例计算竖排倾向
                let physW = globalRect.width * imgW
                let physH = globalRect.height * imgH
                let aspect = physH / max(physW, 1)
                let charCount = line.text.count
                let isVertical = (charCount >= 2 && aspect > 1.18)
                    || (charCount == 1 && containsCJK(line.text) && aspect > 1.35)

                mapped.append(
                    RawLine(
                        rect: globalRect,
                        text: line.text,
                        isVertical: isVertical,
                        confidence: line.confidence,
                        sourcePriority: sourcePriority,
                        bubbleHintIndex: bubbleHintIndex
                    )
                )
            }
            return mapped
        }
    }

    private static func recognizeOnCGImage(
        _ cgImage: CGImage,
        languages: [String],
        minimumTextHeight: Float,
        sourcePriority: Int,
        bubbleHintIndex: Int?
    ) -> [RawLine] {
        let request = VNRecognizeTextRequest()
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            // 关闭自动语言探测，严格按照 recognitionLanguages 激活日/繁/韩竖排模型
            request.automaticallyDetectsLanguage = false
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = minimumTextHeight
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = request.results ?? []
        let imgW = CGFloat(max(cgImage.width, 1))
        let imgH = CGFloat(max(cgImage.height, 1))

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

            guard topLeftRect.width >= 0.006 || topLeftRect.height >= 0.006 else { continue }
            guard topLeftRect.width * topLeftRect.height >= 0.00006 else { continue }

            let physW = topLeftRect.width * imgW
            let physH = topLeftRect.height * imgH
            let aspect = physH / max(physW, 1)
            let charCount = text.count
            let isVertical = (charCount >= 2 && aspect > 1.18)
                || (charCount == 1 && containsCJK(text) && aspect > 1.35)

            rawLines.append(
                RawLine(
                    rect: topLeftRect,
                    text: text,
                    isVertical: isVertical,
                    confidence: candidate.confidence,
                    sourcePriority: sourcePriority,
                    bubbleHintIndex: bubbleHintIndex
                )
            )
        }
        return rawLines
    }

    private static func prepareSubregionCGImage(
        from cropped: CGImage,
        scaledSize: CGSize,
        border: CGFloat,
        enhanceContrast: Bool
    ) -> CGImage? {
        let canvasW = Int(scaledSize.width + border * 2)
        let canvasH = Int(scaledSize.height + border * 2)
        guard canvasW > 0, canvasH > 0 else { return nil }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: canvasW * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.interpolationQuality = .high
        ctx.draw(
            cropped,
            in: CGRect(x: border, y: border, width: scaledSize.width, height: scaledSize.height)
        )
        guard let baseCG = ctx.makeImage() else { return nil }
        if enhanceContrast {
            return makeContrastBoostedCGImage(from: baseCG) ?? baseCG
        }
        return baseCG
    }

    private static func makeContrastBoostedCGImage(from cgImage: CGImage) -> CGImage? {
        var ci = CIImage(cgImage: cgImage)
        if let colorFilter = CIFilter(name: "CIColorControls") {
            colorFilter.setValue(ci, forKey: kCIInputImageKey)
            colorFilter.setValue(0.0, forKey: kCIInputSaturationKey)
            colorFilter.setValue(1.45, forKey: kCIInputContrastKey)
            colorFilter.setValue(0.04, forKey: kCIInputBrightnessKey)
            if let out = colorFilter.outputImage {
                ci = out
            }
        }
        if let sharpFilter = CIFilter(name: "CISharpenLuminance") {
            sharpFilter.setValue(ci, forKey: kCIInputImageKey)
            sharpFilter.setValue(0.75, forKey: kCIInputSharpnessKey)
            if let out = sharpFilter.outputImage {
                ci = out
            }
        }
        let rect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        return sharedCIContext.createCGImage(ci, from: rect)
    }

    // MARK: - Lightweight Speech Bubble Candidate Detector (Grayscale Connected Components)

    /// 快速检测漫画页中的亮底对话气泡与矩形旁白框（宽 320px 灰度分析，单页耗时 < 12ms）
    private static func detectLightBubbleCandidates(in cgImage: CGImage) -> [BubbleCandidate] {
        let srcW = cgImage.width
        let srcH = cgImage.height
        guard srcW >= 64, srcH >= 64 else { return [] }

        let targetW = min(320, srcW)
        let targetH = max(32, Int((Double(srcH) * Double(targetW) / Double(srcW)).rounded()))
        let pixelCount = targetW * targetH
        guard pixelCount > 0, pixelCount <= 360_000 else { return [] }

        var gray = [UInt8](repeating: 0, count: pixelCount)
        let graySpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &gray,
            width: targetW,
            height: targetH,
            bitsPerComponent: 8,
            bytesPerRow: targetW,
            space: graySpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return []
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))

        // 标记高亮度像素（>= 226）作为白底气泡/旁白框背景种子
        let brightThreshold: UInt8 = 226
        let inkThreshold: UInt8 = 165
        var isBright = [Bool](repeating: false, count: pixelCount)
        for i in 0..<pixelCount {
            isBright[i] = gray[i] >= brightThreshold
        }

        // 先对页面四条外边框连通的纯白页面留白做洪水标记，防止外页边距吞并边缘开口气泡
        var visited = [Bool](repeating: false, count: pixelCount)
        var queue = [Int]()
        queue.reserveCapacity(pixelCount / 4)

        func floodFill(startIdx: Int, markAsPageMargin: Bool) -> (count: Int, minX: Int, maxX: Int, minY: Int, maxY: Int) {
            queue.removeAll(keepingCapacity: true)
            queue.append(startIdx)
            visited[startIdx] = true

            var head = 0
            var minX = startIdx % targetW
            var maxX = minX
            var minY = startIdx / targetW
            var maxY = minY

            while head < queue.count {
                let cur = queue[head]
                head += 1

                let cx = cur % targetW
                let cy = cur / targetW
                if !markAsPageMargin {
                    if cx < minX { minX = cx }
                    if cx > maxX { maxX = cx }
                    if cy < minY { minY = cy }
                    if cy > maxY { maxY = cy }
                }

                if cx > 0 {
                    let n = cur - 1
                    if isBright[n] && !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if cx + 1 < targetW {
                    let n = cur + 1
                    if isBright[n] && !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if cy > 0 {
                    let n = cur - targetW
                    if isBright[n] && !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
                if cy + 1 < targetH {
                    let n = cur + targetW
                    if isBright[n] && !visited[n] {
                        visited[n] = true
                        queue.append(n)
                    }
                }
            }
            return (queue.count, minX, maxX, minY, maxY)
        }

        // 排除与画面四边直接相连的大片纯白页边距
        for x in 0..<targetW {
            let topIdx = x
            if isBright[topIdx] && !visited[topIdx] {
                _ = floodFill(startIdx: topIdx, markAsPageMargin: true)
            }
            let botIdx = (targetH - 1) * targetW + x
            if isBright[botIdx] && !visited[botIdx] {
                _ = floodFill(startIdx: botIdx, markAsPageMargin: true)
            }
        }
        for y in 0..<targetH {
            let leftIdx = y * targetW
            if isBright[leftIdx] && !visited[leftIdx] {
                _ = floodFill(startIdx: leftIdx, markAsPageMargin: true)
            }
            let rightIdx = y * targetW + (targetW - 1)
            if isBright[rightIdx] && !visited[rightIdx] {
                _ = floodFill(startIdx: rightIdx, markAsPageMargin: true)
            }
        }

        // 扫描内部亮色连通域，筛选内部包含文字墨水像素的对话气泡/旁白框
        let minAreaPixels = max(140, Int(Double(pixelCount) * 0.0022))
        let maxAreaPixels = Int(Double(pixelCount) * 0.24)
        var rawCandidates: [BubbleCandidate] = []

        for idx in 0..<pixelCount {
            guard isBright[idx] && !visited[idx] else { continue }
            let comp = floodFill(startIdx: idx, markAsPageMargin: false)
            guard comp.count >= minAreaPixels && comp.count <= maxAreaPixels else { continue }

            let bw = comp.maxX - comp.minX + 1
            let bh = comp.maxY - comp.minY + 1
            guard bw >= 12, bh >= 16 else { continue }
            let aspect = Double(bh) / Double(bw)
            guard aspect >= 0.22 && aspect <= 6.5 else { continue }

            let boxArea = bw * bh
            let fillRatio = Double(comp.count) / Double(boxArea)
            // 气泡或旁白框内部大面积为白色，但含文字孔洞，填充度通常在 0.30 ~ 0.96
            guard fillRatio >= 0.28 && fillRatio <= 0.96 else { continue }

            // 统计外接矩形内缩区域中的暗色墨水像素占比（识别是否真含文字，排除纯白高光/衣服/天空）
            let insetX = max(1, bw / 10)
            let insetY = max(1, bh / 10)
            let ix0 = min(comp.maxX, comp.minX + insetX)
            let ix1 = max(ix0, comp.maxX - insetX)
            let iy0 = min(comp.maxY, comp.minY + insetY)
            let iy1 = max(iy0, comp.maxY - insetY)

            var innerTotal = 0
            var innerInk = 0
            for yy in iy0...iy1 {
                let rowStart = yy * targetW
                for xx in ix0...ix1 {
                    innerTotal += 1
                    if gray[rowStart + xx] < inkThreshold {
                        innerInk += 1
                    }
                }
            }
            guard innerTotal > 0 else { continue }
            let inkRatio = Double(innerInk) / Double(innerTotal)
            // 气泡文字墨水占比通常在 2.5% ~ 58%
            guard inkRatio >= 0.025 && inkRatio <= 0.58 else { continue }

            let padX = Double(bw) * 0.05
            let padY = Double(bh) * 0.05
            let nx0 = max(0.0, (Double(comp.minX) - padX) / Double(targetW))
            let ny0 = max(0.0, (Double(comp.minY) - padY) / Double(targetH))
            let nx1 = min(1.0, (Double(comp.maxX + 1) + padX) / Double(targetW))
            let ny1 = min(1.0, (Double(comp.maxY + 1) + padY) / Double(targetH))
            let normRect = CGRect(x: nx0, y: ny0, width: nx1 - nx0, height: ny1 - ny0)
            rawCandidates.append(BubbleCandidate(rect: normRect, inkRatio: inkRatio))
        }

        // 合并高度重叠的相邻候选区（如被文字切断的上下半个气泡），上限保留 18 个防止异常图拖慢速度
        let merged = mergeOverlappingCandidates(rawCandidates)
        if merged.count <= 18 {
            return merged
        }
        return Array(
            merged.sorted { lhs, rhs in
                (lhs.rect.width * lhs.rect.height) > (rhs.rect.width * rhs.rect.height)
            }.prefix(18)
        )
    }

    private static func mergeOverlappingCandidates(_ candidates: [BubbleCandidate]) -> [BubbleCandidate] {
        guard candidates.count > 1 else { return candidates }
        var rects = candidates.map(\.rect)
        var inks = candidates.map(\.inkRatio)
        var changed = true

        while changed {
            changed = false
            var i = 0
            while i < rects.count {
                var j = i + 1
                while j < rects.count {
                    let inter = rects[i].intersection(rects[j])
                    if !inter.isNull {
                        let interArea = inter.width * inter.height
                        let minArea = min(rects[i].width * rects[i].height, rects[j].width * rects[j].height)
                        if minArea > 0 && interArea / minArea > 0.35 {
                            rects[i] = rects[i].union(rects[j])
                            inks[i] = max(inks[i], inks[j])
                            rects.remove(at: j)
                            inks.remove(at: j)
                            changed = true
                            continue
                        }
                    }
                    j += 1
                }
                i += 1
            }
        }

        return zip(rects, inks).map { BubbleCandidate(rect: $0.0, inkRatio: $0.1) }
    }

    // MARK: - Multi-Pass Deduplication & Hint Assignment

    private static func assignBubbleHints(
        to lines: [RawLine],
        candidates: [BubbleCandidate]
    ) -> [RawLine] {
        guard !candidates.isEmpty else { return lines }
        return lines.map { line in
            if line.bubbleHintIndex != nil {
                return line
            }
            let center = CGPoint(x: line.rect.midX, y: line.rect.midY)
            var bestIdx: Int?
            var bestArea = CGFloat.greatestFiniteMagnitude
            for (idx, cand) in candidates.enumerated() {
                if cand.rect.contains(center) {
                    let area = cand.rect.width * cand.rect.height
                    if area < bestArea {
                        bestArea = area
                        bestIdx = idx
                    }
                }
            }
            guard let bestIdx else { return line }
            return RawLine(
                rect: line.rect,
                text: line.text,
                isVertical: line.isVertical,
                confidence: line.confidence,
                sourcePriority: line.sourcePriority,
                bubbleHintIndex: bestIdx
            )
        }
    }

    /// 跨通道去重：优先保留气泡精识 > 网格补扫 > 全图扫描，及更高置信度/更完整文本
    private static func deduplicateLines(_ lines: [RawLine]) -> [RawLine] {
        guard lines.count > 1 else { return lines }

        let ranked = lines.sorted { lhs, rhs in
            if lhs.sourcePriority != rhs.sourcePriority {
                return lhs.sourcePriority > rhs.sourcePriority
            }
            let lScore = Double(lhs.confidence) + min(Double(lhs.text.count), 12.0) * 0.04
            let rScore = Double(rhs.confidence) + min(Double(rhs.text.count), 12.0) * 0.04
            if abs(lScore - rScore) > 0.01 {
                return lScore > rScore
            }
            return (lhs.rect.width * lhs.rect.height) > (rhs.rect.width * rhs.rect.height)
        }

        var kept: [RawLine] = []
        kept.reserveCapacity(ranked.count)

        for candidate in ranked {
            var isDuplicate = false
            for existing in kept {
                let inter = candidate.rect.intersection(existing.rect)
                guard !inter.isNull else { continue }
                let interArea = inter.width * inter.height
                let candArea = candidate.rect.width * candidate.rect.height
                let existArea = existing.rect.width * existing.rect.height
                let minArea = min(candArea, existArea)
                let unionArea = candArea + existArea - interArea

                let iou = unionArea > 0 ? interArea / unionArea : 0
                let containRatio = minArea > 0 ? interArea / minArea : 0

                if iou > 0.32 || containRatio > 0.55 {
                    isDuplicate = true
                    break
                }
                // 部分重叠且文本高度相似/包含也视为同一行重复检出
                if containRatio > 0.25 && textsOverlapMeaningfully(candidate.text, existing.text) {
                    isDuplicate = true
                    break
                }
            }
            if !isDuplicate {
                kept.append(candidate)
            }
        }
        return kept
    }

    private static func textsOverlapMeaningfully(_ a: String, _ b: String) -> Bool {
        let sa = a.replacingOccurrences(of: " ", with: "")
        let sb = b.replacingOccurrences(of: " ", with: "")
        guard !sa.isEmpty, !sb.isEmpty else { return false }
        if sa == sb || sa.contains(sb) || sb.contains(sa) {
            return true
        }
        let setA = Set(sa)
        let setB = Set(sb)
        let common = setA.intersection(setB).count
        let minCount = min(setA.count, setB.count)
        return minCount > 0 && Double(common) / Double(minCount) >= 0.6
    }

    // MARK: - Bubble Clustering (Vertical Japanese + Horizontal Dialog)

    private static func clusterLinesIntoBubbles(
        _ lines: [RawLine],
        bubbleCandidates: [BubbleCandidate]
    ) -> [DetectedTextBubble] {
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

            // 剔除背景网点/阴影中孤立误识别的极小单字（如门洞阴影里的杂点单字）
            let avgConf = group.reduce(Float(0)) { $0 + $1.confidence } / Float(group.count)
            let area = unionRect.width * unionRect.height
            let hasBubbleHint = group.contains { $0.bubbleHintIndex != nil }
            if !hasBubbleHint && joinedText.count <= 1 && area < 0.0018 && avgConf < 0.85 {
                continue
            }
            if !hasBubbleHint && joinedText.count <= 2 && area < 0.0005 && avgConf < 0.55 {
                continue
            }

            // 如果聚类来自同一个气泡候选框，把文本边界轻微约束在候选框内，避免遮罩外溢
            if let hintIdx = group.compactMap(\.bubbleHintIndex).first,
               group.allSatisfy({ $0.bubbleHintIndex == nil || $0.bubbleHintIndex == hintIdx }),
               bubbleCandidates.indices.contains(hintIdx) {
                let clipped = unionRect.intersection(bubbleCandidates[hintIdx].rect)
                if !clipped.isNull, clipped.width > 0.01, clipped.height > 0.01 {
                    unionRect = clipped
                }
            }

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
        // 如果两条文本被明确归入两个不同的白底气泡候选框，禁止跨气泡误合并
        if let ha = a.bubbleHintIndex, let hb = b.bubbleHintIndex {
            if ha != hb {
                return false
            }
            // 同一个气泡候选框内的文本行，放宽间距阈值确保完整拼成一个句子
            let union = a.rect.union(b.rect)
            if union.width <= 0.48 && union.height <= 0.58 {
                return true
            }
        }

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
            if hGap <= max(maxColWidth * 1.65, 0.030) && (vOverlap > -0.024 || vGap <= minHeight * 0.35) {
                let union = ra.union(rb)
                if union.width <= 0.42 && union.height <= 0.55 {
                    return true
                }
            }
            // 同列上下断开的两段竖排字
            if hOverlap > min(ra.width, rb.width) * 0.35 && vGap <= max(maxColWidth * 1.5, 0.028) {
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

/// 高精度无损气泡译文渲染器（按原图分辨率取色遮盖 + 自适应字号居中排版）
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

                // 采样气泡真实底色（优先采框内亮部纸底，兼顾黑底独白框）
                let bgSample = sampler.sampleBackgroundColor(around: bubble.normalizedRect)
                let isDarkBubble = bgSample.luminance < 0.44
                let fillColor: UIColor = isDarkBubble
                    ? bgSample.color.withAlphaComponent(0.95)
                    : bgSample.color.withAlphaComponent(0.97)
                let textColor: UIColor = isDarkBubble ? .white : UIColor(white: 0.08, alpha: 1.0)
                let borderColor: UIColor = isDarkBubble
                    ? UIColor.white.withAlphaComponent(0.14)
                    : UIColor.black.withAlphaComponent(0.08)

                let cornerRadius = min(min(boxRect.width, boxRect.height) * 0.26, 22)
                let roundedPath = UIBezierPath(roundedRect: boxRect, cornerRadius: cornerRadius)

                cgCtx.saveGState()
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

/// 轻量级气泡背景像素采样器（缩略至 180px 宽进行内外边缘取色，单页耗时 < 1.5ms）
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

        let targetW = min(180, max(16, cg.width))
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
        let insetX = min(normalizedRect.width * 0.12, 0.012)
        let insetY = min(normalizedRect.height * 0.12, 0.010)
        let marginX = max(normalizedRect.width * 0.06, 0.006)
        let marginY = max(normalizedRect.height * 0.06, 0.005)

        // 同时采样气泡内缘（避开黑边框外人物/阴影）与紧邻外缘，按亮度分位取气泡真实纸底
        let points: [(CGFloat, CGFloat)] = [
            // 内缘 8 点
            (minX + insetX, minY + insetY),
            (maxX - insetX, minY + insetY),
            (minX + insetX, maxY - insetY),
            (maxX - insetX, maxY - insetY),
            (midX, minY + insetY),
            (midX, maxY - insetY),
            (minX + insetX, midY),
            (maxX - insetX, midY),
            // 紧邻外缘 4 点
            (minX - marginX, midY),
            (maxX + marginX, midY),
            (midX, minY - marginY),
            (midX, maxY + marginY),
        ]

        var samples: [(r: CGFloat, g: CGFloat, b: CGFloat, lum: CGFloat)] = []
        samples.reserveCapacity(points.count)
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

        // 取 75% 亮度分位样本（压过文字笔画与外框黑线，准确还原白底气泡；黑底白字气泡高分位仍偏暗）
        samples.sort { $0.lum < $1.lum }
        let chosen = samples[min(samples.count - 1, Int(Double(samples.count - 1) * 0.75))]
        if chosen.lum > 0.82 {
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
