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
    private let queue = DispatchQueue(label: "com.selfsigned.kedaonlinereader.texture_cache", qos: .userInitiated)

    private init() {
        cache.countLimit = 12
    }

    /// 获取指定纸张纹理图像（带内存二级缓存）
    public func textureImage(for type: ReaderTextureType) -> UIImage? {
        if type == .proceduralStucco {
            return ProceduralStuccoTextureManager.shared.getSharedTile()
        }

        let key = type.rawValue as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let loaded = loadTextureFromBundle(named: type.rawValue)
        if let img = loaded {
            cache.setObject(img, forKey: key)
        }
        return loaded
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
    /// Layer 2: 真实纸质纹理图层 (使用 multiplyBlendMode 正片叠底)
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
                baseColorView.backgroundColor = currentTexture.basePaperColor
            }
        }
    }

    public var textureOpacity: CGFloat = 0.4 {
        didSet { textureOverlayView.alpha = textureOpacity }
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

        // 3. 纹理叠加层 (使用 multiplyBlendMode 正片叠底)
        textureOverlayView.frame = bounds
        textureOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textureOverlayView.contentMode = .scaleAspectFill
        textureOverlayView.alpha = textureOpacity
        textureOverlayView.layer.compositingFilter = "multiplyBlendMode"
        textureOverlayView.isHidden = true
        addSubview(textureOverlayView)

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
            textureOverlayView.isHidden = true
            baseColorView.backgroundColor = .systemBackground

        case .light:
            immersiveBackgroundView.isHidden = true
            textureOverlayView.isHidden = true
            baseColorView.backgroundColor = .white

        case .dark:
            immersiveBackgroundView.isHidden = true
            textureOverlayView.isHidden = true
            baseColorView.backgroundColor = .black

        case .immersive:
            immersiveBackgroundView.isHidden = false
            textureOverlayView.isHidden = true
            baseColorView.backgroundColor = .black

        case .texture:
            immersiveBackgroundView.isHidden = true
            textureOverlayView.isHidden = false
            baseColorView.backgroundColor = currentTexture.basePaperColor
            updateTextureImage()
        }
    }

    private func updateTextureImage() {
        textureOverlayView.image = ReaderTextureCache.shared.textureImage(for: currentTexture)
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

/// 拟真纸张纹理正片叠底覆盖层 (SwiftUI)
/// 增强版：内置全局屏幕空间绝对坐标锁定 (Screen-Space Phase Lock)，翻页、滚动、缩放时微粒纹理绝对锚定，彻底解决多页面拼接错位与接缝断层
public struct PaperTextureOverlayView: View {
    public let texture: ReaderTextureType
    public let opacity: Double

    public init(texture: ReaderTextureType, opacity: Double = 0.4) {
        self.texture = texture
        self.opacity = opacity
    }

    public var body: some View {
        if let uiImg = ReaderTextureCache.shared.textureImage(for: texture) {
            GeometryReader { proxy in
                let tileSize = (texture == .proceduralStucco)
                    ? ProceduralStuccoTextureManager.tileSize
                    : max(uiImg.size.width, 256.0)
                let globalFrame = proxy.frame(in: .global)

                // 正模全局绝对相位计算 (Screen-Space Positive Modulo)
                // globalFrame.minX 与 minY 代表当前视图左上角在全局物理窗口中的绝对坐标
                // 严格将屏幕左上角 (0, 0) 映射为纹理网格原点
                let rawX = globalFrame.minX.truncatingRemainder(dividingBy: tileSize)
                let phaseX = rawX >= 0 ? rawX : rawX + tileSize

                let rawY = globalFrame.minY.truncatingRemainder(dividingBy: tileSize)
                let phaseY = rawY >= 0 ? rawY : rawY + tileSize

                // 本地视图左上角的偏移量：使本地 (0, 0) 恰好对齐 globalFrame 在网格中的相对位置
                let offsetX = -phaseX
                let offsetY = -phaseY

                // 感知透明度：程序化微粒采用 Gamma 0.66 校准，其它材质保留标准线性
                let effectiveOpacity = (texture == .proceduralStucco)
                    ? ProceduralStuccoTextureManager.perceptualAlpha(for: opacity)
                    : opacity

                // 核心关键架构：
                // 1. ZStack(alignment: .topLeading) 锁定左上基准，彻底消除居中对齐导致的中心点随尺寸漂移；
                // 2. 平铺图层尺寸覆盖 view 尺寸 + 1 个 tileSize，确保视口无死角覆盖；
                // 3. 最外层严格限制在 proxy.size 并 clipped()，彻底杜绝外溢，消除跨页面正片叠底双重叠加暗斑！
                ZStack(alignment: .topLeading) {
                    Image(uiImage: uiImg)
                        .resizable(resizingMode: .tile)
                        .frame(
                            width: proxy.size.width + tileSize,
                            height: proxy.size.height + tileSize
                        )
                        .offset(x: offsetX, y: offsetY)
                        .blendMode(.multiply)
                        .opacity(effectiveOpacity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .allowsHitTesting(false)
            }
        }
    }
}

/// MangaPrism 独家粉刷颗粒独立覆盖层 (SwiftUI)
public struct ProceduralStuccoOverlayView: View {
    public let opacity: Double

    public init(opacity: Double = 0.4) {
        self.opacity = opacity
    }

    public var body: some View {
        PaperTextureOverlayView(texture: .proceduralStucco, opacity: opacity)
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
