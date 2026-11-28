import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 足迹页快捷筛选维度
private enum HistoryFilterMode: String, CaseIterable, Identifiable {
    case all = "all"
    case unsaved = "unsaved"
    case saved = "saved"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .unsaved: return "未收藏"
        case .saved: return "已收藏"
        }
    }
}

/// 足迹时间分组桶
private enum HistoryTimeBucket: Int, CaseIterable, Identifiable {
    case today = 0
    case yesterday = 1
    case thisWeek = 2
    case earlier = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "今天"
        case .yesterday: return "昨天"
        case .thisWeek: return "本周"
        case .earlier: return "更早"
        }
    }

    static func classify(_ date: Date, now: Date = Date()) -> HistoryTimeBucket {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return .today
        }
        if cal.isDateInYesterday(date) {
            return .yesterday
        }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
            return .thisWeek
        }
        return .earlier
    }
}

private struct HistorySectionGroup: Identifiable {
    let bucket: HistoryTimeBucket
    let items: [ReadingHistoryItem]
    var id: Int { bucket.rawValue }
}

private struct HistoryReaderLaunchPayload: Identifiable {
    let id = UUID()
    let manga: Manga
    let chapters: [MangaChapter]
    let initialChapter: MangaChapter
    let initialPageIndex: Int?
}

/// 浏览足迹页（完整阅读历史：按时间自然分组 + 搜索与未收藏筛选 + 左滑删除 + 一键补收藏 + 一键续读）
public struct ReadingHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTab: AppTab

    @State private var searchText = ""
    @State private var filterMode: HistoryFilterMode = .all
    @State private var showingClearAlert = false

    // 一键续读状态
    @State private var quickLaunchingMangaKey: String?
    @State private var quickLaunchTask: Task<Void, Never>?
    @State private var readerLaunchPayload: HistoryReaderLaunchPayload?

    // 顶部轻提示 HUD
    @State private var hudMessage: String?
    @State private var hudDismissTask: Task<Void, Never>?

    public init(selectedTab: Binding<AppTab>) {
        self._selectedTab = selectedTab
    }

    private var searchedItems: [ReadingHistoryItem] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return store.readingHistory }
        return store.readingHistory.filter { item in
            let manga = item.manga
            if manga.title.localizedCaseInsensitiveContains(kw)
                || manga.displayAuthor.localizedCaseInsensitiveContains(kw) {
                return true
            }
            if manga.tags.contains(where: { $0.localizedCaseInsensitiveContains(kw) }) {
                return true
            }
            let cleanTitle = MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor).cleanTitle
            return cleanTitle.localizedCaseInsensitiveContains(kw)
        }
    }

    private var filteredItems: [ReadingHistoryItem] {
        switch filterMode {
        case .all:
            return searchedItems
        case .unsaved:
            return searchedItems.filter { !store.isInBookshelf($0.manga) }
        case .saved:
            return searchedItems.filter { store.isInBookshelf($0.manga) }
        }
    }

    private var groupedSections: [HistorySectionGroup] {
        let now = Date()
        var buckets: [HistoryTimeBucket: [ReadingHistoryItem]] = [:]
        for item in filteredItems {
            let bucket = HistoryTimeBucket.classify(item.viewedAt, now: now)
            buckets[bucket, default: []].append(item)
        }
        return HistoryTimeBucket.allCases.compactMap { bucket in
            guard let items = buckets[bucket], !items.isEmpty else { return nil }
            return HistorySectionGroup(bucket: bucket, items: items)
        }
    }

    private func filterCount(for mode: HistoryFilterMode) -> Int {
        switch mode {
        case .all:
            return searchedItems.count
        case .unsaved:
            return searchedItems.filter { !store.isInBookshelf($0.manga) }.count
        case .saved:
            return searchedItems.filter { store.isInBookshelf($0.manga) }.count
        }
    }

    public var body: some View {
        CompatNavigationContainer {
            VStack(spacing: 0) {
                historyHeaderBar

                if store.pauseReadingHistory {
                    incognitoBanner
                }

                if !store.readingHistory.isEmpty {
                    historySearchBar
                    historyFilterBar
                }

                Group {
                    if store.readingHistory.isEmpty {
                        emptyHistoryView
                    } else if groupedSections.isEmpty {
                        emptyFilteredView
                    } else {
                        historyListView
                    }
                }
                .overlay(alignment: .top) {
                    if let hudMessage {
                        historyHudBanner(message: hudMessage)
                            .padding(.top, 10)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.30, dampingFraction: 0.85), value: hudMessage)
            }
            .navigationTitle("足迹")
            .navigationBarTitleDisplayMode(.inline)
            .compatNavigationBarHidden(true)
            .fullScreenCover(item: $readerLaunchPayload) { payload in
                ReaderView(
                    manga: payload.manga,
                    chapters: payload.chapters,
                    initialChapter: payload.initialChapter,
                    initialPageIndex: payload.initialPageIndex
                )
                .environmentObject(store)
            }
            .alert("清空全部浏览足迹？", isPresented: $showingClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.clearAllHistory()
                    triggerHaptic(.medium)
                    showHud("已清空全部浏览足迹")
                }
            } message: {
                Text("仅清空浏览足迹列表，不会影响你的书架收藏和离线缓存。")
            }
            .onDisappear {
                hudDismissTask?.cancel()
                quickLaunchTask?.cancel()
                quickLaunchingMangaKey = nil
            }
        }
    }

    // MARK: - Header & Filter Bars

    private var historyHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("足迹")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !store.readingHistory.isEmpty {
                    Text("\(store.readingHistory.count)条")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                }
            }

            Spacer(minLength: 8)

            Menu {
                Toggle(isOn: $store.pauseReadingHistory) {
                    Label("暂停记录足迹（无痕）", systemImage: "eye.slash")
                }

                if !store.readingHistory.isEmpty {
                    Divider()

                    Button(role: .destructive) {
                        showingClearAlert = true
                    } label: {
                        Label("清空全部足迹", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: store.pauseReadingHistory ? "eye.slash.fill" : "ellipsis.circle")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(store.pauseReadingHistory ? Color.orange : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(
                        (store.pauseReadingHistory ? Color.orange : Color.accentColor).opacity(0.12),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
            .accessibilityLabel("足迹设置与清空")
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var incognitoBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.slash.fill")
                .font(.caption.weight(.bold))
            Text("已暂停记录新足迹（无痕模式）")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Button("恢复记录") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.pauseReadingHistory = false
                }
                triggerHaptic(.light)
            }
            .font(.caption.weight(.bold))
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var historySearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("搜索看过的漫画名、作者或标签", text: $searchText)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 6)
    }

    private var historyFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(HistoryFilterMode.allCases) { mode in
                    let isActive = (filterMode == mode)
                    let count = filterCount(for: mode)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            filterMode = mode
                        }
                        triggerHaptic(.light)
                    } label: {
                        HStack(spacing: 4) {
                            Text(mode.title)
                            Text("\(count)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .opacity(isActive ? 0.9 : 0.72)
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isActive ? .white : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(isActive ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    // MARK: - Grouped History List

    private var historyListView: some View {
        List {
            ForEach(groupedSections) { section in
                Section {
                    ForEach(section.items) { item in
                        historyRow(for: item)
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.removeHistory(key: item.id)
                                    triggerHaptic(.light)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    quickResume(item)
                                } label: {
                                    Label("立即续读", systemImage: "play.fill")
                                }

                                let saved = store.isInBookshelf(item.manga)
                                Button {
                                    toggleSave(item.manga)
                                } label: {
                                    Label(
                                        saved ? "移出书架" : "加入书架",
                                        systemImage: saved ? "bookmark.slash" : "bookmark.fill"
                                    )
                                }

                                Divider()

                                Button(role: .destructive) {
                                    store.removeHistory(key: item.id)
                                    triggerHaptic(.light)
                                } label: {
                                    Label("删除此条足迹", systemImage: "trash")
                                }
                            }
                    }
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
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .compatScrollDismissesKeyboard()
    }

    @ViewBuilder
    private func historyRow(for item: ReadingHistoryItem) -> some View {
        let manga = item.manga
        let saved = store.isInBookshelf(manga)
        let isLaunching = (quickLaunchingMangaKey == manga.compositeKey)
        let sourceTitle = store.sourceName(for: manga.sourceID)
        let progress = store.progress(for: manga)
        let ratio = progress?.progressRatio ?? item.progressRatio

        HStack(alignment: .center, spacing: 12) {
            NavigationLink(destination: MangaDetailView(manga: manga)) {
                HStack(alignment: .center, spacing: 12) {
                    AsyncMangaCoverView(
                        urlString: manga.coverURL,
                        headers: manga.coverHeaders,
                        cornerRadius: 8
                    )
                    .frame(width: 58, height: 80)
                    .overlay(alignment: .bottom) {
                        if let ratio {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.black.opacity(0.35))
                                    Rectangle()
                                        .fill(ratio >= 0.99 ? Color.green : Color.accentColor)
                                        .frame(width: geo.size.width * CGFloat(min(max(ratio, 0.04), 1.0)))
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.10), radius: 4, y: 2)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(MangaTitleMetadataParser.parse(title: manga.title, author: manga.displayAuthor).cleanTitle)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Text(readingSummaryText(item: item, progress: progress))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(
                                (progress != nil || item.lastPageIndex != nil)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            Text(sourceTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemFill))
                                )

                            Text(relativeTimeString(for: item.viewedAt))
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Button {
                    toggleSave(manga)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(saved ? .orange : .secondary)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(saved ? Color.orange.opacity(0.14) : Color(uiColor: .secondarySystemFill))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(saved ? "已收藏，点击取消收藏" : "加入书架")

                Button {
                    quickResume(item)
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 32, height: 32)
                        if isLaunching {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundColor(.accentColor)
                                .offset(x: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLaunching)
                .accessibilityLabel("立即续读")
            }
        }
    }

    // MARK: - Empty States & HUD

    private var emptyHistoryView: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 50))
                .foregroundStyle(.secondary)
            Text("还没有浏览足迹")
                .font(.title3.weight(.semibold))
            Text("在发现页或搜索页打开过的漫画都会自动记录在这里，没收藏也能轻松找回续读。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                selectedTab = .discover
            } label: {
                Label("前往在线发现", systemImage: "safari")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyFilteredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("没有符合条件的足迹")
                .font(.headline)
            Button {
                searchText = ""
                filterMode = .all
            } label: {
                Text("重置筛选条件")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func historyHudBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Color.black.opacity(0.84)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.24), radius: 12, y: 5)
    }

    // MARK: - Helpers & Actions

    private func readingSummaryText(item: ReadingHistoryItem, progress: ReadingProgress?) -> String {
        if let progress {
            if progress.isManuallyMarkedCompleted || progress.isCompleted {
                return "已读完 · \(progress.chapterTitle.isEmpty ? "全本" : progress.chapterTitle)"
            }
            let ch = progress.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ch.isEmpty {
                return "读至 \(ch) · P.\(progress.pageIndex + 1)"
            }
            return "读至 P.\(progress.pageIndex + 1)"
        }
        if let pageIndex = item.lastPageIndex {
            let ch = item.lastChapterTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !ch.isEmpty {
                return "读至 \(ch) · P.\(pageIndex + 1)"
            }
            return "读至 P.\(pageIndex + 1)"
        }
        return "浏览过详情"
    }

    private func relativeTimeString(for date: Date) -> String {
        let interval = max(0, Date().timeIntervalSince(date))
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600)) 小时前" }
        let days = Int(interval / 86400)
        if days < 7 { return "\(days) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func toggleSave(_ manga: Manga) {
        let wasSaved = store.isInBookshelf(manga)
        store.toggleBookshelf(manga)
        triggerHaptic(.light)
        showHud(wasSaved ? "已移出书架" : "已加入书架")
    }

    private func quickResume(_ item: ReadingHistoryItem) {
        let manga = item.manga
        guard quickLaunchingMangaKey != manga.compositeKey else { return }

        let adapter = store.adapter(for: manga.sourceID)
        let offlineChapters = OfflineDownloadManager.shared.offlineChapters(for: manga.compositeKey)
        guard adapter != nil || !offlineChapters.isEmpty else {
            showHud("未找到对应在线图源")
            return
        }

        quickLaunchTask?.cancel()
        quickLaunchingMangaKey = manga.compositeKey
        triggerHaptic(.light)

        quickLaunchTask = Task { @MainActor in
            defer {
                if quickLaunchingMangaKey == manga.compositeKey {
                    quickLaunchingMangaKey = nil
                }
            }

            @MainActor
            func launch(resolvedManga: Manga, chapters: [MangaChapter]) {
                guard let firstChapter = chapters.first else {
                    showHud("该漫画暂无可阅读章节")
                    return
                }
                let progress = store.progress(for: resolvedManga) ?? store.progress(for: manga)
                let targetChapter: MangaChapter
                let targetPageIndex: Int

                if let progress,
                   !progress.isCompleted,
                   let resolved = store.resolveResumeTarget(
                       for: resolvedManga,
                       fallbackManga: manga,
                       chapters: chapters,
                       allowRestartWhenCompleted: true
                   ) {
                    targetChapter = resolved.chapter
                    targetPageIndex = resolved.pageIndex
                } else if let histChapterID = item.lastChapterID,
                          let match = chapters.first(where: { $0.id == histChapterID }) {
                    targetChapter = match
                    targetPageIndex = item.lastPageIndex ?? 0
                } else {
                    targetChapter = firstChapter
                    targetPageIndex = 0
                }

                readerLaunchPayload = HistoryReaderLaunchPayload(
                    manga: resolvedManga,
                    chapters: chapters,
                    initialChapter: targetChapter,
                    initialPageIndex: targetPageIndex
                )
            }

            guard let adapter else {
                launch(resolvedManga: manga, chapters: offlineChapters)
                return
            }

            do {
                let detail = try await adapter.fetchDetail(for: manga)
                guard !Task.isCancelled else { return }
                store.syncBookshelfChapterMeta(
                    manga: detail.manga,
                    chapters: detail.chapters,
                    markUnreadIfIncreased: false
                )
                store.recordHistoryView(manga: detail.manga)
                launch(resolvedManga: detail.manga, chapters: detail.chapters)
            } catch {
                guard !Task.isCancelled else { return }
                if !offlineChapters.isEmpty {
                    showHud("网络不可用，已切入离线缓存")
                    launch(resolvedManga: manga, chapters: offlineChapters)
                } else {
                    showHud("章节载入失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func showHud(_ message: String, duration: TimeInterval = 2.0) {
        hudDismissTask?.cancel()
        hudMessage = message
        hudDismissTask = Task { @MainActor in
            let nanos = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                hudMessage = nil
            }
        }
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: style).impactOccurred()
        #endif
    }
}
