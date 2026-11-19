import SwiftUI
import UIKit

/// 基于 UIScrollView 桥接的高性能漫画缩放视图（支持 1x~5x 双指缩放、双击放大、单击切换工具栏，支持物理纸张纹理正片叠底）
public struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var texture: ReaderTextureType? = nil
    var textureOpacity: Double = 0.4
    var applyTextureToImage: Bool = false
    let onSingleTap: () -> Void
    var onZoomChanged: ((CGFloat) -> Void)? = nil

    public init(
        image: UIImage,
        texture: ReaderTextureType? = nil,
        textureOpacity: Double = 0.4,
        applyTextureToImage: Bool = false,
        onSingleTap: @escaping () -> Void,
        onZoomChanged: ((CGFloat) -> Void)? = nil
    ) {
        self.image = image
        self.texture = texture
        self.textureOpacity = textureOpacity
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

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        // 真实纸张材质纹理覆盖层 (置于 imageView 内部，精准作用于漫画图片本身，随缩放平移天然跟随)
        let textureOverlayView = UIImageView()
        textureOverlayView.contentMode = .scaleAspectFill
        textureOverlayView.clipsToBounds = true
        textureOverlayView.isUserInteractionEnabled = false
        textureOverlayView.layer.compositingFilter = "multiplyBlendMode"
        imageView.addSubview(textureOverlayView)

        context.coordinator.imageView = imageView
        context.coordinator.textureOverlayView = textureOverlayView
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
            }
            if uiView.zoomScale == 1.0 && imageView.frame.size != uiView.bounds.size && uiView.bounds.size != .zero {
                imageView.frame = uiView.bounds
                uiView.contentSize = uiView.bounds.size
            }
        }
        context.coordinator.updateTexture(
            texture: texture,
            opacity: textureOpacity,
            applyToImage: applyTextureToImage
        )
    }

    public final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        weak var textureOverlayView: UIImageView?
        var onSingleTap: () -> Void
        var onZoomChanged: ((CGFloat) -> Void)?

        init(onSingleTap: @escaping () -> Void, onZoomChanged: ((CGFloat) -> Void)?) {
            self.onSingleTap = onSingleTap
            self.onZoomChanged = onZoomChanged
        }

        public func updateTexture(
            texture: ReaderTextureType?,
            opacity: Double,
            applyToImage: Bool
        ) {
            guard let imageView, let image = imageView.image, let textureOverlayView else { return }
            let targetRect = Self.calculateImageAspectFitRect(imageSize: image.size, bounds: imageView.bounds)
            textureOverlayView.frame = targetRect

            if applyToImage, let texture, let texImg = ReaderTextureCache.shared.textureImage(for: texture) {
                textureOverlayView.isHidden = false
                textureOverlayView.image = texImg
                textureOverlayView.alpha = CGFloat(opacity)
            } else {
                textureOverlayView.isHidden = true
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

/// 原图 vs 超分 实时分屏拖动对比视图
public struct SplitCompareView: View {
    let originalImage: UIImage
    let enhancedImage: UIImage
    let engineLabel: String

    @State private var splitRatio: CGFloat = 0.5
    @State private var zoomScale: CGFloat = 1.0
    @State private var lastZoomScale: CGFloat = 1.0

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

                // 左右角标
                VStack {
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
            .gesture(
                DragGesture(minimumDistance: 0)
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
