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

    /// 获取指定纸张纹理图像（带内存二级缓存）
    public func textureImage(for type: ReaderTextureType) -> UIImage? {
        let key = type.rawValue as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        // 优先全名 (例如 Texture_0_classic_paper) 加载，次选短名 (例如 Texture_0) 加载
        let loaded = loadTextureFromBundle(named: type.rawValue)
            ?? loadTextureFromBundle(named: shortKey(for: type))
        if let img = loaded {
            cache.setObject(img, forKey: key)
        }
        return loaded
    }

    /// 获取去色白场校准后的中性纸张肌理图（彻底消除材质自带黄/棕色偏色，仅保留纯白纸纤维颗粒）
    public func neutralGrainImage(for type: ReaderTextureType) -> UIImage? {
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

        let quadFormat = UIGraphicsImageRendererFormat()
        quadFormat.scale = 1.0
        quadFormat.opaque = true

        let drawW = quadW / visibleRatio
        let drawH = quadH / visibleRatio
        let offsetX = -(drawW - quadW) * 0.5
        let offsetY = -(drawH - quadH) * 0.5

        let croppedQuad = UIGraphicsImageRenderer(size: CGSize(width: quadW, height: quadH), format: quadFormat).image { _ in
            image.draw(in: CGRect(x: offsetX, y: offsetY, width: drawW, height: drawH))
        }

        let fullSize = CGSize(width: quadW * 2.0, height: quadH * 2.0)
        return UIGraphicsImageRenderer(size: fullSize, format: quadFormat).image { ctx in
            let cg = ctx.cgContext

            croppedQuad.draw(in: CGRect(x: 0, y: 0, width: quadW, height: quadH))

            cg.saveGState()
            cg.translateBy(x: fullSize.width, y: 0)
            cg.scaleBy(x: -1.0, y: 1.0)
            croppedQuad.draw(in: CGRect(x: 0, y: 0, width: quadW, height: quadH))
            cg.restoreGState()

            cg.saveGState()
            cg.translateBy(x: 0, y: fullSize.height)
            cg.scaleBy(x: 1.0, y: -1.0)
            croppedQuad.draw(in: CGRect(x: 0, y: 0, width: quadW, height: quadH))
            cg.restoreGState()

            cg.saveGState()
            cg.translateBy(x: fullSize.width, y: fullSize.height)
            cg.scaleBy(x: -1.0, y: -1.0)
            croppedQuad.draw(in: CGRect(x: 0, y: 0, width: quadW, height: quadH))
            cg.restoreGState()
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
        didSet { textureCompositeView.alpha = textureOpacity }
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
        textureCompositeView.alpha = textureOpacity

        if let img = ReaderTextureCache.shared.textureImage(for: currentTexture) {
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
        } else {
            neutralTextureOverlayView.image = nil
            textureOverlayView.image = nil
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
            let effectiveOpacity = opacity
            let clampedTint = min(max(tintOpacity, 0.0), 1.0)

            switch phaseAnchor {
            case .local:
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

            case .namedSpace(let spaceName):
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
