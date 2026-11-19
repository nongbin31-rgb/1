import SwiftUI
import UIKit

/// 基于 UIScrollView 桥接的高性能漫画缩放视图（支持 1x~5x 双指缩放、双击放大、单击切换工具栏）
public struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onSingleTap: () -> Void

    public func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
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

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.contentLayoutGuide.centerYAnchor),
        ])

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    public func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
        }
    }

    public final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        public func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleSingleTap() {
            onSingleTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let zoomScale: CGFloat = 2.6
                let w = scrollView.bounds.width / zoomScale
                let h = scrollView.bounds.height / zoomScale
                let rect = CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h)
                scrollView.zoom(to: rect, animated: true)
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
            let width = geo.size.width
            let height = geo.size.height
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
                        splitRatio = max(0.05, min(0.95, value.location.x / max(width, 1)))
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
