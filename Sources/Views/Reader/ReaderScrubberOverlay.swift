import SwiftUI
import UIKit

/// 阅读器自定义进度滑动轨道（支持日漫 RTL 镜像、原点锚点标记、按住零跳变抓手与跨页无间断拖动）
struct ReaderScrubberTrackBar: View {
    let totalPages: Int
    let currentPageIndex: Int
    let isScrubbing: Bool
    let scrubFraction: Double
    let isRightToLeft: Bool
    let originAnchorIndex: Int?
    let onScrubBegin: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnd: (Int) -> Void

    @State private var captureAnchorFraction: Double? = nil
    @State private var isRelativeCapture: Bool = false
    @State private var lastHapticPageIndex: Int? = nil
    private let feedbackGenerator = UISelectionFeedbackGenerator()

    private var maxIndex: Int {
        max(totalPages - 1, 1)
    }

    private var activeFraction: Double {
        let raw = isScrubbing ? scrubFraction : Double(currentPageIndex)
        return min(max(raw, 0), Double(maxIndex))
    }

    private var displayedPageIndex: Int {
        min(max(Int(activeFraction.rounded()), 0), max(totalPages - 1, 0))
    }

    var body: some View {
        HStack(spacing: 10) {
            if isRightToLeft {
                endpointTotalLabel
                trackCanvas
                activePageLabel
            } else {
                activePageLabel
                trackCanvas
                endpointTotalLabel
            }
        }
        .frame(height: 36)
    }

    private var activePageLabel: some View {
        HStack(spacing: 3) {
            if isRightToLeft {
                Image(systemName: "arrow.left")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text("\(displayedPageIndex + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(minWidth: 32, alignment: isRightToLeft ? .leading : .trailing)
    }

    private var endpointTotalLabel: some View {
        Text("\(totalPages)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.75))
            .frame(minWidth: 28, alignment: isRightToLeft ? .trailing : .leading)
    }

    private var trackCanvas: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = geo.size.height
            let thumbDiameter: CGFloat = isScrubbing ? 26 : 20
            let thumbRadius = thumbDiameter * 0.5
            let usableWidth = max(width - thumbDiameter, 1)

            let logicalRatio = CGFloat(activeFraction / Double(maxIndex))
            let visualRatio = isRightToLeft ? (1.0 - logicalRatio) : logicalRatio
            let thumbCenterX = thumbRadius + visualRatio * usableWidth
            let trackHeight: CGFloat = isScrubbing ? 8.5 : 6.5

            ZStack(alignment: .leading) {
                // 全透明扩大触控热区，保证指腹轻靠上下缘也可跟手响应
                Color.clear
                    .contentShape(Rectangle())

                // 底层半透明胶囊轨道
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: width, height: trackHeight)
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
                    )
                    .position(x: width * 0.5, y: height * 0.5)

                // 已读 / 进度彩色填充条（RTL 时从右端向左延伸）
                let fillWidth: CGFloat = isRightToLeft
                    ? max(thumbDiameter * 0.5, width - thumbCenterX)
                    : max(thumbDiameter * 0.5, thumbCenterX)
                let fillCenterX: CGFloat = isRightToLeft
                    ? width - fillWidth * 0.5
                    : fillWidth * 0.5

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: min(width, fillWidth), height: trackHeight)
                    .position(x: fillCenterX, y: height * 0.5)

                // 起跳原点锚点小圆点（方便翻看伏笔时直观参照原位置）
                if let anchor = originAnchorIndex, anchor >= 0, anchor < totalPages {
                    let anchorLogical = CGFloat(Double(anchor) / Double(maxIndex))
                    let anchorVisual = isRightToLeft ? (1.0 - anchorLogical) : anchorLogical
                    let anchorCenterX = thumbRadius + anchorVisual * usableWidth

                    Circle()
                        .fill(Color.white.opacity(0.92))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .position(x: anchorCenterX, y: height * 0.5)
                }

                // 白色圆钮滑块
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.38), radius: isScrubbing ? 5 : 3, y: 1.5)
                    .position(x: thumbCenterX, y: height * 0.5)
                    .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isScrubbing)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let currentRatio = CGFloat(Double(currentPageIndex) / Double(maxIndex))
                        let currentVisual = isRightToLeft ? (1.0 - currentRatio) : currentRatio
                        let restThumbCenterX = thumbRadius + currentVisual * usableWidth

                        let computedFraction: Double
                        if captureAnchorFraction == nil {
                            feedbackGenerator.prepare()
                            lastHapticPageIndex = currentPageIndex

                            // 若手指贴近当前滑块（26pt 内），采用零跳变相对抓手；点在远处轨道则直接定位过去
                            if abs(value.startLocation.x - restThumbCenterX) <= 26 {
                                isRelativeCapture = true
                                computedFraction = Double(currentPageIndex)
                            } else {
                                isRelativeCapture = false
                                computedFraction = fractionForTouchX(
                                    value.location.x,
                                    thumbRadius: thumbRadius,
                                    usableWidth: usableWidth
                                )
                            }
                            captureAnchorFraction = computedFraction
                            onScrubBegin(computedFraction)
                        } else if isRelativeCapture {
                            let deltaRatio = value.translation.width / usableWidth
                            let signedRatio = isRightToLeft ? -deltaRatio : deltaRatio
                            let base = captureAnchorFraction ?? Double(currentPageIndex)
                            let next = base + Double(signedRatio) * Double(maxIndex)
                            computedFraction = min(max(next, 0), Double(maxIndex))
                        } else {
                            computedFraction = fractionForTouchX(
                                value.location.x,
                                thumbRadius: thumbRadius,
                                usableWidth: usableWidth
                            )
                        }

                        let targetIdx = Int(computedFraction.rounded())
                        if let prevHaptic = lastHapticPageIndex, prevHaptic != targetIdx {
                            feedbackGenerator.selectionChanged()
                            lastHapticPageIndex = targetIdx
                        }

                        onScrubChanged(computedFraction)
                    }
                    .onEnded { value in
                        let finalFraction: Double
                        if isRelativeCapture {
                            let deltaRatio = value.translation.width / usableWidth
                            let signedRatio = isRightToLeft ? -deltaRatio : deltaRatio
                            let base = captureAnchorFraction ?? Double(currentPageIndex)
                            finalFraction = min(max(base + Double(signedRatio) * Double(maxIndex), 0), Double(maxIndex))
                        } else if captureAnchorFraction != nil {
                            finalFraction = fractionForTouchX(
                                value.location.x,
                                thumbRadius: thumbRadius,
                                usableWidth: usableWidth
                            )
                        } else {
                            finalFraction = Double(currentPageIndex)
                        }

                        let finalIndex = min(max(Int(finalFraction.rounded()), 0), max(totalPages - 1, 0))
                        captureAnchorFraction = nil
                        isRelativeCapture = false
                        lastHapticPageIndex = nil
                        onScrubEnd(finalIndex)
                    }
            )
        }
    }

    private func fractionForTouchX(_ touchX: CGFloat, thumbRadius: CGFloat, usableWidth: CGFloat) -> Double {
        let clampedX = min(max(touchX - thumbRadius, 0), usableWidth)
        let visualRatio = clampedX / usableWidth
        let logicalRatio = isRightToLeft ? (1.0 - visualRatio) : visualRatio
        return min(max(Double(logicalRatio) * Double(maxIndex), 0), Double(maxIndex))
    }
}

// MARK: - 全屏微弧扇面预览蒙层

/// 拖动进度条时展开的全屏预览浮层（半透暗幕 + 居中高清预映/页码胶囊 + 微弧扇面缩略图卡片流）
struct ReaderScrubberPreviewOverlay: View {
    let pages: [MangaPage]
    let scrubFraction: Double
    let originIndex: Int
    let returnAnchorIndex: Int?
    let isRightToLeft: Bool
    let upscalerConfig: ImageUpscalerConfig
    let enableUpscaler: Bool
    let bottomReservedHeight: CGFloat
    @ObservedObject var thumbnailStore: ReaderThumbnailStore

    private var targetIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(max(Int(scrubFraction.rounded()), 0), pages.count - 1)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let cardWidth: CGFloat = isLandscape
                ? min(max(geo.size.height * 0.22, 68), 88)
                : min(max(geo.size.width * 0.275, 90), 118)
            let cardHeight = cardWidth * 1.40
            let stripHeight = cardHeight + 48

            ZStack {
                // 全屏半透明压暗衬底，主画面保持原地冻结不扰动视线
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.46),
                        Color.black.opacity(0.62),
                        Color.black.opacity(0.84)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 18)

                    centerPreviewHUD(availableSize: geo.size, isLandscape: isLandscape)

                    Spacer(minLength: isLandscape ? 10 : 20)

                    arcThumbnailStrip(
                        containerWidth: geo.size.width,
                        cardWidth: cardWidth,
                        cardHeight: cardHeight
                    )
                    .frame(height: stripHeight)
                    .padding(.bottom, bottomReservedHeight)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func centerPreviewHUD(availableSize: CGSize, isLandscape: Bool) -> some View {
        let _ = thumbnailStore.version
        if pages.indices.contains(targetIndex) {
            let page = pages[targetIndex]
            let thumb = thumbnailStore.cachedThumbnail(for: page.imageURL)
            let isAtOrigin = (targetIndex == originIndex)
            let isUpscaled = enableUpscaler && PageUpscalerPipeline.shared.cachedImage(pageKey: page.id, config: upscalerConfig) != nil
            let isLocallyCached = thumb != nil || OnlineImageLoader.shared.hasCachedImage(for: page.imageURL)
            let isHoverLoading = thumbnailStore.isInFlight(for: page.imageURL)

            VStack(spacing: isLandscape ? 8 : 14) {
                // 居中放大的高清小画框（仅当存在缩略图或正在悬停下载时优雅浮现，避免快速划过时闪空白框）
                if let thumb {
                    let maxPreviewHeight: CGFloat = isLandscape
                        ? max(96, availableSize.height * 0.30)
                        : min(230, availableSize.height * 0.27)
                    let aspect = thumb.size.height > 0 ? (thumb.size.width / thumb.size.height) : 0.71
                    let previewHeight = maxPreviewHeight
                    let previewWidth = min(availableSize.width * 0.56, previewHeight * aspect)

                    Image(uiImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: max(90, previewWidth), height: previewHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.32), lineWidth: 1.2)
                        )
                        .shadow(color: .black.opacity(0.55), radius: 16, y: 8)
                }

                // 居中页码与状态悬浮胶囊
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        Text("第 \(targetIndex + 1) 页")
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                        Text("/ \(pages.count)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    HStack(spacing: 6) {
                        if isAtOrigin {
                            Circle()
                                .fill(Color.white.opacity(0.75))
                                .frame(width: 6, height: 6)
                            Text("当前阅读位置 · 松手不跳转")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.85))
                        } else if isUpscaled {
                            Image(systemName: "sparkles")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            Text("已超分 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                        } else if isLocallyCached {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                            Text("已缓存 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                        } else if isHoverLoading {
                            ProgressView()
                                .scaleEffect(0.65)
                                .tint(.white)
                            Text("正在载入预览 · 松手直达")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.88))
                        } else {
                            Circle()
                                .fill(Color.white.opacity(0.42))
                                .frame(width: 6, height: 6)
                            Text("在线页面 · 停顿加载预览或松手跳转")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.78))
                        }
                    }

                    if let anchor = returnAnchorIndex, anchor != targetIndex, anchor != originIndex {
                        Text("返回原点：第 \(anchor + 1) 页")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.68))
                            .padding(.top, 1)
                    } else if !isAtOrigin {
                        Text("起跳前：第 \(originIndex + 1) 页")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.white.opacity(0.68))
                            .padding(.top, 1)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 12, y: 6)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func arcThumbnailStrip(
        containerWidth: CGFloat,
        cardWidth: CGFloat,
        cardHeight: CGFloat
    ) -> some View {
        let _ = thumbnailStore.version
        let lower = max(0, targetIndex - 4)
        let upper = min(pages.count - 1, targetIndex + 4)

        ZStack {
            if lower <= upper {
                ForEach(lower...upper, id: \.self) { idx in
                    let page = pages[idx]
                    let delta = CGFloat(idx) - CGFloat(scrubFraction)
                    // 日漫（RTL）模式下：较大页码出现在左侧，较小页码退往右侧
                    let visualDelta = isRightToLeft ? -delta : delta
                    let absDelta = abs(visualDelta)

                    let xOffset = visualDelta * (cardWidth * 0.86)
                    let yOffset = pow(absDelta, 1.65) * 14.0
                    let angle = Angle.degrees(Double(visualDelta) * 5.2)
                    let scale = max(0.84, 1.07 - absDelta * 0.115)
                    let cardOpacity = max(0.0, 1.0 - max(0, absDelta - 2.65) * 0.65)
                    let isSelected = (idx == targetIndex)

                    let thumb = thumbnailStore.cachedThumbnail(for: page.imageURL)
                    let isDiskOrMemCached = thumb != nil || OnlineImageLoader.shared.hasCachedImage(for: page.imageURL)
                    let isFetching = thumbnailStore.isInFlight(for: page.imageURL)

                    arcCardView(
                        pageIndex: idx,
                        thumbnail: thumb,
                        isDiskOrMemCached: isDiskOrMemCached,
                        isFetching: isFetching,
                        isSelected: isSelected,
                        isOrigin: idx == originIndex,
                        width: cardWidth,
                        height: cardHeight
                    )
                    .scaleEffect(scale)
                    .rotationEffect(angle, anchor: .bottom)
                    .offset(x: xOffset, y: yOffset)
                    .opacity(cardOpacity)
                    .zIndex(100.0 - Double(absDelta) * 10.0)
                }
            }
        }
        .frame(width: containerWidth, height: cardHeight + 36)
        .clipped()
    }

    @ViewBuilder
    private func arcCardView(
        pageIndex: Int,
        thumbnail: UIImage?,
        isDiskOrMemCached: Bool,
        isFetching: Bool,
        isSelected: Bool,
        isOrigin: Bool,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.14))

            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                // 未加载时的简洁纸卡面，避免快速划过时出现大面积空黑块
                VStack(spacing: 6) {
                    Text("\(pageIndex + 1)")
                        .font(.system(size: max(18, width * 0.24), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(isSelected ? 0.55 : 0.30))

                    if isFetching {
                        ProgressView()
                            .scaleEffect(0.70)
                            .tint(.white.opacity(0.85))
                    } else if isDiskOrMemCached {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(width: width, height: height)
                .background(
                    LinearGradient(
                        colors: [Color(white: 0.20), Color(white: 0.13)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            // 底部渐变护底 + 居中页码数字（对齐截图底部的 45 / 46 / 47 页标视觉）
            VStack {
                HStack {
                    if isOrigin {
                        Circle()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: 6, height: 6)
                            .padding(6)
                    }
                    Spacer()
                }
                Spacer()
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.clear, Color.black.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 30)

                    Text("\(pageIndex + 1)")
                        .font(.caption.weight(.heavy).monospacedDigit())
                        .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.90))
                        .shadow(color: .black.opacity(0.95), radius: 2, y: 1)
                        .padding(.bottom, 5)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.white.opacity(0.92) : Color.white.opacity(0.18),
                    lineWidth: isSelected ? 2.0 : 0.8
                )
        )
        .shadow(
            color: .black.opacity(isSelected ? 0.55 : 0.32),
            radius: isSelected ? 12 : 6,
            y: isSelected ? 6 : 3
        )
    }
}

// MARK: - 跳走后的返回原点锚点胶囊

/// 通过进度条跨页跳转后显示的快捷回跳胶囊，支持一键回到跳走前阅读页或手动收起
struct ReaderReturnAnchorPill: View {
    let anchorPageIndex: Int
    let onReturn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onReturn) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                    Text("回到第 \(anchorPageIndex + 1) 页")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.8, height: 14)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.24), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}
