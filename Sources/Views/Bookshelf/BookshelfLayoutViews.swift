import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 聚焦续读视图内置的状态筛选胶囊
enum BookshelfFocusFilter: String, CaseIterable, Identifiable {
    case all = "all"
    case reading = "reading"
    case unread = "unread"
    case ongoing = "ongoing"
    case completed = "completed"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .reading: return "在读"
        case .unread: return "未读"
        case .ongoing: return "连载中"
        case .completed: return "已完结"
        }
    }

    func matches(_ manga: Manga, progress: ReadingProgress?) -> Bool {
        switch self {
        case .all:
            return true
        case .reading:
            guard let progress else { return false }
            return !progress.isCompleted
        case .unread:
            return progress == nil
        case .ongoing:
            return MangaSerialStatusHelper.isOngoingStatus(manga.statusText)
        case .completed:
            return MangaSerialStatusHelper.isCompletedStatus(manga.statusText)
        }
    }
}

/// 书架交互回调集合（统一供 4 套排布视图调用）
struct BookshelfViewCallbacks {
    let onToggleSelect: (Manga) -> Void
    let onQuickResume: (Manga) -> Void
    let onMarkCompleted: (Manga) -> Void
    let onResetProgress: (Manga) -> Void
    let onRemoveSingle: (Manga) -> Void
}

/// 书架多样式集合容器（4 套原生高阶书架视图，全量使用 iOS 15+ 通用 SwiftUI API）
struct BookshelfLayoutCollectionView: View {
    let style: BookshelfLayoutStyle
    let allBooks: [Manga]
    let sortedBooks: [Manga]
    let displayedBooks: [Manga]
    let isSearching: Bool
    let isEditing: Bool
    let selectedKeys: Set<String>
    let launchingMangaKey: String?
    @Binding var focusFilter: BookshelfFocusFilter
    @ObservedObject var store: AppStore
    let callbacks: BookshelfViewCallbacks

    var body: some View {
        switch style {
        case .focusShelf:
            BookshelfFocusShelfView(
                allBooks: allBooks,
                sortedBooks: sortedBooks,
                displayedBooks: displayedBooks,
                isSearching: isSearching,
                isEditing: isEditing,
                selectedKeys: selectedKeys,
                launchingMangaKey: launchingMangaKey,
                focusFilter: $focusFilter,
                store: store,
                callbacks: callbacks
            )
        case .progressList:
            BookshelfProgressListView(
                books: displayedBooks,
                isEditing: isEditing,
                selectedKeys: selectedKeys,
                launchingMangaKey: launchingMangaKey,
                store: store,
                callbacks: callbacks
            )
        case .geekMatrix:
            BookshelfGeekMatrixView(
                books: displayedBooks,
                isEditing: isEditing,
                selectedKeys: selectedKeys,
                store: store,
                callbacks: callbacks
            )
        case .readingTimeline:
            BookshelfReadingTimelineView(
                books: displayedBooks,
                isEditing: isEditing,
                showsStatsHeader: !isSearching && !isEditing,
                selectedKeys: selectedKeys,
                launchingMangaKey: launchingMangaKey,
                store: store,
                callbacks: callbacks
            )
        }
    }
}

// MARK: - 跨分支导航包装器（ios15 分支采用 destination NavigationLink）

private struct BookshelfMangaLink<Label: View>: View {
    let manga: Manga
    @ViewBuilder let label: () -> Label

    var body: some View {
        NavigationLink(destination: MangaDetailView(manga: manga)) {
            label()
        }
        .buttonStyle(.plain)
    }
}

/// 统一条目交互壳：普通态跳转详情页 + 长按菜单，批量编辑态切换勾选（避免误跳详情页）
private struct BookshelfItemInteractiveWrapper<Content: View>: View {
    let manga: Manga
    let progress: ReadingProgress?
    let isEditing: Bool
    let callbacks: BookshelfViewCallbacks
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isEditing {
            Button {
                callbacks.onToggleSelect(manga)
            } label: {
                content()
            }
            .buttonStyle(.plain)
        } else {
            BookshelfMangaLink(manga: manga) {
                content()
            }
            .bookshelfItemContextMenu(
                manga: manga,
                progress: progress,
                callbacks: callbacks
            )
        }
    }
}

// MARK: - 1. 聚焦续读视图 (Apple Books Focus + 3-Col Shelf)

private struct BookshelfFocusShelfView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let allBooks: [Manga]
    let sortedBooks: [Manga]
    let displayedBooks: [Manga]
    let isSearching: Bool
    let isEditing: Bool
    let selectedKeys: Set<String>
    let launchingMangaKey: String?
    @Binding var focusFilter: BookshelfFocusFilter
    @ObservedObject var store: AppStore
    let callbacks: BookshelfViewCallbacks

    /// 优先选取最近阅读且尚未读完的漫画作为焦点卡，次选最近阅读，若全部未读则取首本收藏
    private var heroManga: Manga? {
        guard !isSearching, !isEditing, !allBooks.isEmpty else { return nil }
        let readBooks = allBooks
            .compactMap { manga -> (Manga, ReadingProgress)? in
                guard let p = store.progress(for: manga) else { return nil }
                return (manga, p)
            }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }

        if let inProgress = readBooks.first(where: { !$0.1.isCompleted }) {
            return inProgress.0
        }
        if let latestRead = readBooks.first {
            return latestRead.0
        }
        return sortedBooks.first ?? allBooks.first
    }

    private var gridColumns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 118, maximum: 156), spacing: 14, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)
    }

    private func count(for filter: BookshelfFocusFilter) -> Int {
        sortedBooks.reduce(into: 0) { count, manga in
            if filter.matches(manga, progress: store.progress(for: manga)) {
                count += 1
            }
        }
    }

    private var visibleFilters: [BookshelfFocusFilter] {
        BookshelfFocusFilter.allCases.filter { filter in
            if filter == .all || filter == .reading || filter == .unread || filter == focusFilter {
                return true
            }
            return count(for: filter) > 0
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let hero = heroManga {
                BookshelfHeroResumeCard(
                    manga: hero,
                    progress: store.progress(for: hero),
                    addedAt: store.bookshelfAddedDate(for: hero),
                    chapterBadge: store.resolvedBookshelfChapterBadge(for: hero),
                    isLaunching: launchingMangaKey == hero.compositeKey,
                    callbacks: callbacks
                )
            }

            // 快捷状态筛选胶囊栏
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(visibleFilters) { filter in
                        let isActive = focusFilter == filter
                        let itemCount = count(for: filter)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                focusFilter = filter
                            }
                            BookshelfHaptics.light()
                        } label: {
                            HStack(spacing: 4) {
                                Text(filter.title)
                                Text("\(itemCount)")
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .opacity(isActive ? 0.9 : 0.72)
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(isActive ? Color.white : Color.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6.5)
                            .background(
                                isActive ? Color.accentColor : Color(uiColor: .secondarySystemFill),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)

            if displayedBooks.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                    Text("「\(focusFilter.title)」分类下暂无漫画")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            focusFilter = .all
                        }
                    } label: {
                        Text("查看全部收藏")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 18) {
                    ForEach(displayedBooks, id: \.compositeKey) { manga in
                        let progress = store.progress(for: manga)
                        let chapterBadge = store.resolvedBookshelfChapterBadge(for: manga)
                        let isSelected = selectedKeys.contains(manga.compositeKey)

                        BookshelfItemInteractiveWrapper(
                            manga: manga,
                            progress: progress,
                            isEditing: isEditing,
                            callbacks: callbacks
                        ) {
                            BookshelfFocusGridCard(
                                manga: manga,
                                progress: progress,
                                chapterBadge: chapterBadge,
                                isEditing: isEditing,
                                isSelected: isSelected
                            )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

/// 顶部「继续阅读」焦点大卡
private struct BookshelfHeroResumeCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let manga: Manga
    let progress: ReadingProgress?
    let addedAt: Date?
    let chapterBadge: BookshelfChapterBadgeInfo?
    let isLaunching: Bool
    let callbacks: BookshelfViewCallbacks

    private var meta: MangaTitleMetadata {
        MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
    }

    private var hasProgress: Bool { progress != nil }
    private var isCompleted: Bool { progress?.isCompleted == true }

    private var eyebrowTitle: String {
        if !hasProgress { return "开始阅读" }
        return isCompleted ? "再次重温" : "继续阅读"
    }

    private var ctaTitle: String {
        if !hasProgress { return "开始阅读" }
        return isCompleted ? "重新阅读" : "继续阅读"
    }

    private var relativeTimeText: String? {
        if let updated = progress?.updatedAt {
            return BookshelfTimeFormatter.relativeLabel(for: updated)
        }
        if let addedAt {
            return "收藏于 \(BookshelfTimeFormatter.relativeLabel(for: addedAt))"
        }
        return nil
    }

    private var subtitleLine: String {
        var parts: [String] = []
        if !manga.author.isEmpty {
            parts.append(manga.displayAuthor)
        }
        if let group = meta.groupName, !group.isEmpty {
            parts.append(group)
        } else if let firstTag = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 1).first {
            parts.append(firstTag)
        }
        return parts.isEmpty ? "个人书架收藏" : parts.joined(separator: " · ")
    }

    private var progressLeadingText: String {
        guard let progress else { return "尚未开始阅读" }
        if progress.isManuallyMarkedCompleted {
            return "已标记读完"
        }
        if !progress.chapterTitle.isEmpty {
            return "\(progress.chapterTitle) · P\(progress.pageIndex + 1)"
        }
        return "已读至 P\(progress.pageIndex + 1)"
    }

    private var progressTrailingText: String {
        guard let progress else { return "未读" }
        if let pct = progress.percentageInt {
            return "\(pct)%"
        }
        return "P\(progress.pageIndex + 1)"
    }

    private var progressFillRatio: Double {
        guard let progress else { return 0 }
        if let ratio = progress.progressRatio {
            return min(1.0, max(0.04, ratio))
        }
        return 0.16
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            BookshelfMangaLink(manga: manga) {
                HStack(alignment: .center, spacing: 14) {
                    AsyncMangaCoverView(
                        urlString: manga.coverURL,
                        headers: manga.coverHeaders,
                        cornerRadius: 10
                    )
                    .frame(width: 82, height: 116)
                    .overlay(BookshelfCoverSpineCrease(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) {
                        if let chapterBadge {
                            BookshelfCoverChapterBadge(
                                text: chapterBadge.text,
                                hasUnreadUpdate: chapterBadge.hasUnreadUpdate,
                                compact: true
                            )
                            .padding(.top, 4)
                            .padding(.trailing, 4)
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.42 : 0.18), radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text(eyebrowTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(isCompleted ? Color.green : Color.accentColor)

                            if let relativeTimeText {
                                Text("· \(relativeTimeText)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Text(meta.cleanTitle)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .padding(.top, 3)

                        Text(subtitleLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(progressLeadingText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(progressTrailingText)
                                    .font(.system(size: 11, weight: .bold))
                                    .monospacedDigit()
                                    .foregroundStyle(
                                        !hasProgress ? Color.secondary : (isCompleted ? Color.green : Color.accentColor)
                                    )
                            }

                            BookshelfLinearProgressTrack(
                                ratio: progressFillRatio,
                                isCompleted: isCompleted,
                                height: 4.5
                            )
                        }
                        .padding(.top, 10)

                        HStack(spacing: 8) {
                            if !manga.statusText.isEmpty {
                                BookshelfStatusPill(statusText: manga.statusText)
                            } else if let tag = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 1).first {
                                Text(tag)
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                            }
                            Spacer(minLength: 92)
                        }
                        .frame(minHeight: 28, alignment: .bottomLeading)
                        .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .background(heroCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.06),
                            lineWidth: 0.75
                        )
                )
                .shadow(
                    color: colorScheme == .dark
                        ? Color.black.opacity(0.45)
                        : Color.black.opacity(0.07),
                    radius: colorScheme == .dark ? 10 : 14,
                    y: 6
                )
            }
            .bookshelfItemContextMenu(
                manga: manga,
                progress: progress,
                callbacks: callbacks
            )

            // 独立悬浮 CTA 按钮，规避 NavigationLink 内嵌 Button 的点击手势冲突
            Button {
                callbacks.onQuickResume(manga)
            } label: {
                HStack(spacing: 4) {
                    if isLaunching {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.72)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                    }
                    Text(isLaunching ? "载入中" : ctaTitle)
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 6.5)
                .background(
                    (isCompleted ? Color.green : Color.accentColor),
                    in: Capsule()
                )
                .shadow(
                    color: (isCompleted ? Color.green : Color.accentColor).opacity(0.28),
                    radius: 6,
                    y: 3
                )
            }
            .buttonStyle(.plain)
            .disabled(isLaunching)
            .padding(.trailing, 14)
            .padding(.bottom, 14)
        }
    }

    private var heroCardBackground: some View {
        ZStack {
            Color(uiColor: .secondarySystemGroupedBackground)

            RadialGradient(
                colors: [
                    Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 8,
                endRadius: 210
            )
        }
    }
}

/// 聚焦续读 3 列卡片（统一收敛为封面底部 3.5pt 进度轨 + 清洗后双行书名 + 状态页码底行）
private struct BookshelfFocusGridCard: View {
    let manga: Manga
    let progress: ReadingProgress?
    let chapterBadge: BookshelfChapterBadgeInfo?
    let isEditing: Bool
    let isSelected: Bool

    private var meta: MangaTitleMetadata {
        MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
    }

    private var rightProgressLabel: String {
        guard let progress else { return "未读" }
        if progress.isCompleted { return "已读完" }
        return "P\(progress.pageIndex + 1)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncMangaCoverView(
                urlString: manga.coverURL,
                headers: manga.coverHeaders,
                cornerRadius: 10
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(3.0 / 4.2, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if !isEditing, let chapterBadge {
                    BookshelfCoverChapterBadge(
                        text: chapterBadge.text,
                        hasUnreadUpdate: chapterBadge.hasUnreadUpdate,
                        compact: false
                    )
                    .padding(.top, 5)
                    .padding(.trailing, 5)
                }
            }
            .overlay(alignment: .bottom) {
                if let progress {
                    BookshelfCoverBottomProgressBar(progress: progress, height: 3.5)
                }
            }
            .overlay {
                if isEditing {
                    BookshelfSelectionOverlay(isSelected: isSelected, cornerRadius: 10, compact: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isEditing && isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isEditing && isSelected ? 2 : 0.5
                    )
            )
            .shadow(color: .black.opacity(0.10), radius: 5, y: 2.5)

            Text(meta.cleanTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 33, maxHeight: 33, alignment: .topLeading)

            HStack(spacing: 4) {
                if !manga.statusText.isEmpty {
                    BookshelfStatusDotText(statusText: manga.statusText)
                } else if !manga.author.isEmpty {
                    Text(manga.displayAuthor)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(rightProgressLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(
                        progress?.isCompleted == true
                            ? Color.green
                            : (progress != nil ? Color.accentColor : Color.secondary.opacity(0.78))
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - 2. 进度列表视图 (Detail Progress List)

private struct BookshelfProgressListView: View {
    let books: [Manga]
    let isEditing: Bool
    let selectedKeys: Set<String>
    let launchingMangaKey: String?
    @ObservedObject var store: AppStore
    let callbacks: BookshelfViewCallbacks

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(books.enumerated()), id: \.element.compositeKey) { index, manga in
                let progress = store.progress(for: manga)
                let chapterBadge = store.resolvedBookshelfChapterBadge(for: manga)
                let isSelected = selectedKeys.contains(manga.compositeKey)
                let isLaunching = launchingMangaKey == manga.compositeKey

                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        BookshelfItemInteractiveWrapper(
                            manga: manga,
                            progress: progress,
                            isEditing: isEditing,
                            callbacks: callbacks
                        ) {
                            BookshelfProgressListRowContent(
                                manga: manga,
                                progress: progress,
                                addedAt: store.bookshelfAddedDate(for: manga),
                                chapterBadge: chapterBadge,
                                isEditing: isEditing,
                                isSelected: isSelected
                            )
                        }

                        if !isEditing {
                            BookshelfQuickActionCapsule(
                                progress: progress,
                                isLaunching: isLaunching
                            ) {
                                callbacks.onQuickResume(manga)
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    if index < books.count - 1 {
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.55))
                            .frame(height: 0.5)
                            .padding(.leading, 78)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 16)
    }
}

private struct BookshelfProgressListRowContent: View {
    let manga: Manga
    let progress: ReadingProgress?
    let addedAt: Date?
    let chapterBadge: BookshelfChapterBadgeInfo?
    let isEditing: Bool
    let isSelected: Bool

    private var meta: MangaTitleMetadata {
        MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
    }

    private var pills: [String] {
        var result: [String] = []
        if !manga.author.isEmpty && manga.displayAuthor != "佚名" {
            result.append(manga.displayAuthor)
        }
        if let group = meta.groupName, !group.isEmpty, !result.contains(group) {
            result.append(group)
        }
        let extraTags = MangaTitleMetadataParser.displayTags(for: manga, metadata: meta, limit: 2)
        for tag in extraTags where !result.contains(tag) && result.count < 3 {
            result.append(tag)
        }
        return result
    }

    private var progressDetailText: String {
        guard let progress else { return "尚未开读" }
        if progress.isManuallyMarkedCompleted {
            return "已读完 · 100%"
        }
        if let total = progress.totalPages, total > 0, let pct = progress.percentageInt {
            return "P\(progress.pageIndex + 1) / \(total) · \(pct)%"
        }
        return "已读至 P\(progress.pageIndex + 1)"
    }

    private var fillRatio: Double {
        guard let progress else { return 0 }
        if let ratio = progress.progressRatio {
            return min(1.0, max(0.04, ratio))
        }
        return 0.16
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AsyncMangaCoverView(
                urlString: manga.coverURL,
                headers: manga.coverHeaders,
                cornerRadius: 8
            )
            .frame(width: 64, height: 90)
            .overlay(BookshelfCoverSpineCrease(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if !isEditing, chapterBadge?.hasUnreadUpdate == true {
                    BookshelfCoverUpdateDot()
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                }
            }
            .overlay {
                if isEditing {
                    BookshelfSelectionOverlay(isSelected: isSelected, cornerRadius: 8, compact: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isEditing && isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isEditing && isSelected ? 2 : 0.5
                    )
            )
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2.5)

            VStack(alignment: .leading, spacing: 6) {
                Text(meta.cleanTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !pills.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(Array(pills.enumerated()), id: \.offset) { idx, pill in
                            Text(pill)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(idx == pills.count - 1 && pills.count > 2 ? Color.secondary.opacity(0.8) : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Color(uiColor: .secondarySystemFill),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4.5) {
                    HStack(spacing: 6) {
                        if let chapterBadge {
                            BookshelfInlineChapterPill(badge: chapterBadge)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if !manga.statusText.isEmpty {
                            BookshelfStatusDotText(statusText: manga.statusText)
                                .fixedSize(horizontal: true, vertical: false)
                        } else if let date = progress?.updatedAt ?? addedAt {
                            Text(BookshelfTimeFormatter.relativeLabel(for: date))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 4)

                        Text(progressDetailText)
                            .font(.system(size: 10.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(progress?.isCompleted == true ? Color.green : Color.secondary)
                            .lineLimit(1)
                    }

                    BookshelfLinearProgressTrack(
                        ratio: fillRatio,
                        isCompleted: progress?.isCompleted == true,
                        height: 4
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

private struct BookshelfQuickActionCapsule: View {
    let progress: ReadingProgress?
    let isLaunching: Bool
    let action: () -> Void

    private var title: String {
        guard let progress else { return "开读" }
        return progress.isCompleted ? "重读" : "续读"
    }

    private var isCompleted: Bool {
        progress?.isCompleted == true
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isLaunching {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.75)
                        .frame(width: 28, height: 15)
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                }
            }
            .foregroundStyle(isCompleted ? Color.secondary : Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6.5)
            .background(
                isCompleted ? Color(uiColor: .secondarySystemFill) : Color.accentColor.opacity(0.13),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .disabled(isLaunching)
    }
}

// MARK: - 3. 极客四列高密矩阵 (High-Density 4-Col Matrix)

private struct BookshelfGeekMatrixView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let books: [Manga]
    let isEditing: Bool
    let selectedKeys: Set<String>
    @ObservedObject var store: AppStore
    let callbacks: BookshelfViewCallbacks

    private var columns: [GridItem] {
        if horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 90, maximum: 118), spacing: 8, alignment: .top)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 7, alignment: .top), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("高密矩阵 · 单屏速览")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                // 极简纯图 / 紧凑标题 内嵌分段胶囊
                HStack(spacing: 2) {
                    matrixTogglePill(title: "极简纯图", active: !store.bookshelfGeekMatrixShowTitles) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.bookshelfGeekMatrixShowTitles = false
                        }
                        BookshelfHaptics.light()
                    }
                    matrixTogglePill(title: "紧凑标题", active: store.bookshelfGeekMatrixShowTitles) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            store.bookshelfGeekMatrixShowTitles = true
                        }
                        BookshelfHaptics.light()
                    }
                }
                .padding(2)
                .background(
                    Color(uiColor: .secondarySystemFill),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }
            .padding(.horizontal, 2)

            LazyVGrid(columns: columns, spacing: store.bookshelfGeekMatrixShowTitles ? 12 : 7) {
                ForEach(books, id: \.compositeKey) { manga in
                    let progress = store.progress(for: manga)
                    let chapterBadge = store.resolvedBookshelfChapterBadge(for: manga)
                    let isSelected = selectedKeys.contains(manga.compositeKey)
                    let meta = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)

                    BookshelfItemInteractiveWrapper(
                        manga: manga,
                        progress: progress,
                        isEditing: isEditing,
                        callbacks: callbacks
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            AsyncMangaCoverView(
                                urlString: manga.coverURL,
                                headers: manga.coverHeaders,
                                cornerRadius: 8
                            )
                            .frame(maxWidth: .infinity)
                            .aspectRatio(3.0 / 4.25, contentMode: .fit)
                            .overlay(alignment: .topLeading) {
                                if !isEditing, let chapterBadge {
                                    BookshelfCoverChapterBadge(
                                        text: chapterBadge.compactText,
                                        hasUnreadUpdate: chapterBadge.hasUnreadUpdate,
                                        compact: true
                                    )
                                    .padding(.top, 4)
                                    .padding(.leading, 4)
                                }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                if !isEditing, let progress {
                                    ZStack {
                                        Circle()
                                            .fill(Color.black.opacity(0.56))
                                            .frame(width: 20, height: 20)
                                        if progress.isCompleted {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9.5, weight: .bold))
                                                .foregroundStyle(Color.green)
                                        } else {
                                            ReadingProgressRingView(
                                                hasProgress: true,
                                                progress: progress.progressRatio,
                                                isExact: progress.totalPages != nil,
                                                size: 13,
                                                isOnDarkBackground: true
                                            )
                                        }
                                    }
                                    .padding(.trailing, 5)
                                    .padding(.bottom, 5)
                                }
                            }
                            .overlay {
                                if isEditing {
                                    BookshelfSelectionOverlay(isSelected: isSelected, cornerRadius: 8, compact: true)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(
                                        isEditing && isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                        lineWidth: isEditing && isSelected ? 2 : 0.5
                                    )
                            )
                            .shadow(color: .black.opacity(0.09), radius: 3, y: 1.5)

                            if store.bookshelfGeekMatrixShowTitles {
                                Text(meta.cleanTitle)
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 1)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private func matrixTogglePill(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if active {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                        } else {
                            Color.clear
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4. 阅读时间轴视图 (Reading Timeline)

private enum BookshelfTimelineBucket: String, CaseIterable, Identifiable {
    case today = "today"
    case thisWeek = "this_week"
    case earlierRead = "earlier_read"
    case unread = "unread"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "今天在读"
        case .thisWeek: return "本周在读"
        case .earlierRead: return "更早阅读"
        case .unread: return "收藏待读"
        }
    }
}

private struct BookshelfTimelineSection: Identifiable {
    let bucket: BookshelfTimelineBucket
    let items: [Manga]
    var id: String { bucket.id }
}

private struct BookshelfReadingTimelineView: View {
    let books: [Manga]
    let isEditing: Bool
    let showsStatsHeader: Bool
    let selectedKeys: Set<String>
    let launchingMangaKey: String?
    @ObservedObject var store: AppStore
    let callbacks: BookshelfViewCallbacks

    private var groupedSections: [BookshelfTimelineSection] {
        let now = Date()
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now.addingTimeInterval(-7 * 86400)

        var map: [BookshelfTimelineBucket: [Manga]] = [:]
        for manga in books {
            let bucket: BookshelfTimelineBucket
            if let updatedAt = store.progress(for: manga)?.updatedAt {
                if calendar.isDateInToday(updatedAt) {
                    bucket = .today
                } else if updatedAt >= weekAgo {
                    bucket = .thisWeek
                } else {
                    bucket = .earlierRead
                }
            } else {
                bucket = .unread
            }
            map[bucket, default: []].append(manga)
        }

        return BookshelfTimelineBucket.allCases.compactMap { bucket in
            guard let items = map[bucket], !items.isEmpty else { return nil }
            return BookshelfTimelineSection(bucket: bucket, items: items)
        }
    }

    var body: some View {
        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            if showsStatsHeader {
                ReadingStatsDashboardView(store: store)
                    .padding(.bottom, 4)
            }
            ForEach(groupedSections) { section in
                Section {
                    VStack(spacing: 10) {
                        ForEach(Array(section.items.enumerated()), id: \.element.compositeKey) { idx, manga in
                            let progress = store.progress(for: manga)
                            let chapterBadge = store.resolvedBookshelfChapterBadge(for: manga)
                            let isSelected = selectedKeys.contains(manga.compositeKey)
                            let isLaunching = launchingMangaKey == manga.compositeKey

                            BookshelfTimelineRow(
                                manga: manga,
                                progress: progress,
                                addedAt: store.bookshelfAddedDate(for: manga),
                                chapterBadge: chapterBadge,
                                bucket: section.bucket,
                                isFirstInSection: idx == 0,
                                isLastInSection: idx == section.items.count - 1,
                                isEditing: isEditing,
                                isSelected: isSelected,
                                isLaunching: isLaunching,
                                callbacks: callbacks
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                } header: {
                    HStack {
                        Text(section.bucket.title)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(section.items.count) 部")
                            .font(.system(size: 11.5, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondary.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.35))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .padding(.bottom, 12)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

private struct BookshelfTimelineRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let manga: Manga
    let progress: ReadingProgress?
    let addedAt: Date?
    let chapterBadge: BookshelfChapterBadgeInfo?
    let bucket: BookshelfTimelineBucket
    let isFirstInSection: Bool
    let isLastInSection: Bool
    let isEditing: Bool
    let isSelected: Bool
    let isLaunching: Bool
    let callbacks: BookshelfViewCallbacks

    private var meta: MangaTitleMetadata {
        MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor)
    }

    private var nodeColor: Color {
        if progress?.isCompleted == true { return .green }
        switch bucket {
        case .today: return .accentColor
        case .thisWeek: return .accentColor.opacity(0.75)
        case .earlierRead: return .secondary.opacity(0.65)
        case .unread: return .secondary.opacity(0.45)
        }
    }

    private var timeAndPositionLabel: (time: String, position: String, highlightPosition: Bool) {
        if let progress {
            let time = BookshelfTimeFormatter.relativeLabel(for: progress.updatedAt)
            if progress.isManuallyMarkedCompleted {
                return (time, "已标记读完", true)
            }
            if progress.isCompleted {
                return (time, "已读完 · P\(progress.pageIndex + 1)", true)
            }
            return (time, "停在 P\(progress.pageIndex + 1)", true)
        }
        if let addedAt {
            return ("收藏于 \(BookshelfTimeFormatter.relativeLabel(for: addedAt))", "尚未开读", false)
        }
        return ("已收藏", "尚未开读", false)
    }

    private var progressBadgeText: String {
        guard let progress else { return "未读" }
        if let pct = progress.percentageInt {
            return progress.isCompleted ? "已读完 100%" : "进度 \(pct)%"
        }
        return "P\(progress.pageIndex + 1)"
    }

    var body: some View {
        // 右侧 InsetGrouped 卡片为主体，左侧时间轴轨通过 overlay(alignment: .leading) 严格贴合卡片真实高度，避免撑高行高
        HStack(spacing: 10) {
            BookshelfItemInteractiveWrapper(
                manga: manga,
                progress: progress,
                isEditing: isEditing,
                callbacks: callbacks
            ) {
                HStack(spacing: 12) {
                    AsyncMangaCoverView(
                        urlString: manga.coverURL,
                        headers: manga.coverHeaders,
                        cornerRadius: 7
                    )
                    .frame(width: 46, height: 64)
                    .overlay(alignment: .topTrailing) {
                        if !isEditing, chapterBadge?.hasUnreadUpdate == true {
                            BookshelfCoverUpdateDot()
                                .padding(.top, 3)
                                .padding(.trailing, 3)
                        }
                    }
                    .overlay {
                        if isEditing {
                            BookshelfSelectionOverlay(isSelected: isSelected, cornerRadius: 7, compact: true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                isEditing && isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isEditing && isSelected ? 2 : 0.5
                            )
                    )

                    VStack(alignment: .leading, spacing: 3.5) {
                        let info = timeAndPositionLabel
                        HStack(spacing: 4) {
                            Text(info.time)
                                .foregroundStyle(.secondary)
                            Text("·")
                                .foregroundStyle(Color.secondary.opacity(0.55))
                            Text(info.position)
                                .foregroundStyle(
                                    progress?.isCompleted == true
                                        ? Color.green
                                        : (info.highlightPosition ? Color.accentColor : Color.secondary)
                                )
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)

                        Text(meta.cleanTitle)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(progressBadgeText)
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(progress?.isCompleted == true ? Color.green : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    (progress?.isCompleted == true ? Color.green.opacity(0.14) : Color(uiColor: .secondarySystemFill)),
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )

                            if let chapterBadge {
                                BookshelfInlineChapterPill(badge: chapterBadge)
                            } else if !manga.statusText.isEmpty {
                                BookshelfStatusDotText(statusText: manga.statusText)
                            } else if let progress, !progress.chapterTitle.isEmpty, !progress.isManuallyMarkedCompleted {
                                Text(progress.chapterTitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }

            if !isEditing {
                Button {
                    callbacks.onQuickResume(manga)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.13))
                            .frame(width: 32, height: 32)
                        if isLaunching {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .offset(x: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLaunching)
                .accessibilityLabel("快速阅读 \(meta.cleanTitle)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isEditing && isSelected
                        ? Color.accentColor
                        : (colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)),
                    lineWidth: isEditing && isSelected ? 1.5 : 0.6
                )
        )
        .shadow(
            color: colorScheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.04),
            radius: 5,
            y: 2
        )
        .padding(.leading, 24)
        .overlay(alignment: .leading) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirstInSection ? Color.clear : Color(uiColor: .separator).opacity(0.6))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)

                Circle()
                    .fill(nodeColor)
                    .frame(width: 9, height: 9)
                    .overlay(
                        Circle()
                            .stroke(Color(uiColor: .systemGroupedBackground), lineWidth: 2.5)
                    )

                Rectangle()
                    .fill(isLastInSection ? Color.clear : Color(uiColor: .separator).opacity(0.6))
                    .frame(width: 1.5)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 14)
            .padding(.top, isFirstInSection ? 0 : -6)
            .padding(.bottom, isLastInSection ? 0 : -6)
        }
    }
}

// MARK: - 公共微型视觉组件与工具

/// 封面底部半透明细进度轨
private struct BookshelfCoverBottomProgressBar: View {
    let progress: ReadingProgress
    let height: CGFloat

    private var ratio: Double {
        if let exact = progress.progressRatio {
            return min(1.0, max(0.06, exact))
        }
        return 0.16
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.38))

                Rectangle()
                    .fill(progress.isCompleted ? Color.green : Color.accentColor)
                    .frame(width: max(4, geo.size.width * ratio))
            }
        }
        .frame(height: height)
    }
}

/// 独立线性进度条（Hero 焦点卡与进度列表共用）
private struct BookshelfLinearProgressTrack: View {
    let ratio: Double
    let isCompleted: Bool
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1.0, max(0.0, ratio))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemFill))

                if clamped > 0 {
                    Capsule()
                        .fill(isCompleted ? Color.green : Color.accentColor)
                        .frame(width: max(height, geo.size.width * clamped))
                }
            }
        }
        .frame(height: height)
    }
}

/// 书脊左侧微弱折痕高光（提升实体封面层次感）
private struct BookshelfCoverSpineCrease: View {
    let cornerRadius: CGFloat

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.24), location: 0.0),
                .init(color: .black.opacity(0.22), location: 0.05),
                .init(color: .white.opacity(0.16), location: 0.08),
                .init(color: .clear, location: 0.16),
                .init(color: .black.opacity(0.08), location: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
    }
}

/// 批量多选勾选浮层
private struct BookshelfSelectionOverlay: View {
    let isSelected: Bool
    let cornerRadius: CGFloat
    var compact: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.black.opacity(0.10))

            let badgeSize: CGFloat = compact ? 20 : 22
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.38))
                    .frame(width: badgeSize, height: badgeSize)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: compact ? 10.5 : 11.5, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 1.5)
                        .frame(width: badgeSize, height: badgeSize)
                }
            }
            .shadow(color: .black.opacity(0.24), radius: 3, y: 1)
            .padding(5)
        }
        .allowsHitTesting(false)
    }
}

/// 封面话数微胶囊角标（用于聚焦续读 3 列网格、Hero 焦点卡与极客 4 列矩阵）
private struct BookshelfCoverChapterBadge: View {
    let text: String
    let hasUnreadUpdate: Bool
    let compact: Bool

    var body: some View {
        let fontSize: CGFloat = compact ? 8.5 : 9.5
        let hPad: CGFloat = compact ? 5 : 6
        let vPad: CGFloat = compact ? 2 : 2.5
        let dotSize: CGFloat = compact ? 4.5 : 5
        let bgColor: Color = hasUnreadUpdate ? Color.black.opacity(0.76) : Color.black.opacity(0.62)
        let strokeColor: Color = hasUnreadUpdate ? Color.orange.opacity(0.75) : Color.white.opacity(0.18)

        HStack(spacing: 3) {
            if hasUnreadUpdate {
                Circle()
                    .fill(Color.orange)
                    .frame(width: dotSize, height: dotSize)
            }
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(Capsule().fill(bgColor))
        .overlay(Capsule().strokeBorder(strokeColor, lineWidth: 0.5))
    }
}

/// 小封面右上角新章节更新红点（用于进度列表与阅读时间轴）
private struct BookshelfCoverUpdateDot: View {
    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 7.5, height: 7.5)
            .overlay(
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.2)
            )
            .shadow(color: Color.black.opacity(0.32), radius: 2, y: 1)
    }
}

/// 列表/时间轴行内话数状态胶囊
private struct BookshelfInlineChapterPill: View {
    let badge: BookshelfChapterBadgeInfo

    var body: some View {
        let dotColor: Color = badge.hasUnreadUpdate
            ? .orange
            : (badge.isOngoing ? .green : .secondary.opacity(0.75))
        let textColor: Color = badge.hasUnreadUpdate
            ? .orange
            : (badge.isOngoing ? .green : .secondary)
        let bgColor: Color = badge.hasUnreadUpdate
            ? Color.orange.opacity(0.14)
            : (badge.isOngoing ? Color.green.opacity(0.12) : Color(uiColor: .secondarySystemFill))

        HStack(spacing: 3.5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
            Text(badge.text)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(textColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(bgColor))
    }
}

/// 连载/完结微状态圆点 + 文本
private struct BookshelfStatusDotText: View {
    let statusText: String

    private var dotColor: Color? {
        if MangaSerialStatusHelper.isOngoingStatus(statusText) {
            return .green
        }
        if MangaSerialStatusHelper.isCompletedStatus(statusText) {
            return .orange
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 4) {
            if let dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 5, height: 5)
            }
            Text(statusText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Hero 焦点卡底部状态胶囊
private struct BookshelfStatusPill: View {
    let statusText: String

    private var tintColor: Color {
        if MangaSerialStatusHelper.isOngoingStatus(statusText) {
            return .green
        }
        if MangaSerialStatusHelper.isCompletedStatus(statusText) {
            return .orange
        }
        return .accentColor
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tintColor)
                .frame(width: 5, height: 5)
            Text(statusText)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tintColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tintColor.opacity(0.14), in: Capsule())
    }
}

/// 书架相对时间格式化工具
enum BookshelfTimeFormatter {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    static func relativeLabel(for date: Date, relativeTo now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 {
            return "刚刚"
        }
        if interval < 3600 {
            return "\(Int(interval / 60))分钟前"
        }
        if interval < 86400, Calendar.current.isDateInToday(date) {
            return "\(Int(interval / 3600))小时前"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "昨天"
        }
        let days = Int(interval / 86400)
        if days < 7 {
            return "\(max(1, days))天前"
        }
        return monthDayFormatter.string(from: date)
    }
}

/// 轻触震动反馈辅助
enum BookshelfHaptics {
    static func light() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    static func medium() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

private extension View {
    func bookshelfItemContextMenu(
        manga: Manga,
        progress: ReadingProgress?,
        callbacks: BookshelfViewCallbacks
    ) -> some View {
        self.contextMenu {
            Button {
                callbacks.onQuickResume(manga)
            } label: {
                let labelTitle: String = {
                    guard let progress else { return "开始阅读" }
                    return progress.isCompleted ? "重新阅读" : "继续阅读"
                }()
                Label(labelTitle, systemImage: "play.fill")
            }

            if progress?.isCompleted != true {
                Button {
                    callbacks.onMarkCompleted(manga)
                } label: {
                    Label("标为已读", systemImage: "checkmark.circle")
                }
            }

            if progress != nil {
                Button {
                    callbacks.onResetProgress(manga)
                } label: {
                    Label("重置阅读进度", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            Button(role: .destructive) {
                callbacks.onRemoveSingle(manga)
            } label: {
                Label("移出书架", systemImage: "trash")
            }
        }
    }
}
