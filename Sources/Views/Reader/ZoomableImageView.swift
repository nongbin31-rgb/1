import SwiftUI
import UIKit

// MARK: - 拟真纸张与多层正片叠底漫画展示视图容器
final class ComicContainerImageView: UIImageView {
    /// Layer 1: 真实物理纸张基准底色正片叠底覆盖层 (使漫画纯白线稿与四周留白纸浆底色100%无缝吻合)
    let paperTintOverlayView = UIImageView()
    /// Layer 1.5: 零泛白柔光纸纤维覆盖层 (激活彩漫与中暗调立体质感且绝不泛白)
    let softLightOverlayView = UIImageView()
    /// Layer 2 裁剪容器：严格限定在漫画画面区域内，不溢出到四周留白
    let textureClipContainer = UIView()
    /// Layer 2a: 去色白场校准后的纯白纸张肌理层 (alpha 始终为 1.0，作为 0% 着色基准)
    let neutralTextureOverlayView = UIImageView()
    /// Layer 2b: 真实纸张材质原彩纹理覆盖层 (随 tintOpacity 变化混合，100% 时完全呈现原材质色调)
    let textureOverlayView = UIImageView()

    override init(image: UIImage?) {
        super.init(image: image)
        setupOverlays()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupOverlays()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupOverlays()
    }

    private func setupOverlays() {
        contentMode = .scaleAspectFit
        backgroundColor = .clear

        paperTintOverlayView.clipsToBounds = true
        paperTintOverlayView.isUserInteractionEnabled = false
        paperTintOverlayView.layer.compositingFilter = "multiplyBlendMode"
        paperTintOverlayView.isHidden = true
        addSubview(paperTintOverlayView)

        softLightOverlayView.clipsToBounds = true
        softLightOverlayView.isUserInteractionEnabled = false
        softLightOverlayView.layer.compositingFilter = "softLightBlendMode"
        softLightOverlayView.isHidden = true
        addSubview(softLightOverlayView)

        textureClipContainer.clipsToBounds = true
        textureClipContainer.isUserInteractionEnabled = false
        textureClipContainer.backgroundColor = .clear
        textureClipContainer.layer.compositingFilter = "multiplyBlendMode"
        textureClipContainer.isHidden = true
        addSubview(textureClipContainer)

        neutralTextureOverlayView.contentMode = .scaleAspectFill
        neutralTextureOverlayView.clipsToBounds = true
        neutralTextureOverlayView.isUserInteractionEnabled = false
        neutralTextureOverlayView.isHidden = true
        textureClipContainer.addSubview(neutralTextureOverlayView)

        textureOverlayView.contentMode = .scaleAspectFill
        textureOverlayView.clipsToBounds = true
        textureOverlayView.isUserInteractionEnabled = false
        textureClipContainer.addSubview(textureOverlayView)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateOverlayFrames()
    }

    func updateOverlayFrames() {
        guard let img = image, bounds.width > 0, bounds.height > 0 else { return }
        let targetRect = ZoomableImageView.Coordinator.calculateImageAspectFitRect(
            imageSize: img.size,
            bounds: bounds
        )
        paperTintOverlayView.frame = targetRect
        softLightOverlayView.frame = targetRect
        textureClipContainer.frame = targetRect
        // 反向定位使平铺原点对齐整页 (0, 0)，与页面四周留白纸张纹理相位 100% 无缝衔接
        let alignedFrame = CGRect(
            x: -targetRect.minX,
            y: -targetRect.minY,
            width: bounds.width,
            height: bounds.height
        )
        neutralTextureOverlayView.frame = alignedFrame
        textureOverlayView.frame = alignedFrame
    }
}

/// 基于 UIScrollView 桥接的高性能漫画缩放视图（支持 1x~5x 双指缩放、双击放大、单击切换工具栏，支持物理纸张原生底色与微粒纹理双重正片叠底）
public struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var texture: ReaderTextureType? = nil
    var textureOpacity: Double = 0.4
    var textureTintOpacity: Double = 1.0
    var applyTextureToImage: Bool = false
    let onSingleTap: () -> Void
    var onZoomChanged: ((CGFloat) -> Void)? = nil

    public init(
        image: UIImage,
        texture: ReaderTextureType? = nil,
        textureOpacity: Double = 0.4,
        textureTintOpacity: Double = 1.0,
        applyTextureToImage: Bool = false,
        onSingleTap: @escaping () -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        self.texture = texture
        self.textureOpacity = textureOpacity
        self.textureTintOpacity = textureTintOpacity
        self.applyTextureToImage = applyTextureToImage
        self.onSingleTap = onSingleTap
        self.onZoomChanged = onZoomChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onZoomChanged: onZoomChanged)
    }

    public func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = ComicContainerImageView(image: image)
        imageView.backgroundColor = .clear
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        context.coordinator.updateTexture(
            texture: texture,
            opacity: textureOpacity,
            tintOpacity: textureTintOpacity,
            applyToImage: applyTextureToImage
        )

        return scrollView
    }

    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onZoomChanged = onZoomChanged
        if let imageView = context.coordinator.imageView {
            if imageView.image !== image {
                imageView.image = image
                imageView.updateOverlayFrames()
            }
            if uiView.zoomScale == 1.0 && imageView.frame.size != uiView.bounds.size && uiView.bounds.size != .zero {
                imageView.frame = uiView.bounds
                uiView.contentSize = uiView.bounds.size
                imageView.updateOverlayFrames()
            }
        }
        context.coordinator.updateTexture(
            texture: texture,
            opacity: textureOpacity,
            tintOpacity: textureTintOpacity,
            applyToImage: applyTextureToImage
        )
    }

    public final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: ComicContainerImageView?
        var onSingleTap: () -> Void
        var onZoomChanged: ((CGFloat) -> Void)?

        init(onSingleTap: @escaping () -> Void, onZoomChanged: ((CGFloat) -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onZoomChanged = onZoomChanged
        }

        public func updateTexture(
            texture: ReaderTextureType?,
            opacity: Double,
            tintOpacity: Double,
            applyToImage: Bool
        ) {
            guard let imageView else { return }
            imageView.updateOverlayFrames()

            if applyToImage, let texture {
                // 1. 物理纸张基准原生底色正片叠底 (支持 0%~100% 着色浓度调节，0% 时保留原图纯白不发黄)
                let clampedTint = min(max(tintOpacity, 0.0), 1.0)
                if clampedTint > 0.001 {
                    imageView.paperTintOverlayView.isHidden = false
                    imageView.paperTintOverlayView.image = UIImage.solidColorImage(color: texture.basePaperColor)
                    imageView.paperTintOverlayView.alpha = CGFloat(clampedTint)
                } else {
                    imageView.paperTintOverlayView.isHidden = true
                    imageView.paperTintOverlayView.alpha = 0.0
                }

                // 2. 真实物理纸张材质微粒/纹理覆盖 (统一采用稳定可靠的正片叠底 multiplyBlendMode，彻底杜绝失效泛白)
                imageView.softLightOverlayView.isHidden = true

                if let texImg = ReaderTextureCache.shared.textureImage(for: texture) {
                    imageView.textureClipContainer.isHidden = false
                    let effectiveAlpha = ReaderTextureCache.perceptualOpacity(for: texture, rawOpacity: opacity)
                    imageView.textureClipContainer.alpha = CGFloat(effectiveAlpha)

                    if texture.usesFineTilePattern {
                        // 程序化 256×256pt 高密无缝立体浮雕纸纹：1:1 逻辑像素重复平铺，不拉伸不糊化
                        imageView.neutralTextureOverlayView.isHidden = true
                        imageView.neutralTextureOverlayView.image = nil
                        imageView.neutralTextureOverlayView.backgroundColor = .clear

                        imageView.textureOverlayView.isHidden = false
                        imageView.textureOverlayView.image = nil
                        imageView.textureOverlayView.backgroundColor = ReaderTextureCache.shared.patternColor(for: texture)
                        imageView.textureOverlayView.alpha = 1.0
                    } else {
                        imageView.neutralTextureOverlayView.backgroundColor = .clear
                        imageView.textureOverlayView.backgroundColor = .clear

                        let neutralImg = clampedTint < 0.999 ? ReaderTextureCache.shared.neutralGrainImage(for: texture) : nil
                        if let neutralImg, clampedTint < 0.999 {
                            imageView.neutralTextureOverlayView.isHidden = false
                            imageView.neutralTextureOverlayView.contentMode = .scaleAspectFill
                            imageView.neutralTextureOverlayView.image = neutralImg
                            imageView.neutralTextureOverlayView.alpha = 1.0
                        } else {
                            imageView.neutralTextureOverlayView.isHidden = true
                            imageView.neutralTextureOverlayView.image = nil
                        }

                        if clampedTint > 0.001 || neutralImg == nil {
                            imageView.textureOverlayView.isHidden = false
                            imageView.textureOverlayView.contentMode = .scaleAspectFill
                            imageView.textureOverlayView.image = texImg
                            imageView.textureOverlayView.alpha = (neutralImg == nil) ? 1.0 : CGFloat(clampedTint)
                        } else {
                            imageView.textureOverlayView.isHidden = true
                            imageView.textureOverlayView.alpha = 0.0
                        }
                    }
                } else {
                    imageView.textureClipContainer.isHidden = true
                }
            } else {
                imageView.paperTintOverlayView.isHidden = true
                imageView.softLightOverlayView.isHidden = true
                imageView.textureClipContainer.isHidden = true
                imageView.neutralTextureOverlayView.isHidden = true
            }
        }

        public static func calculateImageAspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
            guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
                return bounds
            }
            let imageRatio = imageSize.width / imageSize.height
            let viewRatio = bounds.width / bounds.height
            if imageRatio > viewRatio {
                let h = bounds.width / imageRatio
                return CGRect(x: 0, y: (bounds.height - h) * 0.5, width: bounds.width, height: h)
            } else {
                let w = bounds.height * imageRatio
                return CGRect(x: (bounds.width - w) * 0.5, y: 0, width: w, height: bounds.height)
            }
        }

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let imageView else { return }
            let offsetX = max((scrollView.bounds.width - imageView.frame.width) * 0.5, 0)
            let offsetY = max((scrollView.bounds.height - imageView.frame.height) * 0.5, 0)
            imageView.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
            onZoomChanged?(scrollView.zoomScale)
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
                onZoomChanged?(1.0)
            } else {
                let point = gesture.location(in: imageView)
                let zoomScale: CGFloat = 2.6
                let w = scrollView.bounds.width / zoomScale
                let h = scrollView.bounds.height / zoomScale
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
                onZoomChanged?(zoomScale)
            }
        }
    }
}

// MARK: - 极轻量纯色位图内存缓存器
private extension UIImage {
    static var solidCache = [UInt32: UIImage]()
    static let solidLock = NSLock()

    static func solidColorImage(color: UIColor) -> UIImage {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = (UInt32(r * 255) << 24) | (UInt32(g * 255) << 16) | (UInt32(b * 255) << 8) | UInt32(a * 255)

        solidLock.lock()
        if let hit = solidCache[key] {
            solidLock.unlock()
            return hit
        }
        solidLock.unlock()

        let size = CGSize(width: 4, height: 4)
        let renderer = UIGraphicsImageRenderer(size: size)
        let generated = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }

        solidLock.lock()
        solidCache[key] = generated
        solidLock.unlock()
        return generated
    }
}

/// 原图 vs 超分 实时分屏拖动对比视图
public struct SplitCompareView: View {
    let originalImage: UIImage
    let enhancedImage: UIImage
    let engineLabel: String
    var onSingleTap: (() -> Void)? = nil
    var onExitCompare: (() -> Void)? = nil

    @State private var splitRatio: CGFloat = 0.5
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0

    public init(
        originalImage: UIImage,
        enhancedImage: UIImage,
        engineLabel: String,
        onSingleTap: (() -> Void)? = nil,
        onExitCompare: (() -> Void)? = nil
    ) {
        self.originalImage = originalImage
        self.enhancedImage = enhancedImage
        self.engineLabel = engineLabel
        self.onSingleTap = onSingleTap
        self.onExitCompare = onExitCompare
    }

    public var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)
            let dividerX = max(24, min(width - 24, width * splitRatio))

            ZStack {
                // 右侧底层：超分后图像
                Image(uiImage: enhancedImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomScale)
                    .frame(width: width, height: height)

                // 左侧裁剪层：原始图像
                Image(uiImage: originalImage)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoomScale)
                    .frame(width: width, height: height)
                    .mask(
                        HStack(spacing: 0) {
                            Rectangle().frame(width: dividerX)
                            Spacer(minLength: 0)
                        }
                    )

                // 分割线与手柄
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .position(x: dividerX, y: height / 2)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Image(systemName: "arrow.left.and.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 36, height: 36)
                    .position(x: dividerX, y: height / 2)

                // 左右角标与常驻退出按钮
                VStack {
                    if let onExitCompare {
                        HStack {
                            Spacer()
                            Button {
                                onExitCompare()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "xmark")
                                        .font(.caption.bold())
                                    Text("退出对比")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                            }
                            .padding(.trailing, 16)
                            .padding(.top, 56)
                        }
                    }

                    Spacer()
                    HStack {
                        Text("原图 1x")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.65), in: Capsule())
                        Spacer()
                        Text("\(engineLabel) 2x")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.85), in: Capsule())
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 96)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onSingleTap?()
            }
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        splitRatio = max(0.05, min(0.95, value.location.x / width))
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        zoomScale = max(1.0, min(4.0, lastZoomScale * value))
                    }
                    .onEnded { _ in
                        lastZoomScale = zoomScale
                    }
            )
        }
    }
}
