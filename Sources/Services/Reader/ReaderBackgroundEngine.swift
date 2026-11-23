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
    private let tiledImageCache = NSCache<NSString, UIImage>()
    private let patternColorCache = NSCache<NSString, UIColor>()
    private let ambientBlurCache = NSCache<NSString, UIImage>()
    private var classicPlasterBaseImage: UIImage?
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

    /// 经典程序化浮雕纸纹的 100% 最大颗粒数量基准（与 MangaPrism 1:1 对齐）
    public static let maxClassicGrainCount: Int = 23_500

    private init() {
        cache.countLimit = 40
        seamlessTileCache.countLimit = 24
        tiledImageCache.countLimit = 28
        ambientBlurCache.countLimit = 12
    }

    /// 将颗粒密度归一化到 10% ~ 100% 的 5% 离散步进百分比，确保缓存命中率高、滑块拖动跟手
    public static func quantizedGrainDensityPercent(_ density: Double) -> Int {
        let clamped = min(max(density, 0.10), 1.0)
        let stepped = (clamped * 20.0).rounded() * 5.0
        return min(max(Int(stepped), 10), 100)
    }

    /// 感知强度映射：经典粉刷采用 1:1 线性透明度（对齐 MangaPrism StuccoTextureOverlay），
    /// 避免非线性抬升导致高档位人脸发灰显脏，同时让 35%~60% 常用区间保持通透细腻
    public static func perceptualOpacity(for texture: ReaderTextureType, rawOpacity: Double) -> Double {
        return min(max(rawOpacity, 0.0), 1.0)
    }

    /// 经典粉刷模式严格采用纯单层 Multiply（正片叠底），不再叠加额外的 Overlay 高光层，
    /// 以确保深色/中暗调区域零白噪泛灰、彩漫零掉饱和度（保留接口返回 0.0 兼容旧调用）
    public static func highlightOverlayOpacity(for texture: ReaderTextureType, rawOpacity: Double) -> Double {
        return 0.0
    }

    /// 非经典位图材质的分级物理无缝切片逻辑尺寸（取消全员 160pt 2×2 浓缩格子，恢复舒展真实的材质比例）
    public static func macroTileLogicalSize(for texture: ReaderTextureType) -> CGFloat {
        switch texture {
        case .classic:      return 128.0
        case .brownPaper:   return 220.0
        case .whiteWall:    return 260.0
        case .grungePaper:  return 240.0
        case .tissueMarble: return 280.0
        case .wood:         return 320.0
        }
    }

    /// 双层细节纸纹 (Detail Mipmap) 动态权重计算（现已全量支持经典与全部 5 种非经典材质）：
    /// - 1.0x 常规或缩小阅读：100% 宏观层，0% 微观层（零额外渲染开销）；
    /// - 1.08x -> 2.35x 双指/双击放大：Smoothstep 平滑交叉过渡，宏观层渐退，高频微观层平滑接管，彻底消除放大颗粒变大发糊；
    /// - > 2.6x 超高倍放大：施加轻度高倍阻尼衰减，查看极小字或局部笔触时清爽不噪。
    public static func zoomMipmapOpacities(
        for texture: ReaderTextureType,
        baseOpacity: Double,
        zoomScale: CGFloat
    ) -> (coarse: Double, fine: Double) {
        let effBase = perceptualOpacity(for: texture, rawOpacity: baseOpacity)
        guard effBase > 0.001, zoomScale > 1.08 else {
            return (coarse: effBase, fine: 0.0)
        }

        let z = Double(min(max(zoomScale, 1.0), 5.2))
        let u = min(max((z - 1.08) / (2.35 - 1.08), 0.0), 1.0)
        let t = u * u * (3.0 - 2.0 * u) // Smoothstep 三次平滑曲线，捏合过程零突变

        // 经典材质保留 28% 底斑起伏 + 88% 微粒；位图材质保留 34% 宏观肌理色调 + 88% 1:1 高频纤维
        let coarseFloor = texture.usesFineTilePattern ? 0.28 : 0.34
        let coarseWeight = 1.0 - t * (1.0 - coarseFloor)
        let fineWeight = t * 0.88

        // 超高倍率 (> 2.6x ~ 5.0x) 轻度衰减，避免极端放大时微观层也变粗
        let highZoomDamping: Double
        if z > 2.60 {
            let hu = min(max((z - 2.60) / (5.0 - 2.60), 0.0), 1.0)
            highZoomDamping = 1.0 - hu * 0.38
        } else {
            highZoomDamping = 1.0
        }

        return (
            coarse: effBase * coarseWeight * highZoomDamping,
            fine: effBase * fineWeight * highZoomDamping
        )
    }

    private func cacheKey(for type: ReaderTextureType, grainDensity: Double) -> NSString {
        if type.usesFineTilePattern {
            let pct = Self.quantizedGrainDensityPercent(grainDensity)
            return "\(type.rawValue)_d\(pct)" as NSString
        }
        return type.rawValue as NSString
    }

    private func fineDetailCacheKey(for type: ReaderTextureType, grainDensity: Double) -> NSString {
        if type.usesFineTilePattern {
            let pct = Self.quantizedGrainDensityPercent(grainDensity)
            return "\(type.rawValue)_fine64_d\(pct)" as NSString
        }
        return "\(type.rawValue)_fine88_highpass" as NSString
    }

    /// 获取指定纸张纹理图像（带内存二级缓存；经典材质支持按 10%~100% 颗粒数量缓存切片）
    public func textureImage(for type: ReaderTextureType, grainDensity: Double = 1.0) -> UIImage? {
        let key = cacheKey(for: type, grainDensity: grainDensity)
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
            let pct = Self.quantizedGrainDensityPercent(grainDensity)
            let screenScale: CGFloat = Thread.isMainThread ? max(UIScreen.main.scale, 2.0) : 3.0
            let plasterBase = classicPlasterBaseImage ?? {
                let base = Self.buildClassicPlasterBaseTile(screenScale: screenScale)
                self.classicPlasterBaseImage = base
                return base
            }()
            loaded = Self.buildProceduralClassicStuccoTile(
                densityPercent: pct,
                screenScale: screenScale,
                plasterBase: plasterBase
            )
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

    /// 获取缓存的 GPU 原生无缝平铺图像（供 UIImageView 1:1 左上角对齐平铺，支持 nearest 最近邻采样且无 Y 轴翻转）
    public func tiledTextureImage(for type: ReaderTextureType, grainDensity: Double = 1.0) -> UIImage? {
        let key = cacheKey(for: type, grainDensity: grainDensity)
        if let cached = tiledImageCache.object(forKey: key) {
            return cached
        }
        let baseImg: UIImage?
        if type.usesFineTilePattern {
            baseImg = textureImage(for: type, grainDensity: grainDensity)
        } else {
            // 对除经典外的其他材质，使用无缝 160pt 高密平铺切片，避免 AspectFill 放大 5 倍导致的粗糙噪点感
            baseImg = seamlessDenseTileImage(for: type)
        }
        guard let img = baseImg else {
            return nil
        }
        let tiled = img.resizableImage(withCapInsets: .zero, resizingMode: .tile)
        tiledImageCache.setObject(tiled, forKey: key)
        return tiled
    }

    /// 获取缓存的去色中性版 GPU 原生无缝平铺图像（供着色度 < 100% 时无缝混合使用）
    public func tiledNeutralTextureImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            return tiledTextureImage(for: type)
        }
        let key = "\(type.rawValue)_neutral_dense_tiled" as NSString
        if let cached = tiledImageCache.object(forKey: key) {
            return cached
        }
        guard let img = seamlessNeutralDenseTileImage(for: type) else {
            return nil
        }
        let tiled = img.resizableImage(withCapInsets: .zero, resizingMode: .tile)
        tiledImageCache.setObject(tiled, forKey: key)
        return tiled
    }

    /// 获取其它位图材质的舒展无接缝平铺切片（按材质分级至 220~320pt，采用偏移交叉羽化消除镜像格子感）
    public func seamlessDenseTileImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            return textureImage(for: type)
        }
        let key = "\(type.rawValue)_offset_wrap_tile" as NSString
        if let cached = seamlessTileCache.object(forKey: key) {
            return cached
        }
        guard let baseImg = textureImage(for: type) else {
            return nil
        }

        let logicalSize = Self.macroTileLogicalSize(for: type)
        return queue.sync {
            if let cached = seamlessTileCache.object(forKey: key) {
                return cached
            }
            let generated = Self.buildSeamlessDenseTile(from: baseImg, targetLogicalSize: logicalSize)
            seamlessTileCache.setObject(generated, forKey: key)
            return generated
        }
    }

    /// 获取其它位图材质去色中性版的舒展无接缝平铺切片
    public func seamlessNeutralDenseTileImage(for type: ReaderTextureType) -> UIImage? {
        if type.usesFineTilePattern {
            return textureImage(for: type)
        }
        let key = "\(type.rawValue)_neutral_offset_wrap_tile" as NSString
        if let cached = seamlessTileCache.object(forKey: key) {
            return cached
        }
        guard let neutralImg = neutralGrainImage(for: type) else {
            return nil
        }

        let logicalSize = Self.macroTileLogicalSize(for: type)
        return queue.sync {
            if let cached = seamlessTileCache.object(forKey: key) {
                return cached
            }
            let generated = Self.buildSeamlessDenseTile(from: neutralImg, targetLogicalSize: logicalSize)
            seamlessTileCache.setObject(generated, forKey: key)
            return generated
        }
    }

    private static func buildSeamlessDenseTile(from image: UIImage, targetLogicalSize: CGFloat = 240.0) -> UIImage {
        let screenScale: CGFloat = Thread.isMainThread ? max(UIScreen.main.scale, 2.0) : 3.0
        return buildOffsetWrapSeamlessTile(
            from: image,
            targetLogicalSize: targetLogicalSize,
            screenScale: screenScale
        )
    }

    /// 获取双层细节纸纹 (Mipmap Level 1) 的高频微观切片：
    /// - 经典材质：64×64pt 程序化高密微粒
    /// - 位图材质：88×88pt 原图 1:1 像素中心高通提取的高频纤维无缝切片（放大看细节时锐利不糊）
    public func fineDetailTextureImage(for type: ReaderTextureType, grainDensity: Double = 1.0) -> UIImage? {
        let key = fineDetailCacheKey(for: type, grainDensity: grainDensity)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        if type.usesFineTilePattern {
            loadLock.lock()
            defer { loadLock.unlock() }
            if let cached = cache.object(forKey: key) {
                return cached
            }
            let pct = Self.quantizedGrainDensityPercent(grainDensity)
            let screenScale: CGFloat = Thread.isMainThread ? max(UIScreen.main.scale, 2.0) : 3.0
            let generated = Self.buildProceduralClassicStuccoTile(
                densityPercent: pct,
                screenScale: screenScale,
                plasterBase: nil,
                tileSize: 64.0,
                seed: 20261119
            )
            cache.setObject(generated, forKey: key)
            return generated
        }

        guard let baseImg = textureImage(for: type) else {
            return nil
        }
        return queue.sync {
            if let cached = cache.object(forKey: key) {
                return cached
            }
            let screenScale: CGFloat = Thread.isMainThread ? max(UIScreen.main.scale, 2.0) : 3.0
            let generated = Self.buildBitmapFineDetailTile(
                from: baseImg,
                targetLogicalSize: 88.0,
                screenScale: screenScale
            )
            cache.setObject(generated, forKey: key)
            return generated
        }
    }

    /// 获取缓存的微观层 GPU 原生无缝平铺图像（供放大状态下的第二层 Multiply 细节叠加使用）
    public func tiledFineDetailTextureImage(for type: ReaderTextureType, grainDensity: Double = 1.0) -> UIImage? {
        let key = fineDetailCacheKey(for: type, grainDensity: grainDensity)
        if let cached = tiledImageCache.object(forKey: key) {
            return cached
        }
        guard let img = fineDetailTextureImage(for: type, grainDensity: grainDensity) else {
            return nil
        }
        let tiled = img.resizableImage(withCapInsets: .zero, resizingMode: .tile)
        tiledImageCache.setObject(tiled, forKey: key)
        return tiled
    }

    /// 获取缓存的平铺画刷颜色（向后兼容旧调用）
    public func patternColor(for type: ReaderTextureType, grainDensity: Double = 1.0) -> UIColor? {
        let key = cacheKey(for: type, grainDensity: grainDensity)
        if let cached = patternColorCache.object(forKey: key) {
            return cached
        }
        guard let img = textureImage(for: type, grainDensity: grainDensity) else {
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

    /// 仅生成一次的透明底柔和纸浆光斑基础切片（42 处无缝明暗斑块），供各颗粒密度档位直接复用提速
    private static func buildClassicPlasterBaseTile(screenScale: CGFloat) -> UIImage {
        let tileSize: CGFloat = 128.0
        let scaleFactor: CGFloat = tileSize / 256.0
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize),
            format: format
        )

        return renderer.image { ctx in
            let cg = ctx.cgContext
            cg.clear(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

            var plasterRng = SplitMix64RNG(seed: 20261108)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            cg.setAllowsAntialiasing(true)
            cg.setShouldAntialias(true)
            for _ in 0..<42 {
                let cx = CGFloat(plasterRng.nextUnitDouble()) * tileSize
                let cy = CGFloat(plasterRng.nextUnitDouble()) * tileSize
                let baseRadius = (20.0 + CGFloat(plasterRng.nextUnitDouble()) * 38.0) * scaleFactor
                let softRadius = baseRadius + 12.0 * scaleFactor
                let isLight = plasterRng.nextBool()
                let component: CGFloat = isLight ? 1.0 : 0.0
                let peakAlpha: CGFloat = isLight ? 0.055 : 0.020

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
        }
    }

    /// 1:1 复刻 MangaPrism StuccoTextureManager 的程序化高密立体浮雕纸纹引擎：
    /// 支持宏观基础层 (128×128pt) 与放大微观细节层 (64×64pt) 双尺度生成，
    /// 100% 对应 23,500 颗最大微粒数量，支持按 10%~100% 向下平滑调节颗粒疏密
    private static func buildProceduralClassicStuccoTile(
        densityPercent: Int,
        screenScale: CGFloat,
        plasterBase: UIImage?,
        tileSize: CGFloat = 128.0,
        seed: UInt64 = 20261109
    ) -> UIImage {
        let scaleFactor: CGFloat = tileSize / 256.0
        let grainCount = max(1, Int((Double(maxClassicGrainCount) * Double(densityPercent) / 100.0).rounded()))

        let format = UIGraphicsImageRendererFormat()
        format.scale = screenScale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize),
            format: format
        )

        return renderer.image { ctx in
            let cg = ctx.cgContext

            // 严格保持透明底（对齐 MangaPrism）：宏观层叠加 42 处柔和纸浆起伏斑块，微观层专注纯粹细微纤维
            cg.clear(CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
            plasterBase?.draw(in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

            // Layer 2: 按目标密度绘制前 grainCount 颗无缝立体浮雕微粒（固定种子保证减密时保留的颗粒原地不动）
            var grainRng = SplitMix64RNG(seed: seed)
            cg.setAllowsAntialiasing(false)
            cg.setShouldAntialias(false)

            let poreR: CGFloat = 69.0 / 255.0   // #45474D 炭灰纸浆微孔
            let poreG: CGFloat = 71.0 / 255.0
            let poreB: CGFloat = 77.0 / 255.0
            let shadowOffset: CGFloat = 0.85 * scaleFactor
            let shadowMinDiameter: CGFloat = 0.95 * scaleFactor

            for _ in 0..<grainCount {
                let x = CGFloat(grainRng.nextUnitDouble()) * tileSize
                let y = CGFloat(grainRng.nextUnitDouble()) * tileSize
                // 保留大量细砂，同时让 16% 较大高光颗粒形成清晰的立体视觉锚点
                let rawDiameter: CGFloat = grainRng.nextUnitDouble() < 0.16
                    ? (1.55 + CGFloat(grainRng.nextUnitDouble()) * 1.15)
                    : (0.75 + CGFloat(grainRng.nextUnitDouble()) * 1.05)
                let diameter = rawDiameter * scaleFactor
                let isRaisedGrain = grainRng.nextUnitDouble() > 0.36

                if isRaisedGrain {
                    if diameter > shadowMinDiameter {
                        let shadowAlpha = 0.10 + CGFloat(grainRng.nextUnitDouble()) * 0.14
                        cg.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: shadowAlpha)
                        var sx = x + shadowOffset
                        if sx >= tileSize { sx -= tileSize }
                        var sy = y + shadowOffset
                        if sy >= tileSize { sy -= tileSize }
                        drawSeamlessDot(in: cg, x: sx, y: sy, diameter: diameter * 0.88, tileSize: tileSize)
                    }

                    let highlightAlpha = 0.82 + CGFloat(grainRng.nextUnitDouble()) * 0.18
                    cg.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: highlightAlpha)
                    drawSeamlessDot(in: cg, x: x, y: y, diameter: diameter, tileSize: tileSize)
                } else {
                    let poreAlpha = 0.12 + CGFloat(grainRng.nextUnitDouble()) * 0.16
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
        if !crossesLeft && !crossesRight && !crossesTop && !crossesBottom {
            return
        }

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

    /// 对位图纹理执行中心裁剪 + 半周期偏移交叉羽化（Offset-Wrap Cross-Fade）：
    /// 相比 2×2 镜像翻转，既保证 100% 四边无缝循环，又保持完整单份纹理物理尺度，彻底消除对称格子感。
    private static func buildOffsetWrapSeamlessTile(
        from image: UIImage,
        targetLogicalSize: CGFloat,
        screenScale: CGFloat
    ) -> UIImage {
        let origW = image.size.width
        let origH = image.size.height
        guard origW > 32, origH > 32 else { return image }

        let pixelDim = min(max(Int((targetLogicalSize * screenScale).rounded()), 160), 768)
        let cropSize = CGSize(width: pixelDim, height: pixelDim)
        let trimRatio: CGFloat = 0.03
        let visibleRatio = 1.0 - trimRatio * 2.0

        // 取原图中心最大内接正方形（保持 AspectFill 不拉伸变形）
        let srcMinSide = min(origW, origH) * visibleRatio
        let drawScale = CGFloat(pixelDim) / max(srcMinSide, 1.0)
        let drawW = origW * drawScale
        let drawH = origH * drawScale
        let originX = (CGFloat(pixelDim) - drawW) * 0.5
        let originY = (CGFloat(pixelDim) - drawH) * 0.5

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let squareImg = UIGraphicsImageRenderer(size: cropSize, format: format).image { _ in
            image.draw(in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
        }

        guard let srcBytes = extractRGBABytes(from: squareImg, width: pixelDim, height: pixelDim) else {
            return squareImg
        }
        // 关键第一步：应用 Retinex 平场低频分离归一化，彻底消除摄影暗角与大尺度倾斜光照
        let flatBytes = applyFlatFieldNormalization(srcBytes, width: pixelDim, height: pixelDim)
        // 关键第二步：执行双通道可分离升余弦无缝混合，达到几何上的完美环形平铺无缝
        let blended = applyOffsetWrapBlend(flatBytes, width: pixelDim, height: pixelDim)
        return makeUIImage(fromRGBABytes: blended, width: pixelDim, height: pixelDim, scale: screenScale) ?? squareImg
    }

    /// 从高清位图原图中心 1:1 像素截取局部，经高通滤波提取纯白底细微纸纤并无缝偏移混合，专供放大 Mipmap Level 1 接管使用
    private static func buildBitmapFineDetailTile(
        from image: UIImage,
        targetLogicalSize: CGFloat = 88.0,
        screenScale: CGFloat
    ) -> UIImage {
        let pixelDim = min(max(Int((targetLogicalSize * screenScale).rounded()), 160), 320)
        let tilePxSize = CGSize(width: pixelDim, height: pixelDim)

        let rawPxW = image.cgImage.map { CGFloat($0.width) } ?? (image.size.width * image.scale)
        let rawPxH = image.cgImage.map { CGFloat($0.height) } ?? (image.size.height * image.scale)
        guard rawPxW > 32, rawPxH > 32 else { return image }

        // 若原图分辨率足够大，按 1:1 原图物理像素从中心裁取 pixelDim×pixelDim 区域，完全不缩水
        let sampleSpan = min(rawPxW, rawPxH, CGFloat(pixelDim))
        let scaleFactor = CGFloat(pixelDim) / max(sampleSpan, 1.0)
        let drawW = rawPxW * scaleFactor
        let drawH = rawPxH * scaleFactor
        let originX = (CGFloat(pixelDim) - drawW) * 0.5
        let originY = (CGFloat(pixelDim) - drawH) * 0.5

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let patchImg = UIGraphicsImageRenderer(size: tilePxSize, format: format).image { _ in
            image.draw(in: CGRect(x: originX, y: originY, width: drawW, height: drawH))
        }

        guard let srcBytes = extractRGBABytes(from: patchImg, width: pixelDim, height: pixelDim) else {
            return patchImg
        }

        // 转灰度并做可分离盒式低通分离，提取高频细微纤维落差
        let totalCount = pixelDim * pixelDim
        var gray = [Float](repeating: 0, count: totalCount)
        for i in 0..<totalCount {
            let idx = i * 4
            let r = Float(srcBytes[idx])
            let g = Float(srcBytes[idx + 1])
            let b = Float(srcBytes[idx + 2])
            gray[i] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        }

        let radius = 4
        let horiz = boxBlur1DHorizontal(gray, width: pixelDim, height: pixelDim, radius: radius)
        let lowFreq = boxBlur1DVertical(horiz, width: pixelDim, height: pixelDim, radius: radius)

        var highPassBytes = [UInt8](repeating: 255, count: totalCount * 4)
        for i in 0..<totalCount {
            let diff = gray[i] - lowFreq[i]
            // 中性高通白底 [0.74, 1.0]，均值落在 ~0.96，确保正片叠底放大时清晰细腻且绝不发灰变脏
            let hp = min(max(0.96 + diff * 1.55, 0.74), 1.0)
            let byte = UInt8((hp * 255.0).rounded())
            let idx = i * 4
            highPassBytes[idx] = byte
            highPassBytes[idx + 1] = byte
            highPassBytes[idx + 2] = byte
            highPassBytes[idx + 3] = 255
        }

        let seamlessBytes = applyOffsetWrapBlend(highPassBytes, width: pixelDim, height: pixelDim)
        return makeUIImage(fromRGBABytes: seamlessBytes, width: pixelDim, height: pixelDim, scale: screenScale) ?? patchImg
    }

    private static func extractRGBABytes(from image: UIImage, width: Int, height: Int) -> [UInt8]? {
        guard let cgImg = image.cgImage else { return nil }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    private static func makeUIImage(fromRGBABytes bytes: [UInt8], width: Int, height: Int, scale: CGFloat) -> UIImage? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var mutableBytes = bytes
        guard let ctx = CGContext(
            data: &mutableBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let outCG = ctx.makeImage() else {
            return nil
        }
        return UIImage(cgImage: outCG, scale: scale, orientation: .up)
    }

    /// 平场低频分离归一化（Flat-Field Normalization via Retinex Division）：
    /// 将图像分离为宏观低频光照场 L(x, y) 与高频微观物理材质反射率 R(x, y)。
    /// 通过逐像素除法 R = (I / L) * mean，彻底消除镜头光学暗角与打光不均，
    /// 同时 100% 完整保留物理纸纤维、纸浆斑点与真实木纹细节。
    private static func applyFlatFieldNormalization(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        let totalPixels = width * height
        guard totalPixels > 0 else { return src }

        var rChannel = [Float](repeating: 0, count: totalPixels)
        var gChannel = [Float](repeating: 0, count: totalPixels)
        var bChannel = [Float](repeating: 0, count: totalPixels)

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0

        for i in 0..<totalPixels {
            let idx = i * 4
            let r = Float(src[idx])
            let g = Float(src[idx + 1])
            let b = Float(src[idx + 2])
            rChannel[i] = r
            gChannel[i] = g
            bChannel[i] = b
            sumR += Double(r)
            sumG += Double(g)
            sumB += Double(b)
        }

        let meanR = Float(sumR / Double(totalPixels))
        let meanG = Float(sumG / Double(totalPixels))
        let meanB = Float(sumB / Double(totalPixels))

        // 提取宏观光照场的滤波半径（约切片尺寸的 1/4 ~ 1/3，足够滤除纸张高频微观纤维，仅保留镜头暗角与大尺度光照梯度）
        let radius = max(width / 4, 16)

        // 级联两次可分离盒式滤波（具备环面环绕周期边界），数学上等价于大尺度近似高斯低通滤波
        let rBlurH1 = boxBlur1DHorizontal(rChannel, width: width, height: height, radius: radius)
        let rBlur1  = boxBlur1DVertical(rBlurH1, width: width, height: height, radius: radius)
        let rBlurH2 = boxBlur1DHorizontal(rBlur1, width: width, height: height, radius: radius / 2)
        let lowFreqR = boxBlur1DVertical(rBlurH2, width: width, height: height, radius: radius / 2)

        let gBlurH1 = boxBlur1DHorizontal(gChannel, width: width, height: height, radius: radius)
        let gBlur1  = boxBlur1DVertical(gBlurH1, width: width, height: height, radius: radius)
        let gBlurH2 = boxBlur1DHorizontal(gBlur1, width: width, height: height, radius: radius / 2)
        let lowFreqG = boxBlur1DVertical(gBlurH2, width: width, height: height, radius: radius / 2)

        let bBlurH1 = boxBlur1DHorizontal(bChannel, width: width, height: height, radius: radius)
        let bBlur1  = boxBlur1DVertical(bBlurH1, width: width, height: height, radius: radius)
        let bBlurH2 = boxBlur1DHorizontal(bBlur1, width: width, height: height, radius: radius / 2)
        let lowFreqB = boxBlur1DVertical(bBlurH2, width: width, height: height, radius: radius / 2)

        var out = [UInt8](repeating: 255, count: totalPixels * 4)
        for i in 0..<totalPixels {
            let idx = i * 4
            // 平场校准：(原像素 / 低频背景) * 全局平均色调
            let flatR = (rChannel[i] / max(lowFreqR[i], 1.0)) * meanR
            let flatG = (gChannel[i] / max(lowFreqG[i], 1.0)) * meanG
            let flatB = (bChannel[i] / max(lowFreqB[i], 1.0)) * meanB

            out[idx]     = UInt8(min(max(flatR.rounded(), 0.0), 255.0))
            out[idx + 1] = UInt8(min(max(flatG.rounded(), 0.0), 255.0))
            out[idx + 2] = UInt8(min(max(flatB.rounded(), 0.0), 255.0))
            out[idx + 3] = src[idx + 3]
        }
        return out
    }

    /// 对图像执行双通道可分离升余弦无缝环形混合（Separable Two-Pass Raised-Cosine Wrap Blend）：
    /// 先做水平无缝环绕混合，再做垂直无缝环绕混合。
    /// 彻底杜绝双轴相乘 (wx * wy) 在中心与十字边缘处产生的四角/边缘暗坑明暗互异畸变，
    /// 保证四边 100% 连续无缝平铺，且整体明暗严格均匀。
    private static func applyOffsetWrapBlend(_ src: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 2, height > 2 else { return src }
        let halfW = width / 2
        let halfH = height / 2

        @inline(__always)
        func raisedCosineWeight(_ coord: Int, total: Int) -> Float {
            let norm = (Float(coord) + 0.5) / Float(total)
            let dist = abs(2.0 * norm - 1.0)
            return 0.5 * (1.0 + cos(Float.pi * dist))
        }

        var wx = [Float](repeating: 0, count: width)
        for x in 0..<width { wx[x] = raisedCosineWeight(x, total: width) }
        var wy = [Float](repeating: 0, count: height)
        for y in 0..<height { wy[y] = raisedCosineWeight(y, total: height) }

        // Pass 1: 水平方向可分离平滑环绕混合 (每行独立处理，杜绝纵向交叉相乘干扰)
        var pass1 = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                let sx = (x + halfW) % width
                let w = wx[x]
                let invW = 1.0 - w

                let idxA = (rowBase + x) * 4
                let idxB = (rowBase + sx) * 4

                pass1[idxA]     = UInt8(min(max(Float(src[idxA])     * w + Float(src[idxB])     * invW, 0.0), 255.0))
                pass1[idxA + 1] = UInt8(min(max(Float(src[idxA + 1]) * w + Float(src[idxB + 1]) * invW, 0.0), 255.0))
                pass1[idxA + 2] = UInt8(min(max(Float(src[idxA + 2]) * w + Float(src[idxB + 2]) * invW, 0.0), 255.0))
                pass1[idxA + 3] = src[idxA + 3]
            }
        }

        // Pass 2: 垂直方向可分离平滑环绕混合 (每列独立处理，严格保持水平已无缝性，实现四边完美无缝)
        var out = [UInt8](repeating: 255, count: width * height * 4)
        for x in 0..<width {
            for y in 0..<height {
                let sy = (y + halfH) % height
                let w = wy[y]
                let invW = 1.0 - w

                let idxA = (y * width + x) * 4
                let idxB = (sy * width + x) * 4

                out[idxA]     = UInt8(min(max(Float(pass1[idxA])     * w + Float(pass1[idxB])     * invW, 0.0), 255.0))
                out[idxA + 1] = UInt8(min(max(Float(pass1[idxA + 1]) * w + Float(pass1[idxB + 1]) * invW, 0.0), 255.0))
                out[idxA + 2] = UInt8(min(max(Float(pass1[idxA + 2]) * w + Float(pass1[idxB + 2]) * invW, 0.0), 255.0))
                out[idxA + 3] = pass1[idxA + 3]
            }
        }

        return out
    }

    private static func boxBlur1DHorizontal(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let denom = Float(radius * 2 + 1)
        for y in 0..<height {
            let rowBase = y * width
            var sum: Float = 0
            for dx in -radius...radius {
                let x = (dx % width + width) % width
                sum += src[rowBase + x]
            }
            out[rowBase] = sum / denom
            for x in 1..<width {
                let addX = (x + radius) % width
                let subX = (x - radius - 1 + width) % width
                sum += src[rowBase + addX] - src[rowBase + subX]
                out[rowBase + x] = sum / denom
            }
        }
        return out
    }

    private static func boxBlur1DVertical(_ src: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var out = [Float](repeating: 0, count: width * height)
        let denom = Float(radius * 2 + 1)
        for x in 0..<width {
            var sum: Float = 0
            for dy in -radius...radius {
                let y = (dy % height + height) % height
                sum += src[y * width + x]
            }
            out[x] = sum / denom
            for y in 1..<height {
                let addY = (y + radius) % height
                let subY = (y - radius - 1 + height) % height
                sum += src[addY * width + x] - src[subY * width + x]
                out[y * width + x] = sum / denom
            }
        }
        return out
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

    /// 生成并缓存用于单页沉浸式背景的轻量下采样高斯模糊图（避免翻页 3D 卷曲动画对大图实时离屏模糊掉帧）
    public func ambientBlurImage(for image: UIImage, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = ambientBlurCache.object(forKey: key) {
            return cached
        }
        guard let cgImg = image.cgImage, cgImg.width > 0, cgImg.height > 0 else {
            return nil
        }

        let targetWidth: CGFloat = 180.0
        let scale = min(1.0, targetWidth / CGFloat(cgImg.width))
        let ciImage = CIImage(cgImage: cgImg)
        let scaledCI = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let targetExtent = scaledCI.extent

        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(scaledCI.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(6.0, 45.0 * Double(scale)), forKey: kCIInputRadiusKey)

        guard let outputCI = filter.outputImage?.cropped(to: targetExtent),
              let outCG = srgbContext.createCGImage(outputCI, from: targetExtent) else {
            return nil
        }

        let blurred = UIImage(cgImage: outCG, scale: 1.0, orientation: image.imageOrientation)
        ambientBlurCache.setObject(blurred, forKey: key)
        return blurred
    }

    /// 计算纹理着色与纯白底混合后的不透明纸浆基准色（供单页 UIHostingController 底层防穿透兜底）
    public static func blendedPaperUIColor(for texture: ReaderTextureType, tintOpacity: Double) -> UIColor {
        let t = CGFloat(min(max(tintOpacity, 0.0), 1.0))
        var r: CGFloat = 1.0
        var g: CGFloat = 1.0
        var b: CGFloat = 1.0
        var a: CGFloat = 1.0
        texture.basePaperColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(
            red: (1.0 - t) + t * r,
            green: (1.0 - t) + t * g,
            blue: (1.0 - t) + t * b,
            alpha: 1.0
        )
    }

    /// 解析当前阅读背景对应的不透明 UIKit 兜底色，杜绝翻页视图第 0 帧或安全区变动瞬间出现透明镂空
    public static func resolvedHostUIColor(
        background: ReaderBackground,
        texture: ReaderTextureType,
        tintOpacity: Double,
        textureTarget: ReaderTextureTarget,
        imageOnlyBackdrop: ReaderImageOnlyBackdrop
    ) -> UIColor {
        switch background {
        case .followSystem:
            return .systemBackground
        case .light:
            return .white
        case .dark, .immersive:
            return .black
        case .texture:
            if textureTarget == .imageOnly {
                switch imageOnlyBackdrop {
                case .paperTint:
                    return blendedPaperUIColor(for: texture, tintOpacity: tintOpacity)
                case .followSystem:
                    return .systemBackground
                case .light:
                    return .white
                case .dark, .immersive:
                    return .black
                }
            }
            return blendedPaperUIColor(for: texture, tintOpacity: tintOpacity)
        }
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
    /// Layer 2.5: 经典透明底浮雕纸纹的辅助高光层 (使用 overlayBlendMode 激活凸起微粒受光面，纯黑线稿零泛白)
    public let highlightOverlayView = UIImageView()
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
            highlightOverlayView.alpha = CGFloat(
                ReaderTextureCache.highlightOverlayOpacity(for: currentTexture, rawOpacity: Double(textureOpacity))
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

    public var textureGrainDensity: CGFloat = 1.0 {
        didSet {
            if currentBackground == .texture && currentTexture.usesFineTilePattern {
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

        highlightOverlayView.frame = bounds
        highlightOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        highlightOverlayView.contentMode = .scaleToFill
        highlightOverlayView.clipsToBounds = true
        highlightOverlayView.backgroundColor = .clear
        highlightOverlayView.layer.compositingFilter = "overlayBlendMode"
        highlightOverlayView.layer.magnificationFilter = .nearest
        highlightOverlayView.layer.minificationFilter = .nearest
        highlightOverlayView.isHidden = true
        addSubview(highlightOverlayView)

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
            highlightOverlayView.isHidden = true
            baseColorView.backgroundColor = .systemBackground

        case .light:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = true
            highlightOverlayView.isHidden = true
            baseColorView.backgroundColor = .white

        case .dark:
            immersiveBackgroundView.isHidden = true
            textureCompositeView.isHidden = true
            highlightOverlayView.isHidden = true
            baseColorView.backgroundColor = .black

        case .immersive:
            immersiveBackgroundView.isHidden = false
            textureCompositeView.isHidden = true
            highlightOverlayView.isHidden = true
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

        let grainDensity = Double(textureGrainDensity)
        if let img = ReaderTextureCache.shared.textureImage(for: currentTexture, grainDensity: grainDensity) {
            if currentTexture.usesFineTilePattern {
                let tiled = ReaderTextureCache.shared.tiledTextureImage(for: currentTexture, grainDensity: grainDensity) ?? img
                neutralTextureOverlayView.isHidden = true
                neutralTextureOverlayView.image = nil
                neutralTextureOverlayView.backgroundColor = .clear

                textureOverlayView.isHidden = false
                textureOverlayView.backgroundColor = .clear
                textureOverlayView.contentMode = .scaleToFill
                textureOverlayView.layer.magnificationFilter = .nearest
                textureOverlayView.layer.minificationFilter = .nearest
                textureOverlayView.image = tiled
                textureOverlayView.alpha = 1.0

                highlightOverlayView.isHidden = true
                highlightOverlayView.image = nil
                highlightOverlayView.alpha = 0.0
            } else {
                neutralTextureOverlayView.backgroundColor = .clear
                textureOverlayView.backgroundColor = .clear
                textureOverlayView.contentMode = .scaleToFill
                textureOverlayView.layer.magnificationFilter = .linear
                textureOverlayView.layer.minificationFilter = .linear

                highlightOverlayView.isHidden = true
                highlightOverlayView.image = nil
                highlightOverlayView.alpha = 0.0

                let neutralTiled = t < 0.999 ? ReaderTextureCache.shared.tiledNeutralTextureImage(for: currentTexture) : nil
                if let neutralTiled, t < 0.999 {
                    neutralTextureOverlayView.isHidden = false
                    neutralTextureOverlayView.contentMode = .scaleToFill
                    neutralTextureOverlayView.image = neutralTiled
                    neutralTextureOverlayView.alpha = 1.0
                } else {
                    neutralTextureOverlayView.isHidden = true
                    neutralTextureOverlayView.image = nil
                }

                let tiled = ReaderTextureCache.shared.tiledTextureImage(for: currentTexture, grainDensity: grainDensity)
                if t > 0.001 || neutralTiled == nil, let tiled {
                    textureOverlayView.isHidden = false
                    textureOverlayView.contentMode = .scaleToFill
                    textureOverlayView.image = tiled
                    textureOverlayView.alpha = (neutralTiled == nil) ? 1.0 : t
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
            highlightOverlayView.isHidden = true
            highlightOverlayView.image = nil
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

// MARK: - 阅读器当前缩放倍率环境键（驱动条漫/SwiftUI 纸纹双层细节 Mipmap 平滑交叉过渡）
private struct ReaderZoomScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

public extension EnvironmentValues {
    var readerZoomScale: CGFloat {
        get { self[ReaderZoomScaleKey.self] }
        set { self[ReaderZoomScaleKey.self] = newValue }
    }
}

/// 拟真纸张纹理正片叠底覆盖层 (SwiftUI)
/// 严格采用正片叠底 Multiply 模式，暗部与深色墨水天然吸收，彻底杜绝任何泛白与发灰
public struct PaperTextureOverlayView: View {
    @Environment(\.readerZoomScale) private var readerZoomScale: CGFloat

    public let texture: ReaderTextureType
    public let opacity: Double
    public let tintOpacity: Double
    public let grainDensity: Double
    public let phaseAnchor: TexturePhaseAnchor
    public let referenceSize: CGSize?

    public init(
        texture: ReaderTextureType,
        opacity: Double = 0.4,
        tintOpacity: Double = 1.0,
        grainDensity: Double = 1.0,
        phaseAnchor: TexturePhaseAnchor = .local,
        referenceSize: CGSize? = nil
    ) {
        self.texture = texture
        self.opacity = opacity
        self.tintOpacity = tintOpacity
        self.grainDensity = grainDensity
        self.phaseAnchor = phaseAnchor
        self.referenceSize = referenceSize
    }

    public var body: some View {
        if let img = ReaderTextureCache.shared.textureImage(for: texture, grainDensity: grainDensity) {
            let mip = ReaderTextureCache.zoomMipmapOpacities(
                for: texture,
                baseOpacity: opacity,
                zoomScale: readerZoomScale
            )
            let clampedTint = min(max(tintOpacity, 0.0), 1.0)

            switch phaseAnchor {
            case .local:
                if texture.usesFineTilePattern {
                    // 经典高密粉刷微粒：双层细节纸纹 Mipmap 交叉过渡（1x 宏观 128pt + 2x 微观 64pt），纯 Multiply 正片叠底
                    ZStack {
                        Image(uiImage: img)
                            .interpolation(.none)
                            .resizable(resizingMode: .tile)
                            .opacity(mip.coarse)
                            .blendMode(.multiply)

                        if mip.fine > 0.005,
                           let fineImg = ReaderTextureCache.shared.fineDetailTextureImage(
                               for: texture,
                               grainDensity: grainDensity
                           ) {
                            Image(uiImage: fineImg)
                                .interpolation(.none)
                                .resizable(resizingMode: .tile)
                                .opacity(mip.fine)
                                .blendMode(.multiply)
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    let neutralTile = clampedTint < 0.999 ? ReaderTextureCache.shared.seamlessNeutralDenseTileImage(for: texture) : nil
                    let denseTile = ReaderTextureCache.shared.seamlessDenseTileImage(for: texture) ?? img

                    ZStack {
                        ZStack {
                            if let neutralTile, clampedTint < 0.999 {
                                Image(uiImage: neutralTile)
                                    .interpolation(.medium)
                                    .resizable(resizingMode: .tile)
                            }
                            if clampedTint > 0.001 || neutralTile == nil {
                                Image(uiImage: denseTile)
                                    .interpolation(.medium)
                                    .resizable(resizingMode: .tile)
                                    .opacity(neutralTile == nil ? 1.0 : clampedTint)
                            }
                        }
                        .blendMode(.multiply)
                        .opacity(mip.coarse)

                        if mip.fine > 0.005,
                           let fineImg = ReaderTextureCache.shared.fineDetailTextureImage(
                               for: texture,
                               grainDensity: grainDensity
                           ) {
                            Image(uiImage: fineImg)
                                .interpolation(.medium)
                                .resizable(resizingMode: .tile)
                                .opacity(mip.fine)
                                .blendMode(.multiply)
                        }
                    }
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

                            ZStack {
                                Color.clear
                                    .frame(width: viewW, height: viewH)
                                    .overlay(alignment: .topLeading) {
                                        Image(uiImage: img)
                                            .interpolation(.none)
                                            .resizable(resizingMode: .tile)
                                            .frame(width: viewW + tileW * 2.0, height: viewH + tileH * 2.0)
                                            .offset(x: -phaseX, y: -phaseY)
                                    }
                                    .clipped()
                                    .opacity(mip.coarse)
                                    .blendMode(.multiply)

                                if mip.fine > 0.005,
                                   let fineImg = ReaderTextureCache.shared.fineDetailTextureImage(
                                       for: texture,
                                       grainDensity: grainDensity
                                   ) {
                                    let fineTileW = max(fineImg.size.width, 32.0)
                                    let fineTileH = max(fineImg.size.height, 32.0)
                                    let finePhaseX = Self.positiveModulo(contentFrame.minX, divisor: fineTileW)
                                    let finePhaseY = Self.positiveModulo(contentFrame.minY, divisor: fineTileH)

                                    Color.clear
                                        .frame(width: viewW, height: viewH)
                                        .overlay(alignment: .topLeading) {
                                            Image(uiImage: fineImg)
                                                .interpolation(.none)
                                                .resizable(resizingMode: .tile)
                                                .frame(width: viewW + fineTileW * 2.0, height: viewH + fineTileH * 2.0)
                                                .offset(x: -finePhaseX, y: -finePhaseY)
                                        }
                                        .clipped()
                                        .opacity(mip.fine)
                                        .blendMode(.multiply)
                                }
                            }
                        }
                    }
                    .allowsHitTesting(false)
                } else {
                    let tileImg = ReaderTextureCache.shared.seamlessDenseTileImage(for: texture) ?? img
                    let neutralTileImg = clampedTint < 0.999 ? ReaderTextureCache.shared.seamlessNeutralDenseTileImage(for: texture) : nil
                    let tileW: CGFloat = max(tileImg.size.width, 64.0)
                    let tileH: CGFloat = max(tileImg.size.height, 64.0)
                    GeometryReader { proxy in
                        let viewW = proxy.size.width
                        let viewH = proxy.size.height
                        if viewW > 0, viewH > 0 {
                            let contentFrame = proxy.frame(in: .named(spaceName))

                            let phaseX = Self.positiveModulo(contentFrame.minX, divisor: tileW)
                            let phaseY = Self.positiveModulo(contentFrame.minY, divisor: tileH)

                            ZStack {
                                Color.clear
                                    .frame(width: viewW, height: viewH)
                                    .overlay(alignment: .topLeading) {
                                        ZStack {
                                            if let neutralTileImg, clampedTint < 0.999 {
                                                Image(uiImage: neutralTileImg)
                                                    .interpolation(.medium)
                                                    .resizable(resizingMode: .tile)
                                            }
                                            if clampedTint > 0.001 || neutralTileImg == nil {
                                                Image(uiImage: tileImg)
                                                    .interpolation(.medium)
                                                    .resizable(resizingMode: .tile)
                                                    .opacity(neutralTileImg == nil ? 1.0 : clampedTint)
                                            }
                                        }
                                        .frame(width: viewW + tileW * 2.0, height: viewH + tileH * 2.0)
                                        .offset(x: -phaseX, y: -phaseY)
                                    }
                                    .clipped()
                                    .opacity(mip.coarse)
                                    .blendMode(.multiply)

                                if mip.fine > 0.005,
                                   let fineImg = ReaderTextureCache.shared.fineDetailTextureImage(
                                       for: texture,
                                       grainDensity: grainDensity
                                   ) {
                                    let fineTileW = max(fineImg.size.width, 32.0)
                                    let fineTileH = max(fineImg.size.height, 32.0)
                                    let finePhaseX = Self.positiveModulo(contentFrame.minX, divisor: fineTileW)
                                    let finePhaseY = Self.positiveModulo(contentFrame.minY, divisor: fineTileH)

                                    Color.clear
                                        .frame(width: viewW, height: viewH)
                                        .overlay(alignment: .topLeading) {
                                            Image(uiImage: fineImg)
                                                .interpolation(.medium)
                                                .resizable(resizingMode: .tile)
                                                .frame(width: viewW + fineTileW * 2.0, height: viewH + fineTileH * 2.0)
                                                .offset(x: -finePhaseX, y: -finePhaseY)
                                        }
                                        .clipped()
                                        .opacity(mip.fine)
                                        .blendMode(.multiply)
                                }
                            }
                        }
                    }
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
