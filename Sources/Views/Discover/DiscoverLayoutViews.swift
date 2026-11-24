import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 发现页多样式集合容器（保留默认经典三列网格 + 新增 5 套 Apple HIG 高阶视图）
struct DiscoverLayoutCollectionView: View {
    let style: DiscoverLayoutStyle
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void

    private let classicColumns = [
        GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 14, alignment: .top)
    ]

    var body: some View {
        switch style {
        case .classicGrid:
            classicGridContent
        case .editorialList:
            DiscoverEditorialListView(
                mangas: mangas,
                store: store,
                onItemAppear: onItemAppear
            )
        case .immersiveWall:
            DiscoverImmersiveWallView(
                mangas: mangas,
                store: store,
                onItemAppear: onItemAppear
            )
        case .editorialGallery:
            DiscoverEditorialGalleryView(
                mangas: mangas,
                store: store,
                onItemAppear: onItemAppear
            )
        case .tactileBookshelf:
            DiscoverTactileBookshelfView(
                mangas: mangas,
                store: store,
                onItemAppear: onItemAppear
            )
        case .magazineToday:
            DiscoverMagazineTodayView(
                mangas: mangas,
                store: store,
                onItemAppear: onItemAppear
            )
        }
    }

    private var classicGridContent: some View {
        LazyVGrid(columns: classicColumns, spacing: 18) {
            ForEach(mangas) { manga in
                DiscoverMangaLink(manga: manga) {
                    MangaGridCard(
                        manga: manga,
                        progress: store.progress(for: manga)
                    )
                }
                .onAppear {
                    onItemAppear(manga)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// 统一导航跳转包装器（配合 CompatNavigationContainer，全量兼容 iOS 15 ~ iOS 26）
private struct DiscoverMangaLink<Label: View>: View {
    let manga: Manga
    @ViewBuilder let label: () -> Label

    var body: some View {
        NavigationLink(destination: MangaDetailView(manga: manga)) {
            label()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 1. 详情信息流 (Apple Books Editorial List)

private struct DiscoverEditorialListView: View {
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(mangas.enumerated()), id: \.element.id) { index, manga in
                let progress = store.progress(for: manga)
                let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
                let tags = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 2)
                let isSaved = store.isInBookshelf(manga)

                VStack(spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        DiscoverMangaLink(manga: manga) {
                            HStack(alignment: .top, spacing: 14) {
                                // 左侧 3:4.2 竖向圆角封面
                                AsyncMangaCoverView(
                                    urlString: manga.coverURL,
                                    headers: manga.coverHeaders,
                                    cornerRadius: 8
                                )
                                .frame(width: 74, height: 104)
                                .overlay(alignment: .bottomLeading) {
                                    if let progress {
                                        Text("P\(progress.pageIndex + 1)")
                                            .font(.system(size: 9.5, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(.black.opacity(0.66), in: Capsule())
                                            .padding(4)
                                    }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.11), radius: 5, y: 2.5)

                                // 右侧结构化元数据列
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(meta.cleanTitle)
                                        .font(.system(size: 15.5, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .padding(.trailing, 30)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    // 作者 + 连载状态副信息行（状态固定宽度保护，避免被长作者名挤压隐藏）
                                    HStack(spacing: 5) {
                                        if !manga.author.isEmpty {
                                            Text(manga.displayAuthor)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }

                                        if !manga.author.isEmpty && !manga.statusText.isEmpty {
                                            Text("·")
                                                .font(.caption)
                                                .foregroundStyle(.secondary.opacity(0.55))
                                        }

                                        if !manga.statusText.isEmpty {
                                            DiscoverStatusBadgeLabel(statusText: manga.statusText, compact: true)
                                                .fixedSize(horizontal: true, vertical: false)
                                                .layoutPriority(1)
                                        }
                                    }

                                    Spacer(minLength: 4)

                                    // 底部低噪胶囊标签 + 微缩阅读进度圆环
                                    HStack(spacing: 6) {
                                        HStack(spacing: 5) {
                                            if let group = meta.groupName {
                                                DiscoverMicroCapsule(text: group, isAccent: false)
                                            }
                                            ForEach(Array(tags.enumerated()), id: \.offset) { tagIdx, tag in
                                                let highlight = (tagIdx == tags.count - 1) && (meta.groupName != nil || tags.count > 1)
                                                DiscoverMicroCapsule(text: tag, isAccent: highlight)
                                            }
                                        }
                                        .lineLimit(1)

                                        Spacer(minLength: 6)

                                        ReadingProgressRingView(
                                            hasProgress: progress != nil,
                                            progress: progress?.progressRatio,
                                            isExact: progress?.totalPages != nil
                                        )
                                        .frame(width: 14, height: 14, alignment: .center)
                                    }
                                }
                                .frame(height: 104, alignment: .top)
                            }
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .onAppear {
                            onItemAppear(manga)
                        }

                        // 独立覆盖层书签按钮，避免嵌套在 NavigationLink 内产生手势冲突
                        // 图标置于右对齐的 14pt 居中槽位，与下方进度圆环水平中心严格对齐，同时保留左侧与上下扩展点击热区
                        Button {
                            store.toggleBookshelf(manga)
                            triggerLightHaptic()
                        } label: {
                            Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(isSaved ? Color.accentColor : Color.secondary.opacity(0.65))
                                .frame(width: 14, height: 18, alignment: .center)
                                .padding(.leading, 12)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .accessibilityLabel(isSaved ? "移出书架" : "加入书架")
                    }

                    // 精准对齐右侧文本起点的 0.5pt 原生内缩分隔线
                    if index < mangas.count - 1 {
                        Rectangle()
                            .fill(Color(.separator).opacity(0.55))
                            .frame(height: 0.5)
                            .padding(.leading, 88)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - 2. 沉浸海报墙 (Immersive Cover Wall — 视觉纯粹流)

private struct DiscoverImmersiveWallView: View {
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(mangas) { manga in
                let progress = store.progress(for: manga)
                let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
                let tags = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 1)
                let isSaved = store.isInBookshelf(manga)

                DiscoverMangaLink(manga: manga) {
                    AsyncMangaCoverView(
                        urlString: manga.coverURL,
                        headers: manga.coverHeaders,
                        cornerRadius: 14
                    )
                    .frame(maxWidth: .infinity)
                    .aspectRatio(2.0 / 3.1, contentMode: .fit)
                    // 左上角优先展示连载/完结状态微胶囊，右上角展示进度或主标签/收藏
                    .overlay(alignment: .top) {
                        HStack(spacing: 6) {
                            if !manga.statusText.isEmpty {
                                DiscoverStatusBadgeLabel(
                                    statusText: manga.statusText,
                                    compact: true,
                                    isOnDarkBackground: true
                                )
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.black.opacity(0.48), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                                )
                            } else if let topTag = tags.first {
                                Text(topTag)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.42), in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                                    )
                            }

                            Spacer(minLength: 4)

                            if let progress {
                                Text("P\(progress.pageIndex + 1)")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .environment(\.colorScheme, .dark)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.26), lineWidth: 0.5)
                                    )
                            } else if isSaved {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .environment(\.colorScheme, .dark)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                                    )
                            } else if !manga.statusText.isEmpty, let topTag = tags.first {
                                Text(topTag)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .environment(\.colorScheme, .dark)
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                                    )
                            }
                        }
                        .padding(8)
                    }
                    // 底部三段式平滑暗幕 + 悬浮标题与微缩进度圆环
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meta.cleanTitle)
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .shadow(color: .black.opacity(0.35), radius: 2, y: 1)

                            HStack(spacing: 4) {
                                let subtitle = !manga.author.isEmpty
                                    ? manga.displayAuthor
                                    : (meta.groupName ?? manga.statusText)
                                if !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.78))
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 4)

                                ReadingProgressRingView(
                                    hasProgress: progress != nil,
                                    progress: progress?.progressRatio,
                                    isExact: progress?.totalPages != nil,
                                    size: 12,
                                    isOnDarkBackground: true
                                )
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .padding(.top, 46)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black.opacity(0.46), location: 0.46),
                                    .init(color: .black.opacity(0.88), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }
                .onAppear {
                    onItemAppear(manga)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - 3. 双列呼吸画廊 (2-Column Editorial Gallery — 高级留白流)

private struct DiscoverEditorialGalleryView: View {
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 14, alignment: .top),
        GridItem(.flexible(), spacing: 14, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(mangas) { manga in
                let progress = store.progress(for: manga)
                let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
                let tags = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 1)

                DiscoverMangaLink(manga: manga) {
                    VStack(alignment: .leading, spacing: 9) {
                        // 大画幅 3:4.2 封面 + 同色系环境光动态漫反射投影
                        AsyncMangaCoverView(
                            urlString: manga.coverURL,
                            headers: manga.coverHeaders,
                            cornerRadius: 12
                        )
                        .frame(maxWidth: .infinity)
                        .aspectRatio(3.0 / 4.2, contentMode: .fit)
                        .overlay(alignment: .topLeading) {
                            if let group = meta.groupName {
                                Text(group)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                                    )
                                    .padding(7)
                            }
                        }
                        .overlay(alignment: .bottomLeading) {
                            if let progress {
                                Text("P\(progress.pageIndex + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6.5)
                                    .padding(.vertical, 2.5)
                                    .background(.black.opacity(0.65), in: Capsule())
                                    .padding(7)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .background {
                            // 复用内存图片缓存生成柔和封面同色漫反射光晕
                            AsyncMangaCoverView(
                                urlString: manga.coverURL,
                                headers: manga.coverHeaders,
                                cornerRadius: 12
                            )
                            .scaleEffect(0.92)
                            .offset(y: 7)
                            .blur(radius: 13)
                            .opacity(colorScheme == .dark ? 0.30 : 0.24)
                            .allowsHitTesting(false)
                        }
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                        // 下方清爽排版区
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meta.cleanTitle)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            let subline = gallerySubtitle(manga: manga, meta: meta)
                            if !subline.isEmpty {
                                Text(subline)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            HStack(spacing: 5) {
                                if !manga.statusText.isEmpty {
                                    DiscoverStatusBadgeLabel(statusText: manga.statusText, compact: true)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .layoutPriority(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }

                                if let firstTag = tags.first {
                                    Text(firstTag)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }

                                Spacer(minLength: 4)

                                ReadingProgressRingView(
                                    hasProgress: progress != nil,
                                    progress: progress?.progressRatio,
                                    isExact: progress?.totalPages != nil
                                )
                            }
                            .padding(.top, 2)
                        }
                        .padding(.horizontal, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onAppear {
                    onItemAppear(manga)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func gallerySubtitle(manga: Manga, meta: MangaTitleMetadata) -> String {
        var parts: [String] = []
        if !manga.author.isEmpty {
            parts.append(manga.displayAuthor)
        }
        if let group = meta.groupName, !parts.contains(group) {
            parts.append(group)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 4. 拟物精装书架 (Tactile Bookshelf — Apple Books 实体书感)

private struct DiscoverTactileBookshelfView: View {
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var shelfRows: [(offset: Int, items: [Manga])] {
        var rows: [(Int, [Manga])] = []
        var idx = 0
        while idx < mangas.count {
            let end = min(idx + 3, mangas.count)
            rows.append((idx / 3, Array(mangas[idx..<end])))
            idx += 3
        }
        return rows
    }

    var body: some View {
        LazyVStack(spacing: 22) {
            ForEach(shelfRows, id: \.offset) { row in
                VStack(spacing: 0) {
                    // 书籍行（3 列固定对齐，坐落在层板之上）
                    HStack(alignment: .bottom, spacing: 14) {
                        ForEach(row.items) { manga in
                            let progress = store.progress(for: manga)
                            DiscoverMangaLink(manga: manga) {
                                TactileHardcoverBookView(
                                    manga: manga,
                                    progress: progress,
                                    isDark: colorScheme == .dark
                                )
                            }
                            .frame(maxWidth: .infinity)
                            .onAppear {
                                onItemAppear(manga)
                            }
                        }

                        // 不足 3 本时透明占位，保持严格 3 列等宽
                        if row.items.count < 3 {
                            ForEach(0..<(3 - row.items.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .zIndex(2)

                    // 极简悬浮玻璃/石材层板
                    TactileShelfLedgeView(isDark: colorScheme == .dark)
                        .padding(.top, -2)
                        .zIndex(1)

                    // 层板下方居中极简书名与状态/进度
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(row.items) { manga in
                            let progress = store.progress(for: manga)
                            let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
                            DiscoverMangaLink(manga: manga) {
                                VStack(spacing: 3) {
                                    Text(meta.cleanTitle)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .center)

                                    HStack(spacing: 4) {
                                        if !manga.statusText.isEmpty {
                                            DiscoverStatusBadgeLabel(statusText: manga.statusText, compact: true)
                                                .fixedSize(horizontal: true, vertical: false)
                                        }
                                        ReadingProgressRingView(
                                            hasProgress: progress != nil,
                                            progress: progress?.progressRatio,
                                            isExact: progress?.totalPages != nil,
                                            size: 10
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }

                        if row.items.count < 3 {
                            ForEach(0..<(3 - row.items.count), id: \.self) { _ in
                                Color.clear
                                    .frame(maxWidth: .infinity, maxHeight: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 9)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 18)
    }
}

/// 精装实体书单本视图（含右侧纸页叠层 + 左侧书脊压痕高光 + 底部接地投影）
private struct TactileHardcoverBookView: View {
    let manga: Manga
    let progress: ReadingProgress?
    let isDark: Bool

    var body: some View {
        // 硬壳封面正面（尺寸严格由 3:4.25 决定，纸页边与阴影均通过 background 附着）
        AsyncMangaCoverView(
            urlString: manga.coverURL,
            headers: manga.coverHeaders,
            cornerRadius: 0
        )
        .frame(maxWidth: .infinity)
        .aspectRatio(3.0 / 4.25, contentMode: .fit)
        .overlay {
            // 书脊立体折痕高光渐变
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.32), location: 0.0),
                    .init(color: .white.opacity(0.05), location: 0.035),
                    .init(color: .black.opacity(0.28), location: 0.055),
                    .init(color: .white.opacity(0.24), location: 0.075),
                    .init(color: .clear, location: 0.13),
                    .init(color: .clear, location: 0.93),
                    .init(color: .black.opacity(0.14), location: 1.0)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(height: 0.75)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) {
            if let progress {
                Text("P\(progress.pageIndex + 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(5)
            }
        }
        .clipShape(TactileBookCoverShape(leadingRadius: 2.5, trailingRadius: 5))
        .shadow(color: .black.opacity(isDark ? 0.45 : 0.22), radius: 5, y: 3)
        .background(alignment: .trailing) {
            // 右侧 3.5pt 叠层纸页切面
            TactilePaperPagesEdge(isDark: isDark)
                .frame(width: 4.5)
                .padding(.vertical, 3)
                .offset(x: 3.5)
        }
        .background(alignment: .bottom) {
            // 底部层板接地接触阴影
            Ellipse()
                .fill(Color.black.opacity(isDark ? 0.65 : 0.40))
                .frame(height: 6)
                .padding(.horizontal, 2)
                .blur(radius: 2)
                .offset(y: 3)
        }
        .padding(.trailing, 3.5)
    }
}

/// 右侧叠层纸页切面（全版本兼容，自动适配浅/深色）
private struct TactilePaperPagesEdge: View {
    let isDark: Bool

    var body: some View {
        let stops: [Gradient.Stop] = isDark
            ? [
                .init(color: Color(red: 0.78, green: 0.77, blue: 0.76), location: 0.0),
                .init(color: Color(red: 0.56, green: 0.55, blue: 0.54), location: 0.32),
                .init(color: Color(red: 0.85, green: 0.84, blue: 0.82), location: 0.58),
                .init(color: Color(red: 0.48, green: 0.47, blue: 0.45), location: 1.0)
            ]
            : [
                .init(color: Color(red: 0.96, green: 0.955, blue: 0.94), location: 0.0),
                .init(color: Color(red: 0.88, green: 0.87, blue: 0.85), location: 0.34),
                .init(color: Color.white, location: 0.58),
                .init(color: Color(red: 0.83, green: 0.82, blue: 0.80), location: 1.0)
            ]

        LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
            .clipShape(TactileBookCoverShape(leadingRadius: 0, trailingRadius: 2))
            .shadow(color: .black.opacity(0.18), radius: 1, x: 1, y: 0)
    }
}

/// 精装书架立体悬浮层板
private struct TactileShelfLedgeView: View {
    let isDark: Bool

    var body: some View {
        let topGrad = isDark
            ? LinearGradient(
                colors: [Color(red: 0.17, green: 0.17, blue: 0.18), Color(red: 0.12, green: 0.12, blue: 0.135)],
                startPoint: .top,
                endPoint: .bottom
            )
            : LinearGradient(
                colors: [Color(red: 0.98, green: 0.98, blue: 0.99), Color(red: 0.925, green: 0.933, blue: 0.95)],
                startPoint: .top,
                endPoint: .bottom
            )
        let lipColor = isDark
            ? Color(red: 0.08, green: 0.08, blue: 0.09)
            : Color(red: 0.85, green: 0.86, blue: 0.89)

        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(topGrad)
                .frame(height: 11)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(isDark ? 0.14 : 0.7))
                        .frame(height: 0.8)
                        .padding(.horizontal, 2)
                }

            Rectangle()
                .fill(lipColor)
                .frame(height: 2)
                .clipShape(TactileBottomCornerShape(radius: 4))
        }
        .shadow(color: .black.opacity(isDark ? 0.65 : 0.14), radius: 7, y: 5)
        .shadow(color: .black.opacity(isDark ? 0.40 : 0.08), radius: 2, y: 1.5)
    }
}

/// 左/右独立圆角矩形（兼容 iOS 15+，不依赖 iOS 16 UnevenRoundedRectangle）
private struct TactileBookCoverShape: Shape {
    let leadingRadius: CGFloat
    let trailingRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let tl = min(leadingRadius, min(rect.width, rect.height) / 2)
        let bl = tl
        let tr = min(trailingRadius, min(rect.width, rect.height) / 2)
        let br = tr

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        if tr > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr),
                radius: tr,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        if br > 0 {
            path.addArc(
                center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                radius: br,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        if bl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl),
                radius: bl,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        }
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        if tl > 0 {
            path.addArc(
                center: CGPoint(x: rect.minX + tl, y: rect.minY + tl),
                radius: tl,
                startAngle: .degrees(180),
                endAngle: .degrees(270),
                clockwise: false
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct TactileBottomCornerShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, min(rect.width / 2, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(
            center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
            radius: r,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

// MARK: - 5. 焦点杂志流 (App Store Today 风格 — 层次探索流)

private struct DiscoverMagazineTodayView: View {
    let mangas: [Manga]
    @ObservedObject var store: AppStore
    let onItemAppear: (Manga) -> Void

    private let compactGridColumns = [
        GridItem(.flexible(), spacing: 10, alignment: .top),
        GridItem(.flexible(), spacing: 10, alignment: .top)
    ]

    private var heroManga: Manga? {
        mangas.first
    }

    private var carouselItems: [Manga] {
        guard mangas.count > 1 else { return [] }
        return Array(mangas.dropFirst().prefix(5))
    }

    private var gridItems: [Manga] {
        guard mangas.count > 1 else { return [] }
        if mangas.count > 6 {
            return Array(mangas.dropFirst(6))
        }
        return Array(mangas.dropFirst())
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            // 1. 首屏 Hero 焦点推荐大卡
            if let hero = heroManga {
                magazineHeroCard(hero)
                    .padding(.horizontal, 16)
                    .onAppear {
                        onItemAppear(hero)
                    }
            }

            // 2. 横向滑卡区
            if !carouselItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("本页焦点")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("横滑探索")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)

                    magazineHorizontalCarousel(items: carouselItems)
                }
            }

            // 3. 底部紧凑 2 列横向发现网格（完整承接当前页及瀑布流后续全部作品）
            if !gridItems.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(mangas.count > 6 ? "探索更多佳作" : "本页作品速览")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.primary)

                        Spacer()

                        Text("共 \(gridItems.count) 部")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: compactGridColumns, spacing: 10) {
                        ForEach(gridItems) { manga in
                            magazineCompactRowCard(manga)
                                .onAppear {
                                    onItemAppear(manga)
                                }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func magazineHeroCard(_ manga: Manga) -> some View {
        let progress = store.progress(for: manga)
        let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
        let tags = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 3)

        return DiscoverMangaLink(manga: manga) {
            HStack(spacing: 14) {
                // 左侧微倾立体封面
                AsyncMangaCoverView(
                    urlString: manga.coverURL,
                    headers: manga.coverHeaders,
                    cornerRadius: 10
                )
                .frame(width: 98, height: 138)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.28), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.42), radius: 12, y: 7)
                .rotationEffect(.degrees(-2))

                // 右侧编辑策展文案 + 高对比胶囊 CTA
                VStack(alignment: .leading, spacing: 7) {
                    Text("✦ 今日精选聚焦")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.95))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())

                    Text(meta.cleanTitle)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(heroDescription(manga: manga, meta: meta, tags: tags))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 4)

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            if !manga.statusText.isEmpty {
                                DiscoverStatusBadgeLabel(
                                    statusText: manga.statusText,
                                    compact: true,
                                    isOnDarkBackground: true
                                )
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            ReadingProgressRingView(
                                hasProgress: progress != nil,
                                progress: progress?.progressRatio,
                                isExact: progress?.totalPages != nil,
                                size: 12,
                                isOnDarkBackground: true
                            )
                        }

                        Spacer(minLength: 4)

                        Text(progress.map { "继续 P\($0.pageIndex + 1)" } ?? "立即查看")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5.5)
                            .background(.white, in: Capsule())
                            .shadow(color: .black.opacity(0.14), radius: 3, y: 1.5)
                    }
                }
                .frame(height: 138, alignment: .top)
            }
            .padding(16)
            .background {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.10, blue: 0.25),
                            Color(red: 0.16, green: 0.15, blue: 0.34),
                            Color(red: 0.10, green: 0.12, blue: 0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )

                    AsyncMangaCoverView(
                        urlString: manga.coverURL,
                        headers: manga.coverHeaders,
                        cornerRadius: 0
                    )
                    .scaleEffect(1.22)
                    .blur(radius: 26)
                    .opacity(0.58)
                    .allowsHitTesting(false)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.30),
                            Color.black.opacity(0.56)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.20), radius: 14, y: 7)
        }
    }

    private func magazineHorizontalCarousel(items: [Manga]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { manga in
                    let progress = store.progress(for: manga)
                    let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)

                    DiscoverMangaLink(manga: manga) {
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncMangaCoverView(
                                urlString: manga.coverURL,
                                headers: manga.coverHeaders,
                                cornerRadius: 11
                            )
                            .frame(width: 124, height: 174)
                            .overlay(alignment: .bottomLeading) {
                                if let progress {
                                    Text("P\(progress.pageIndex + 1)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.black.opacity(0.66), in: Capsule())
                                        .padding(6)
                                }
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 6, y: 3)

                            Text(meta.cleanTitle)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            HStack(spacing: 4) {
                                if !manga.statusText.isEmpty {
                                    DiscoverStatusBadgeLabel(statusText: manga.statusText, compact: true)
                                        .fixedSize(horizontal: true, vertical: false)
                                } else {
                                    let info = meta.groupName ?? (!manga.author.isEmpty ? manga.displayAuthor : "")
                                    if !info.isEmpty {
                                        Text(info)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 2)
                                ReadingProgressRingView(
                                    hasProgress: progress != nil,
                                    progress: progress?.progressRatio,
                                    isExact: progress?.totalPages != nil,
                                    size: 11
                                )
                            }
                        }
                        .frame(width: 124, alignment: .leading)
                    }
                    .onAppear {
                        onItemAppear(manga)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
            .compatScrollTargetLayout()
        }
        .compatViewAlignedScrollBehavior()
    }

    private func magazineCompactRowCard(_ manga: Manga) -> some View {
        let progress = store.progress(for: manga)
        let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)

        return DiscoverMangaLink(manga: manga) {
            HStack(spacing: 9) {
                AsyncMangaCoverView(
                    urlString: manga.coverURL,
                    headers: manga.coverHeaders,
                    cornerRadius: 6
                )
                .frame(width: 46, height: 64)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

                VStack(alignment: .leading, spacing: 5) {
                    Text(meta.cleanTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer(minLength: 0)

                    HStack(spacing: 4) {
                        if !manga.statusText.isEmpty {
                            DiscoverStatusBadgeLabel(statusText: manga.statusText, compact: true)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if let group = meta.groupName {
                            Text(group)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if let progress {
                            Text("P\(progress.pageIndex + 1)")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 2)

                        ReadingProgressRingView(
                            hasProgress: progress != nil,
                            progress: progress?.progressRatio,
                            isExact: progress?.totalPages != nil,
                            size: 11
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 64, alignment: .top)
            }
            .padding(8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func heroDescription(manga: Manga, meta: MangaTitleMetadata, tags: [String]) -> String {
        let cleanSummary = manga.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSummary.isEmpty {
            return cleanSummary
        }
        var parts: [String] = []
        if !manga.author.isEmpty { parts.append(manga.displayAuthor) }
        if let group = meta.groupName { parts.append(group) }
        parts.append(contentsOf: tags)
        return parts.isEmpty ? "点击查看详情与章节列表" : parts.joined(separator: " · ")
    }
}

// MARK: - Shared Micro Subviews & Compat Helpers

private struct DiscoverStatusBadgeLabel: View {
    let statusText: String
    var compact: Bool = false
    var isOnDarkBackground: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            if MangaSerialStatusHelper.isOngoingStatus(statusText) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 4.5, height: 4.5)
            } else if MangaSerialStatusHelper.isCompletedStatus(statusText) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 4.5, height: 4.5)
            }
            Text(statusText)
                .font(compact ? .system(size: 10, weight: .medium) : .caption2)
                .foregroundStyle(isOnDarkBackground ? Color.white.opacity(0.92) : Color.secondary)
                .lineLimit(1)
        }
    }
}

private struct DiscoverMicroCapsule: View {
    let text: String
    let isAccent: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(isAccent ? Color.accentColor : Color.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                isAccent ? Color.accentColor.opacity(0.13) : Color(.secondarySystemFill),
                in: Capsule()
            )
    }
}

private func triggerLightHaptic() {
    #if canImport(UIKit)
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.impactOccurred()
    #endif
}

private extension View {
    @ViewBuilder
    func compatScrollTargetLayout() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetLayout()
        } else {
            self
        }
    }

    @ViewBuilder
    func compatViewAlignedScrollBehavior() -> some View {
        if #available(iOS 17.0, *) {
            self.scrollTargetBehavior(.viewAligned)
        } else {
            self
        }
    }
}
