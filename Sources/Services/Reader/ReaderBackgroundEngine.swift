//
//  ReaderBackgroundEngine.swift
//  KedaOnlineReader
//
//  复刻自：可达阅读器 (Kedamanga) 拟真纸质与多模式阅读背景系统
//  涵盖 5 种背景模式、6 套真实物理纸张材质、正片叠底复合滤镜与立体书脊阴影
//

import CoreGraphics
import CoreImage
import Foundation
import QuartzCore
import SwiftUI
import UIKit

// MARK: - 1. 物理纸张纹理资源管理器与缓存池

public final class ReaderTextureCache: @unchecked Sendable {
    public static let shared = ReaderTextureCache()

    private let cache = NSCache<NSString, UIImage>()
    private let seamlessTileCache = NSCache<NSString, UIImage>()
    private let patternColorCache = NSCache<NSString, UIColor>()
    private let loadLock = NSLock()
    private let queue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.texture_cache", qos: .userInitiated)
    private let srgbContext: CIContext = {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: srgb,
            .outputColorSpace: srgb,
            .useSoftwareRenderer: false
        ])
    }()

    private init() {
        cache.countLimit = 24
        seamlessTileCache.countLimit = 24
    }

    /// 感知强度映射：经典浮雕纸纹沿用 MangaPrism 0.66 幂次曲线，让低档位也保持清晰立体颗粒而非雾面发灰
    public static func perceptualOpacity(for texture: ReaderTextureType, rawOpacity: Double) -> Double {
        let clamped = min(max(rawOpacity, 0.0), 1.0)
        guard texture.usesFineTilePattern, clamped > 0 else { return clamped }
        return pow(clamped, 0.66)
    }

    /// 获取指定纸张纹理图像（带内存二级缓存）
    public func textureImage(for type: ReaderTextureType) -> UIImage? {
        let key = type.rawValue as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        loadLock.lock()
        defer { loadLock.unlock() }
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let loaded: UIImage?
        if type.usesFineTilePattern {
            // 经典纸张采用 MangaPrism 风格 256×256pt 程序化高密立体浮雕无缝微粒切片
            loaded = Self.buildProceduralClassicStuccoTile()
        } else {
            // 优先全名 (例如 Texture_1_brown_paper) 加载，次选短名 (例如 Texture_1) 加载
            loaded = loadTextureFromBundle(named: type.rawValue)
                ?? loadTextureFromBundle(named: shortKey(for: type))
        }
        if let img = loaded {
            cache.setObject(img, forKey: key)
        }
        return loaded
    }

    /// 获取缓存的平铺画刷颜色（供 UIKit 1:1 逻辑尺寸高频无损平铺，避免拖动滑块时重复创建 CGPattern）
    public func patternColor(for type: ReaderTextureType) -> UIColor? {
        let key = type.rawValue as NSString
        if let cached = patternColorCache.object(forKey: key) {
            return cached
        }
        guard let img = textureImage(for: type) else {
            return nil
        }
        let color = UIColor(patternImage: img)
        patternColorCache.setObject(color, forKey: key)
        return color
    }

    /// 获取去色白场校准后的中性纸张肌理图（彻底消除材质自带黄/棕色偏色，仅保留纯白纸纤维颗粒）
    public func neutralGrainImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            // 程序化经典浮雕纸纹基底本身即为纯白零偏色，直接复用保持微粒锐度
            return textureImage(for: type)
        }
        let key = "\(type.rawValue)_neutral_grain" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let baseImg = textureImage(for: type) else {
            return nil
        }

        return queue.sync {
            if let cached = cache.object(forKey: key) {
                return cached
            }
            let generated = buildNeutralGrainImage(from: baseImg)
            cache.setObject(generated, forKey: key)
            return generated
        }
    }

    /// 获取专为条漫连续滚动平铺打造的 2×2 镜像无缝纹理图（裁去边缘暗边并双向镜像衔接，消除拼接线）
    public func seamlessTileImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            // 经典浮雕微粒切片自身采用 8 向边界环绕生成，天然 100% 无缝循环
            return textureImage(for: type)
        }
        let key = "\(type.rawValue)_seamless_tile" as NSString
        if let cached = seamlessTileCache.object(forKey: key) {
            return cached
        }
        guard let baseImg = textureImage(for: type) else {
            return nil
        }

        return queue.sync {
            if let cached = seamlessTileCache.object(forKey: key) {
                return cached
            }
            let generated = Self.buildSeamlessMirroredTile(from: baseImg)
            seamlessTileCache.setObject(generated, forKey: key)
            return generated
        }
    }

    /// 获取去色白场校准后的 2×2 镜像无缝纹理图（供条漫 0% 着色或过渡混合使用）
    public func seamlessNeutralTileImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            return textureImage(for: type)
        }
        let key = "\(type.rawValue)_seamless_neutral_tile" as NSString
        if let cached = seamlessTileCache.object(forKey: key) {
            return cached
        }
        guard let neutralImg = neutralGrainImage(for: type) else {
            return nil
        }

        return queue.sync {
            if let cached = seamlessTileCache.object(forKey: key) {
                return cached
            }
            let generated = Self.buildSeamlessMirroredTile(from: neutralImg)
            seamlessTileCache.setObject(generated, forKey: key)
            return generated
        }
    }

    private func buildNeutralGrainImage(from image: UIImage) -> UIImage {
        let origW = image.size.width
        let origH = image.size.height
        guard origW > 16, origH > 16 else { return image }

        let maxDim: CGFloat = 1600.0
        let scale = min(1.0, maxDim / max(origW, origH))
        let targetSize = CGSize(
            width: max(32.0, floor(origW * scale)),
            height: max(32.0, floor(origH * scale))
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let bounded = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        let meanLuma = estimateAverageLuminance(of: bounded)
        guard let ciInput = CIImage(image: bounded),
              let desaturateFilter = CIFilter(name: "CIColorControls") else {
            return bounded
        }

        desaturateFilter.setValue(ciInput, forKey: kCIInputImageKey)
        desaturateFilter.setValue(0.0, forKey: kCIInputSaturationKey)

        guard let grayCI = desaturateFilter.outputImage,
              let matrixFilter = CIFilter(name: "CIColorMatrix") else {
            return bounded
        }

        // 将各款纸张均值亮度拉齐至 ~0.97 纯白纸基，同时保留 0.82 倍纤维暗部肌理对比
        let gain: CGFloat = 0.82
        let targetWhite: CGFloat = 0.97
        let lumaScale = gain / max(meanLuma, 0.25)
        let lumaBias = targetWhite - gain

        matrixFilter.setValue(grayCI, forKey: kCIInputImageKey)
        matrixFilter.setValue(CIVector(x: lumaScale, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrixFilter.setValue(CIVector(x: 0, y: lumaScale, z: 0, w: 0), forKey: "inputGVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: lumaScale, w: 0), forKey: "inputBVector")
        matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrixFilter.setValue(CIVector(x: lumaBias, y: lumaBias, z: lumaBias, w: 0), forKey: "inputBiasVector")

        guard let outputCI = matrixFilter.outputImage,
              let outCG = srgbContext.createCGImage(outputCI, from: grayCI.extent) else {
            return bounded
        }
        return UIImage(cgImage: outCG)
    }

    private func estimateAverageLuminance(of image: UIImage) -> CGFloat {
        guard let cgImg = image.cgImage else { return 0.85 }
        let sampleSize = 8
        var pixels = [UInt8](repeating: 0, count: sampleSize * sampleSize)
        guard let ctx = CGContext(
            data: &pixels,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0.85
        }
        ctx.interpolationQuality = .medium
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        let total = pixels.reduce(0) { $0 + Int($1) }
        return CGFloat(total) / CGFloat(pixels.count * 255)
    }

    /// 1:1 复刻 MangaPrism StuccoTextureManager 的程序化高密立体浮雕纸纹引擎：
    /// 256×256pt 逻辑尺寸（2x 视网膜锐利渲染），内含 42 处无缝柔和纸浆光斑 + 23,500 颗带右下投影的立体凸起微粒与炭灰气孔
    private static func buildProceduralClassicStuccoTile() -> UIImage {
        let tileSize: CGFloat = 256.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize),
            format: format
        )

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 纯白基底：确保正片叠底 Multiply 时凸起高光区域保持通透洁净不发灰
            cg.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            cg.fill(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

            // Layer 1: 42 处无缝柔和纸浆起伏斑块（模拟手工纸张轻微明暗起伏）
            var plasterRng = SplitMix64RNG(seed: 20261108)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)
            for _ in 0..<42 {
                let cx = CGFloat(plasterRng.nextUnitDouble()) * tileSize
                let cy = CGFloat(plasterRng.nextUnitDouble()) * tileSize
                let baseRadius = 20.0 + CGFloat(plasterRng.nextUnitDouble()) * 38.0
                let softRadius = baseRadius + 12.0
                let isLight = plasterRng.nextBool()
                let component: CGFloat = isLight ? 1.0 : 0.0
                let peakAlpha: CGFloat = isLight ? 0.055 : 0.024

                let colors = [
                    CGColor(colorSpace: colorSpace, components: [component, component, component, peakAlpha])!,
                    CGColor(colorSpace: colorSpace, components: [component, component, component, peakAlpha * 0.45])!,
                    CGColor(colorSpace: colorSpace, components: [component, component, component, 0.0])!
                ] as CFArray
                let locations: [CGFloat] = [0.0, 0.55, 1.0]
                if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
                    drawSeamlessRadialGradient(
                        in: cg,
                        gradient: gradient,
                        cx: cx,
                        cy: cy,
                        radius: softRadius,
                        tileSize: tileSize
                    )
                }
            }

            // Layer 2: 23,500 颗无缝立体浮雕微粒（关闭抗锯齿保持刀锋般清晰的实体纸粒感）
            var grainRng = SplitMix64RNG(seed: 20261109)
            cg.setAllowsAntialiasing(false)
            cg.setShouldAntialias(false)

            let poreR: CGFloat = 69.0 / 255.0   // #45474D 炭灰纸浆微孔
            let poreG: CGFloat = 71.0 / 255.0
            let poreB: CGFloat = 77.0 / 255.0

            for _ in 0..<23_500 {
                let x = CGFloat(grainRng.nextUnitDouble()) * tileSize
                let y = CGFloat(grainRng.nextUnitDouble()) * tileSize
                // 保留大量细砂，同时让 16% 较大高光颗粒形成清晰的立体视觉锚点
                let diameter: CGFloat = grainRng.nextUnitDouble() < 0.16
                    ? (1.55 + CGFloat(grainRng.nextUnitDouble()) * 1.15)
                    : (0.75 + CGFloat(grainRng.nextUnitDouble()) * 1.05)
                let isRaisedGrain = grainRng.nextUnitDouble() > 0.36

                if isRaisedGrain {
                    if diameter > 0.95 {
                        let shadowAlpha = 0.13 + CGFloat(grainRng.nextUnitDouble()) * 0.15
                        cg.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: shadowAlpha)
                        var sx = x + 0.85
                        if sx >= tileSize { sx -= tileSize }
                        var sy = y + 0.85
                        if sy >= tileSize { sy -= tileSize }
                        drawSeamlessDot(in: cg, x: sx, y: sy, diameter: diameter * 0.88, tileSize: tileSize)
                    }

                    let highlightAlpha = 0.86 + CGFloat(grainRng.nextUnitDouble()) * 0.14
                    cg.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: highlightAlpha)
                    drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter, tileSize: tileSize)
                } else {
                    let poreAlpha = 0.14 + CGFloat(grainRng.nextUnitDouble()) * 0.16
                    cg.setFillColor(red: poreR, green: poreG, blue: poreB, alpha: poreAlpha)
                    drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter * 0.85, tileSize: tileSize)
                }
            }
        }
    }

    private static func drawSeamlessDot(
        in cg: CGContext,
        x: CGFloat,
        y: CGFloat,
        diameter: CGFloat,
        tileSize: CGFloat
    ) {
        let r = diameter * 0.5
        cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: diameter, height: diameter))

        let crossesLeft = x - r < 0
        let crossesRight = x + r > tileSize
        let crossesTop = y - r < 0
        let crossesBottom = y + r > tileSize

        if crossesLeft {
            cg.fillEllipse(in: CGRect(x: x + tileSize - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesRight {
            cg.fillEllipse(in: CGRect(x: x - tileSize - r, y: y - r, width: diameter, height: diameter))
        }
        if crossesTop {
            cg.fillEllipse(in: CGRect(x: x - r, y: y + tileSize - r, width: diameter, height: diameter))
        }
        if crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - r, y: y - tileSize - r, width: diameter, height: diameter))
        }
        if crossesLeft && crossesTop {
            cg.fillEllipse(in: CGRect(x: x + tileSize - r, y: y + tileSize - r, width: diameter, height: diameter))
        }
        if crossesLeft && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x + tileSize - r, y: y - tileSize - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesTop {
            cg.fillEllipse(in: CGRect(x: x - tileSize - r, y: y + tileSize - r, width: diameter, height: diameter))
        }
        if crossesRight && crossesBottom {
            cg.fillEllipse(in: CGRect(x: x - tileSize - r, y: y - tileSize - r, width: diameter, height: diameter))
        }
    }

    private static func drawSeamlessRadialGradient(
        in cg: CGContext,
        gradient: CGGradient,
        cx: CGFloat,
        cy: CGFloat,
        radius: CGFloat,
        tileSize: CGFloat
    ) {
        func drawAt(_ x: CGFloat, _ y: CGFloat) {
            let center = CGPoint(x: x, y: y)
            cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        drawAt(cx, cy)

        let crossesLeft = cx - radius < 0
        let crossesRight = cx + radius > tileSize
        let crossesTop = cy - radius < 0
        let crossesBottom = cy + radius > tileSize

        if crossesLeft { drawAt(cx + tileSize, cy) }
        if crossesRight { drawAt(cx - tileSize, cy) }
        if crossesTop { drawAt(cx, cy + tileSize) }
        if crossesBottom { drawAt(cx, cy - tileSize) }
        if crossesLeft && crossesTop { drawAt(cx + tileSize, cy + tileSize) }
        if crossesLeft && crossesBottom { drawAt(cx + tileSize, cy - tileSize) }
        if crossesRight && crossesTop { drawAt(cx - tileSize, cy + tileSize) }
        if crossesRight && crossesBottom { drawAt(cx - tileSize, cy - tileSize) }
    }

    /// 高速确定性伪随机数生成器（SplitMix64），保证每次生成的立体纸粒分布一致且毫秒级完成
    private struct SplitMix64RNG {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        mutating func nextUnitDouble() -> Double {
            Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0)
        }

        mutating func nextBool() -> Bool {
            (nextUInt64() & 1) == 1
        }
    }

    private static func buildSeamlessMirroredTile(from image: UIImage) -> UIImage {
        let origW = image.size.width
        let origH = image.size.height
        guard origW > 32, origH > 32 else { return image }

        let trimRatio: CGFloat = 0.03
        let visibleRatio: CGFloat = 1.0 - trimRatio * 2.0
        let maxQuadrantDim: CGFloat = 1024.0
        let downScale = min(1.0, maxQuadrantDim / max(origW, origH))
        let quadW = max(64.0, floor(origW * visibleRatio * downScale))
        let quadH = max(64.0, floor(origH * visibleRatio * downScale))

        return renderMirroredTileGrid(
            from: image,
            columns: 2,
            rows: 2,
            cellSize: CGSize(width: quadW, height: quadH),
            cropInsetRatio: trimRatio
        )
    }

    private static func renderMirroredTileGrid(
        from image: UIImage,
        columns: Int,
        rows: Int,
        cellSize: CGSize,
        cropInsetRatio: CGFloat
    ) -> UIImage {
        let visibleRatio = max(0.2, 1.0 - cropInsetRatio * 2.0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let drawW = cellSize.width / visibleRatio
        let drawH = cellSize.height / visibleRatio
        let offsetX = -(drawW - cellSize.width) * 0.5
        let offsetY = -(drawH - cellSize.height) * 0.5

        let croppedCell = UIGraphicsImageRenderer(size: cellSize, format: format).image { _ in
            image.draw(in: CGRect(x: offsetX, y: offsetY, width: drawW, height: drawH))
        }

        let fullSize = CGSize(
            width: cellSize.width * CGFloat(columns),
            height: cellSize.height * CGFloat(rows)
        )
        return UIGraphicsImageRenderer(size: fullSize, format: format).image { ctx in
            let cg = ctx.cgContext
            for row in 0..<rows {
                for col in 0..<columns {
                    let flipX = col % 2 == 1
                    let flipY = row % 2 == 1
                    let originX = CGFloat(col) * cellSize.width
                    let originY = CGFloat(row) * cellSize.height

                    cg.saveGState()
                    cg.translateBy(
                        x: originX + (flipX ? cellSize.width : 0),
                        y: originY + (flipY ? cellSize.height : 0)
                    )
                    cg.scaleBy(x: flipX ? -1.0 : 1.0, y: flipY ? -1.0 : 1.0)
                    croppedCell.draw(in: CGRect(origin: .zero, size: cellSize))
                    cg.restoreGState()
                }
            }
        }
    }

    private func shortKey(for type: ReaderTextureType) -> String {
        switch type {
        case .classic:      return "Texture_0"
        case .brownPaper:   return "Texture_1"
        case .whiteWall:    return "Texture_2"
        case .grungePaper:  return "Texture_3"
        case .tissueMarble: return "Texture_4"
        case .wood:         return "Texture_5"
        }
    }

    /// 获取设置页小尺寸样张预览图
    public func previewSampleImage() -> UIImage? {
        let key = "Texture_Preview_sample" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let loaded = loadTextureFromBundle(named: "Texture_Preview_sample")
        if let img = loaded {
            cache.setObject(img, forKey: key)
        }
        return loaded
    }

    private func loadTextureFromBundle(named name: String) -> UIImage? {
        // 1. 检查 xcassets / 顶层命名
        if let img = UIImage(named: name) {
            return img
        }

        let extensions = ["heic", "jpg", "png"]
        let subdirectories = ["Reader_Textures", "Resources/Reader_Textures", ""]

        for subdir in subdirectories {
            for ext in extensions {
                let sub = subdir.isEmpty ? nil : subdir
                if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub),
                   let data = try? Data(contentsOf: url),
                   let img = UIImage(data: data) {
                    return img
                }
                if let path = Bundle.main.path(forResource: name, ofType: ext, inDirectory: sub),
                   let img = UIImage(contentsOfFile: path) {
                    return img
                }
            }
        }

        // 2. 检查应用根沙盒可能的外置目录
        for ext in extensions {
            if let path = Bundle.main.path(forResource: name, ofType: ext),
               let img = UIImage(contentsOfFile: path) {
                return img
            }
        }

        return nil
    }
}

// MARK: - 2. UIKit 阅读背景视图容器 (ReaderBackgroundContainerView)

public class ReaderBackgroundContainerView: UIView {

    // MARK: - 视图分层架构
    /// Layer 0: 基础底色视图
    public let baseColorView = UIView()
    /// Layer 1: 沉浸式动态高斯模糊背景层 (用于 immersive 模式)
    public let immersiveBackgroundView = UIImageView()
    /// Layer 2: 真实纸质纹理复合容器 (使用 multiplyBlendMode 正片叠底，支持着色与去色肌理无缝混合)
    public let textureCompositeView = UIView()
    public let neutralTextureOverlayView = UIImageView()
    public let textureOverlayView = UIImageView()
    /// Layer 3: 书脊中缝立体渐变阴影层 (CAGradientLayer)
    public let spineGradientLayer = CAGradientLayer()
    /// Layer 4: 书脊中缝细分割线 (模拟实体开本中线)
    public let spineDividingLineView = UIView()

    // MARK: - 配置属性
    public var currentBackground: ReaderBackground = .followSystem {
        didSet { applyBackgroundStyle() }
    }

    public var currentTexture: ReaderTextureType = .classic {
        didSet {
            updateTextureImage()
            if currentBackground == .texture {
                baseColorView.backgroundColor = blendedPaperColor()
            }
        }
    }

    public var textureOpacity: CGFloat = 0.4 {
        didSet {
            textureCompositeView.alpha = CGFloat(
                ReaderTextureCache.perceptualOpacity(for: currentTexture, rawOpacity: Double(textureOpacity))
            )
        }
    }

    public var textureTintOpacity: CGFloat = 1.0 {
        didSet {
            if currentBackground == .texture {
                baseColorView.backgroundColor = blendedPaperColor()
                updateTextureImage()
            }
        }
    }

    public var showSpineShadow: Bool = true {
        didSet { spineGradientLayer.isHidden = !showSpineShadow }
    }

    public var showDividingLine: Bool = true {
        didSet { spineDividingLineView.isHidden = !showDividingLine }
    }

    public var spineEdge: UIRectEdge = .left {
        didSet { setNeedsLayout() }
    }

    // MARK: - 生命周期与初始化
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        clipsToBounds = true

        // 1. 底色层
        baseColorView.frame = bounds
        baseColorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(baseColorView)

        // 2. 沉浸式模糊背景层
        immersiveBackgroundView.frame = bounds
        immersiveBackgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        immersiveBackgroundView.contentMode = .scaleAspectFill
        immersiveBackgroundView.clipsToBounds = true
        immersiveBackgroundView.isHidden = true
        addSubview(immersiveBackgroundView)

        // 3. 纹理叠加复合容器 (使用 multiplyBlendMode 正片叠底)
        textureCompositeView.frame = bounds
        textureCompositeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textureCompositeView.clipsToBounds = true
        textureCompositeView.backgroundColor = .clear
        textureCompositeView.alpha = textureOpacity
        textureCompositeView.layer.compositingFilter = "multiplyBlendMode"
        textureCompositeView.isHidden = true
        addSubview(textureCompositeView)

        neutralTextureOverlayView.frame = textureCompositeView.bounds
        neutralTextureOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        neutralTextureOverlayView.contentMode = .scaleAspectFill
        neutralTextureOverlayView.isHidden = true
        textureCompositeView.addSubview(neutralTextureOverlayView)

        textureOverlayView.frame = textureCompositeView.bounds
        textureOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textureOverlayView.contentMode = .scaleAspectFill
        textureCompositeView.addSubview(textureOverlayView)

        // 4. 书脊立体阴影
        setupSpineGradient()

        // 5. 书脊分割线
        spineDividingLineView.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        addSubview(spineDividingLineView)

        applyBackgroundStyle()
        updateTextureImage()
    }

    private func setupSpineGradient() {
        spineGradientLayer.colors = [
            UIColor.black.withAlphaComponent(0.24).cgColor,
            UIColor.black.withAlphaComponent(0.06).cgColor,
            UIColor.clear.cgColor
        ]
        spineGradientLayer.locations = [0.0, 0.45, 1.0]
        layer.addSublayer(spineGradientLayer)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let spineWidth: CGFloat = 26.0

        switch spineEdge {
        case .left:
            spineGradientLayer.frame = CGRect(x: 0, y: 0, width: spineWidth, height: bounds.height)
            spineGradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
            spineGradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
            spineDividingLineView.frame = CGRect(x: 0, y: 0, width: 0.5, height: bounds.height)
        case .right:
            spineGradientLayer.frame = CGRect(x: bounds.width - spineWidth, y: 0, width: spineWidth, height: bounds.height)
            spineGradientLayer.startPoint = CGPoint(x: 1.0, y: 0.5)
            spineGradientLayer.endPoint = CGPoint(x: 0.0, y: 0.5)
            spineDividingLineView.frame = CGRect(x: bounds.width - 0.5, y: 0, width: 0.5, height: bounds.height)
        default:
            spineGradientLayer.frame = CGRect(x: 0, y: 0, width: spineWidth, height: bounds.height)
            spineDividingLineView.frame = CGRect(x: 0, y: 0, width: 0.5, height: bounds.height)
        }
    }

    // MARK: - 模式渲染切换
    public func applyBackgroundStyle() {
        switch currentBackground {
        case .followSystem:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = true
            baseColorView.backgroundColor = .systemBackground

        case .light:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = true
            baseColorView.backgroundColor = .white

        case .dark:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = true
            baseColorView.backgroundColor = .black

        case .immersive:
            immersiveBackgroundView.isHidden = false
            textureCompositeView.isHidden = true
            baseColorView.backgroundColor = .black

        case .texture:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = false
            baseColorView.backgroundColor = blendedPaperColor()
            updateTextureImage()
        }
    }

    private func blendedPaperColor() -> UIColor {
        let t = min(max(textureTintOpacity, 0.0), 1.0)
        var r: CGFloat = 1.0
        var g: CGFloat = 1.0
        var b: CGFloat = 1.0
        var a: CGFloat = 1.0
        currentTexture.basePaperColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(
            red: (1.0 - t) + t * r,
            green: (1.0 - t) + t * g,
            blue: (1.0 - t) + t * b,
            alpha: 1.0
        )
    }

    private func updateTextureImage() {
        let t = min(max(textureTintOpacity, 0.0), 1.0)
        textureCompositeView.alpha = CGFloat(
            ReaderTextureCache.perceptualOpacity(for: currentTexture, rawOpacity: Double(textureOpacity))
        )

        if let img = ReaderTextureCache.shared.textureImage(for: currentTexture) {
            if currentTexture.usesFineTilePattern {
                neutralTextureOverlayView.isHidden = true
                neutralTextureOverlayView.image = nil
                neutralTextureOverlayView.backgroundColor = .clear

                textureOverlayView.isHidden = false
                textureOverlayView.image = nil
                textureOverlayView.backgroundColor = ReaderTextureCache.shared.patternColor(for: currentTexture)
                textureOverlayView.alpha = 1.0
            } else {
                neutralTextureOverlayView.backgroundColor = .clear
                textureOverlayView.backgroundColor = .clear

                let neutralImg = t < 0.999 ? ReaderTextureCache.shared.neutralGrainImage(for: currentTexture) : nil
                if let neutralImg, t < 0.999 {
                    neutralTextureOverlayView.isHidden = false
                    neutralTextureOverlayView.contentMode = .scaleAspectFill
                    neutralTextureOverlayView.image = neutralImg
                    neutralTextureOverlayView.alpha = 1.0
                } else {
                    neutralTextureOverlayView.isHidden = true
                    neutralTextureOverlayView.image = nil
                }

                if t > 0.001 || neutralImg == nil {
                    textureOverlayView.isHidden = false
                    textureOverlayView.contentMode = .scaleAspectFill
                    textureOverlayView.image = img
                    textureOverlayView.alpha = (neutralImg == nil) ? 1.0 : t
                } else {
                    textureOverlayView.isHidden = true
                    textureOverlayView.alpha = 0.0
                }
            }
        } else {
            neutralTextureOverlayView.image = nil
            neutralTextureOverlayView.backgroundColor = .clear
            textureOverlayView.image = nil
            textureOverlayView.backgroundColor = .clear
        }
    }

    // MARK: - 沉浸式动态氛围高斯模糊 (CoreImage 异步高效管线)
    public func updateImmersiveContent(from comicImage: UIImage?) {
        guard currentBackground == .immersive, let image = comicImage else {
            immersiveBackgroundView.image = nil
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let blurred = self.generateAmbientBlur(image: image, radius: 45.0)
            DispatchQueue.main.async {
                UIView.transition(with: self.immersiveBackgroundView,
                                  duration: 0.35,
                                  options: .transitionCrossDissolve,
                                  animations: {
                    self.immersiveBackgroundView.image = blurred
                })
            }
        }
    }

    private func generateAmbientBlur(image: UIImage, radius: Double) -> UIImage? {
        guard let cgImg = image.cgImage else { return nil }
        
        // 关键优化：先对大图进行下采样以极低开销执行高斯模糊
        let targetSize = CGSize(width: 256, height: 256 * CGFloat(cgImg.height) / CGFloat(cgImg.width))
        let ciImage = CIImage(cgImage: cgImg)
        let scale = targetSize.width / CGFloat(cgImg.width)
        let scaledCI = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(scaledCI, forKey: kCIInputImageKey)
        filter.setValue(radius * Double(scale), forKey: kCIInputRadiusKey)

        guard let outputCI = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        if let outCG = context.createCGImage(outputCI, from: scaledCI.extent) {
            return UIImage(cgImage: outCG)
        }
        return nil
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if currentBackground == .followSystem {
            applyBackgroundStyle()
        }
    }
}

// MARK: - 3. SwiftUI 拟真纸质与书脊光影扩展组件

/// 纸张纹理平铺相位锚点模式
public enum TexturePhaseAnchor: Equatable, Sendable {
    /// 绑定当前视图自身坐标系（默认）：翻页、滚动、缩放时纹理严格贴合漫画纸面同步移动
    case local
    /// 绑定指定命名内容坐标系（如条漫 ScrollView 内部 LazyVStack）：
    /// 纹理随滚动内容一起移动，同时保证多张条漫切片拼接处 100% 无缝相位衔接
    case namedSpace(String)
}

/// 拟真纸张纹理正片叠底覆盖层 (SwiftUI)
/// 严格采用正片叠底 Multiply 模式，暗部与深色墨水天然吸收，彻底杜绝任何泛白与发灰
public struct PaperTextureOverlayView: View {
    public let texture: ReaderTextureType
    public let opacity: Double
    public let tintOpacity: Double
    public let phaseAnchor: TexturePhaseAnchor
    public let referenceSize: CGSize?

    public init(
        texture: ReaderTextureType,
        opacity: Double = 0.4,
        tintOpacity: Double = 1.0,
        phaseAnchor: TexturePhaseAnchor = .local,
        referenceSize: CGSize? = nil
    ) {
        self.texture = texture
        self.opacity = opacity
        self.tintOpacity = tintOpacity
        self.phaseAnchor = phaseAnchor
        self.referenceSize = referenceSize
    }

    public var body: some View {
        if let img = ReaderTextureCache.shared.textureImage(for: texture) {
            let effectiveOpacity = ReaderTextureCache.perceptualOpacity(for: texture, rawOpacity: opacity)
            let clampedTint = min(max(tintOpacity, 0.0), 1.0)

            switch phaseAnchor {
            case .local:
                if texture.usesFineTilePattern {
                    // 经典高密浮雕微粒：原生 1:1 逻辑尺寸 (256×256pt) 无缝重复平铺
                    Image(uiImage: img)
                        .resizable(resizingMode: .tile)
                        .blendMode(.multiply)
                        .opacity(effectiveOpacity)
                        .allowsHitTesting(false)
                } else {
                    let neutralImg = clampedTint < 0.999 ? ReaderTextureCache.shared.neutralGrainImage(for: texture) : nil
                    // 与画面层 ZoomableImageView 保持完全一致的 AspectFill 缩放与居中锚点，
                    // 避免高分原图 1:1 平铺导致背景纹理颗粒过大及边缘接缝错位
                    GeometryReader { proxy in
                        let targetSize = validReferenceSize() ?? proxy.size
                        ZStack {
                            if let neutralImg, clampedTint < 0.999 {
                                aspectFilledTexture(neutralImg, targetSize: targetSize, containerSize: proxy.size)
                            }
                            if clampedTint > 0.001 || neutralImg == nil {
                                aspectFilledTexture(img, targetSize: targetSize, containerSize: proxy.size)
                                    .opacity(neutralImg == nil ? 1.0 : clampedTint)
                            }
                        }
                        .compositingGroup()
                    }
                    .blendMode(.multiply)
                    .opacity(effectiveOpacity)
                    .allowsHitTesting(false)
                }

            case .namedSpace(let spaceName):
                if texture.usesFineTilePattern {
                    let tileW = max(img.size.width, 64.0)
                    let tileH = max(img.size.height, 64.0)
                    GeometryReader { proxy in
                        let viewW = proxy.size.width
                        let viewH = proxy.size.height
                        if viewW > 0, viewH > 0 {
                            let contentFrame = proxy.frame(in: .named(spaceName))
                            let phaseX = Self.positiveModulo(contentFrame.minX, divisor: tileW)
                            let phaseY = Self.positiveModulo(contentFrame.minY, divisor: tileH)

                            Color.clear
                                .frame(width: viewW, height: viewH)
                                .overlay(alignment: .topLeading) {
                                    Image(uiImage: img)
                                        .resizable(resizingMode: .tile)
                                        .frame(width: viewW + tileW, height: viewH + tileH)
                                        .offset(x: -phaseX, y: -phaseY)
                                }
                                .clipped()
                        }
                    }
                    .blendMode(.multiply)
                    .opacity(effectiveOpacity)
                    .allowsHitTesting(false)
                } else {
                    let tileImg = ReaderTextureCache.shared.seamlessTileImage(for: texture) ?? img
                    let neutralTileImg = clampedTint < 0.999 ? ReaderTextureCache.shared.seamlessNeutralTileImage(for: texture) : nil
                    let refSize = validReferenceSize() ?? fallbackScreenSize()
                    let singleSize = Self.scaledTileSize(for: img, fitting: refSize)
                    let screenScale = max(UIScreen.main.scale, 1.0)
                    let tileW = max(64.0, (singleSize.width * 2.0 * screenScale).rounded() / screenScale)
                    let tileH = max(64.0, (singleSize.height * 2.0 * screenScale).rounded() / screenScale)
                    GeometryReader { proxy in
                        let viewW = proxy.size.width
                        let viewH = proxy.size.height
                        if viewW > 0, viewH > 0 {
                            let contentFrame = proxy.frame(in: .named(spaceName))

                            let phaseX = Self.positiveModulo(contentFrame.minX, divisor: tileW)
                            let phaseY = Self.positiveModulo(contentFrame.minY, divisor: tileH)

                            let cols = min(max(1, Int(ceil((viewW + phaseX) / tileW))), 64)
                            let rows = min(max(1, Int(ceil((viewH + phaseY) / tileH))), 64)

                            Color.clear
                                .frame(width: viewW, height: viewH)
                                .overlay(alignment: .topLeading) {
                                    ZStack {
                                        if let neutralTileImg, clampedTint < 0.999 {
                                            tileGridView(tileImg: neutralTileImg, rows: rows, cols: cols, tileW: tileW, tileH: tileH)
                                        }
                                        if clampedTint > 0.001 || neutralTileImg == nil {
                                            tileGridView(tileImg: tileImg, rows: rows, cols: cols, tileW: tileW, tileH: tileH)
                                                .opacity(neutralTileImg == nil ? 1.0 : clampedTint)
                                        }
                                    }
                                    .compositingGroup()
                                    .offset(x: -phaseX, y: -phaseY)
                                }
                                .clipped()
                        }
                    }
                    .blendMode(.multiply)
                    .opacity(effectiveOpacity)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func aspectFilledTexture(_ image: UIImage, targetSize: CGSize, containerSize: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: targetSize.width, height: targetSize.height)
            .frame(width: containerSize.width, height: containerSize.height)
            .clipped()
    }

    private func tileGridView(tileImg: UIImage, rows: Int, cols: Int, tileW: CGFloat, tileH: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<cols, id: \.self) { _ in
                        Image(uiImage: tileImg)
                            .resizable()
                            .frame(width: tileW, height: tileH)
                    }
                }
            }
        }
    }

    private func validReferenceSize() -> CGSize? {
        guard let ref = referenceSize, ref.width > 0, ref.height > 0 else {
            return nil
        }
        return ref
    }

    private func fallbackScreenSize() -> CGSize {
        let screenSize = UIScreen.main.bounds.size
        if screenSize.width > 0, screenSize.height > 0 {
            return screenSize
        }
        return CGSize(width: 390, height: 844)
    }

    private static func positiveModulo(_ value: CGFloat, divisor: CGFloat) -> CGFloat {
        guard value.isFinite, divisor > 0 else { return 0 }
        let raw = value.truncatingRemainder(dividingBy: divisor)
        let mod = raw >= 0 ? raw : raw + divisor
        return mod >= divisor ? 0 : mod
    }

    /// 计算与全屏 AspectFill 纹理颗粒大小完全一致的平铺单元尺寸
    private static func scaledTileSize(for img: UIImage, fitting refSize: CGSize) -> CGSize {
        let imgW = img.size.width
        let imgH = img.size.height
        guard imgW > 0, imgH > 0, refSize.width > 0, refSize.height > 0 else {
            return CGSize(width: max(imgW, 64.0), height: max(imgH, 64.0))
        }
        let fillScale = max(refSize.width / imgW, refSize.height / imgH)
        return CGSize(
            width: max(imgW * fillScale, 64.0),
            height: max(imgH * fillScale, 64.0)
        )
    }
}

/// 兼容性覆层 (向后兼容历史调用)
public struct ProceduralStuccoMultiPassOverlayView: View {
    public let opacity: Double
    public let phaseAnchor: TexturePhaseAnchor

    public init(opacity: Double = 0.4, phaseAnchor: TexturePhaseAnchor = .local) {
        self.opacity = opacity
        self.phaseAnchor = phaseAnchor
    }

    public var body: some View {
        PaperTextureOverlayView(
            texture: .whiteWall,
            opacity: opacity,
            phaseAnchor: phaseAnchor
        )
    }
}

/// 兼容性白墙覆盖层 (向后兼容历史调用)
public struct ProceduralStuccoOverlayView: View {
    public let opacity: Double
    public let phaseAnchor: TexturePhaseAnchor

    public init(opacity: Double = 0.4, phaseAnchor: TexturePhaseAnchor = .local) {
        self.opacity = opacity
        self.phaseAnchor = phaseAnchor
    }

    public var body: some View {
        PaperTextureOverlayView(
            texture: .whiteWall,
            opacity: opacity,
            phaseAnchor: phaseAnchor
        )
    }
}

/// 兼容性白墙底布视图 (向后兼容历史调用)
public struct StuccoWallBackgroundView: View {
    public let baseColor: Color
    public let intensity: Double

    public init(
        baseColor: Color = Color(red: 0.960, green: 0.960, blue: 0.953),
        intensity: Double = 0.35
    ) {
        self.baseColor = baseColor
        self.intensity = intensity
    }

    public var body: some View {
        ZStack {
            baseColor
            PaperTextureOverlayView(texture: .whiteWall, opacity: intensity)
        }
        .ignoresSafeArea()
    }
}

/// 仿真立体书脊阴影覆盖层 (SwiftUI)
public struct SpineShadowOverlayView: View {
    public enum Edge {
        case leading
        case trailing
        case center
    }

    public let edge: Edge
    public let showDividingLine: Bool

    public init(edge: Edge = .leading, showDividingLine: Bool = true) {
        self.edge = edge
        self.showDividingLine = showDividingLine
    }

    public var body: some View {
        GeometryReader { _ in
            switch edge {
            case .leading:
                HStack(spacing: 0) {
                    if showDividingLine {
                        Color.black.opacity(0.12)
                            .frame(width: 0.5)
                    }
                    LinearGradient(
                        colors: [Color.black.opacity(0.24), Color.black.opacity(0.06), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 24)
                    Spacer()
                }
            case .trailing:
                HStack(spacing: 0) {
                    Spacer()
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.06), Color.black.opacity(0.24)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 24)
                    if showDividingLine {
                        Color.black.opacity(0.12)
                            .frame(width: 0.5)
                    }
                }
            case .center:
                HStack(spacing: 0) {
                    Spacer()
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.15)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 16)
                    if showDividingLine {
                        Color.black.opacity(0.15)
                            .frame(width: 1)
                    }
                    LinearGradient(
                        colors: [Color.black.opacity(0.15), Color.clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 16)
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }
}
