import SwiftUI

/// 在线收藏书架（4 套原生高阶视图 + 真实数据排序 + 批量管理 + 撤销恢复 + 一键续读直达阅读器）
public struct BookshelfView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTab: AppTab

    @State private var searchText = ""
    @State private var focusFilter: BookshelfFocusFilter = .all
    @State private var selectedGroupFilter: BookshelfGroupFilter = .all

    // 自定义分组管理与选择弹窗状态
    @State private var showingGroupManagerSheet = false
    @State private var groupPickerContext: BookshelfGroupPickerContext?
    @State private var showingLocalFileImporter = false

    // 批量管理多选状态
    @State private var isEditing = false
    @State private var selectedKeys: Set<String> = []

    // 撤销快照与顶部轻提示 HUD
    @State private var lastRemovedSnapshot: [AppStore.BookshelfRemovedItem] = []
    @State private var hudMessage: String?
    @State private var hudShowsUndo = false
    @State private var hudDismissTask: Task<Void, Never>?

    // 一键续读直达阅读器状态
    @State private var quickLaunchingMangaKey: String?
    @State private var quickLaunchTask: Task<Void, Never>?
    @State private var readerLaunchPayload: BookshelfReaderLaunchPayload?

    // 书架章节更新检查状态
    @State private var isCheckingUpdates = false
    @State private var backgroundSyncTask: Task<Void, Never>?

    private var searchedBooks: [Manga] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return store.bookshelf }
        return store.bookshelf.filter { manga in
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

    private var sortedBooks: [Manga] {
        let indexed = Array(searchedBooks.enumerated())
        switch store.bookshelfSortOrder {
        case .recentRead:
            return indexed.sorted { lhs, rhs in
                let lp = store.progress(for: lhs.element)
                let rp = store.progress(for: rhs.element)
                switch (lp?.updatedAt, rp?.updatedAt) {
                case let (lDate?, rDate?):
                    if lDate != rDate { return lDate > rDate }
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    break
                }
                let lAdded = store.bookshelfAddedDate(for: lhs.element)
                let rAdded = store.bookshelfAddedDate(for: rhs.element)
                switch (lAdded, rAdded) {
                case let (la?, ra?) where la != ra:
                    return la > ra
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)

        case .recentAdded:
            return indexed.sorted { lhs, rhs in
                let lAdded = store.bookshelfAddedDate(for: lhs.element)
                let rAdded = store.bookshelfAddedDate(for: rhs.element)
                switch (lAdded, rAdded) {
                case let (la?, ra?) where la != ra:
                    return la > ra
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }.map(\.element)

        case .progress:
            return indexed.sorted { lhs, rhs in
                let lp = store.progress(for: lhs.element)
                let rp = store.progress(for: rhs.element)
                let lScore = progressSortScore(lp)
                let rScore = progressSortScore(rp)
                if lScore != rScore {
                    return lScore > rScore
                }
                if let lPage = lp?.pageIndex, let rPage = rp?.pageIndex, lPage != rPage {
                    return lPage > rPage
                }
                if let lDate = lp?.updatedAt, let rDate = rp?.updatedAt, lDate != rDate {
                    return lDate > rDate
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    private var groupFilteredBooks: [Manga] {
        switch selectedGroupFilter {
        case .all:
            return sortedBooks
        case .ungrouped:
            return sortedBooks.filter { store.groupIDs(for: $0).isEmpty }
        case .group(let groupID):
            return sortedBooks.filter { store.groupIDs(for: $0).contains(groupID) }
        }
    }

    private var displayedBooks: [Manga] {
        guard store.bookshelfLayoutStyle == .focusShelf else {
            return groupFilteredBooks
        }
        return groupFilteredBooks.filter { manga in
            focusFilter.matches(manga, progress: store.progress(for: manga))
        }
    }

    private var isFilteringGroup: Bool {
        selectedGroupFilter != .all
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleKeySet: Set<String> {
        Set(displayedBooks.map(\.compositeKey))
    }

    private var activeSelectedKeys: Set<String> {
        selectedKeys.intersection(visibleKeySet)
    }

    private var isAllVisibleSelected: Bool {
        !displayedBooks.isEmpty && activeSelectedKeys.count == displayedBooks.count
    }

    private var callbacks: BookshelfViewCallbacks {
        BookshelfViewCallbacks(
            onToggleSelect: toggleSelect(_:),
            onQuickResume: quickResume(_:),
            onManageGroups: { manga in
                groupPickerContext = .single(manga)
            },
            onMarkCompleted: markSingleCompleted(_:),
            onResetProgress: resetSingleProgress(_:),
            onRemoveSingle: removeSingle(_:)
        )
    }

    public var body: some View {
        CompatNavigationContainer {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    bookshelfHeaderBar

                    if !store.bookshelf.isEmpty {
                        bookshelfSearchBar

                        if !store.bookshelfGroups.isEmpty {
                            bookshelfGroupBar
                        }
                    }

                    Group {
                        if store.bookshelf.isEmpty {
                            emptyStateView
                        } else if sortedBooks.isEmpty {
                            emptySearchResultView
                        } else if groupFilteredBooks.isEmpty {
                            emptyGroupResultView
                        } else {
                            ScrollView(showsIndicators: store.bookshelfLayoutStyle != .readingTimeline) {
                                BookshelfLayoutCollectionView(
                                    style: store.bookshelfLayoutStyle,
                                    allBooks: isFilteringGroup ? groupFilteredBooks : store.bookshelf,
                                    sortedBooks: groupFilteredBooks,
                                    displayedBooks: displayedBooks,
                                    isSearching: isSearching || isFilteringGroup,
                                    isEditing: isEditing,
                                    selectedKeys: activeSelectedKeys,
                                    launchingMangaKey: quickLaunchingMangaKey,
                                    focusFilter: $focusFilter,
                                    store: store,
                                    callbacks: callbacks
                                )
                                .padding(.bottom, isEditing ? 78 : 8)
                            }
                            .refreshable {
                                await checkBookshelfUpdates(forceAll: false, silent: false)
                            }
                            .compatScrollIndicatorsHidden(store.bookshelfLayoutStyle == .readingTimeline)
                            .background(
                                (store.bookshelfLayoutStyle == .readingTimeline
                                    ? Color(uiColor: .systemGroupedBackground)
                                    : Color.clear)
                                .ignoresSafeArea(edges: .bottom)
                            )
                            .compatScrollDismissesKeyboard()
                        }
                    }
                    .overlay(alignment: .top) {
                        if let hudMessage {
                            bookshelfHudBanner(message: hudMessage, showsUndo: hudShowsUndo)
                                .padding(.top, 10)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.32, dampingFraction: 0.84), value: hudMessage)
                }

                // 底部悬浮毛玻璃批量操作条（保留系统 TabBar 零兼容坑）
                if isEditing && !store.bookshelf.isEmpty {
                    batchActionBar
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isEditing)
            .navigationTitle("书架")
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
            .onChange(of: store.bookshelf.count) { count in
                if count == 0 && isEditing {
                    exitEditMode()
                } else {
                    selectedKeys = selectedKeys.intersection(Set(store.bookshelf.map(\.compositeKey)))
                }
            }
            .onChange(of: store.bookshelfLayoutStyle) { _ in
                if isEditing {
                    selectedKeys = selectedKeys.intersection(visibleKeySet)
                }
            }
            .onChange(of: focusFilter) { _ in
                if isEditing {
                    selectedKeys = selectedKeys.intersection(visibleKeySet)
                }
            }
            .onChange(of: selectedGroupFilter) { _ in
                if isEditing {
                    selectedKeys = selectedKeys.intersection(visibleKeySet)
                }
            }
            .onChange(of: store.bookshelfGroups) { groups in
                if case .group(let activeID) = selectedGroupFilter,
                   !groups.contains(where: { $0.id == activeID }) {
                    selectedGroupFilter = .all
                }
                if groups.isEmpty {
                    selectedGroupFilter = .all
                }
            }
            .sheet(isPresented: $showingGroupManagerSheet) {
                BookshelfGroupManagerSheet()
                    .environmentObject(store)
            }
            .sheet(item: $groupPickerContext) { ctx in
                BookshelfGroupPickerSheet(context: ctx) { message in
                    if case .batch = ctx {
                        exitEditMode()
                    }
                    showHud(message)
                }
                .environmentObject(store)
            }
            .background {
                Color.clear
                    .sheet(isPresented: $showingLocalFileImporter) {
                        LocalMangaDocumentPicker(
                            onPick: { urls in
                                showingLocalFileImporter = false
                                guard !urls.isEmpty else { return }
                                Task {
                                    showHud("正在导入 \(urls.count) 个本地文件...", duration: 4.0)
                                    let outcome = await store.importLocalMangaFiles(urls: urls)
                                    if !outcome.imported.isEmpty {
                                        BookshelfHaptics.medium()
                                        if outcome.failedNames.isEmpty {
                                            showHud("已导入 \(outcome.imported.count) 部本地漫画")
                                        } else {
                                            showHud("导入成功 \(outcome.imported.count) 部，失败 \(outcome.failedNames.count) 部", duration: 3.2)
                                        }
                                    } else if let firstError = outcome.failedNames.first {
                                        showHud("导入失败：\(firstError)", duration: 3.5)
                                    } else {
                                        showHud("未检测到可导入的漫画文件", duration: 2.5)
                                    }
                                }
                            },
                            onCancel: {
                                showingLocalFileImporter = false
                            }
                        )
                        .ignoresSafeArea()
                    }
            }
            .onAppear {
                scheduleSilentChapterSyncIfNeeded()
            }
            .onDisappear {
                hudDismissTask?.cancel()
                quickLaunchTask?.cancel()
                backgroundSyncTask?.cancel()
                quickLaunchingMangaKey = nil
            }
        }
    }

    // MARK: - Header Bar

    private var bookshelfHeaderBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if isEditing {
                Button {
                    toggleSelectAll()
                } label: {
                    Text(isAllVisibleSelected ? "取消全选" : "全选")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(displayedBooks.isEmpty)

                Spacer(minLength: 8)

                Text(activeSelectedKeys.isEmpty ? "选择漫画" : "已选 \(activeSelectedKeys.count) 本")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Button {
                    exitEditMode()
                } label: {
                    Text("完成")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("书架")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !store.bookshelf.isEmpty {
                        Text("\(store.bookshelf.count)本")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                    }
                }

                Spacer(minLength: 8)

                if !store.bookshelf.isEmpty {
                    Button {
                        enterEditMode()
                    } label: {
                        Text("选择")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("进入批量管理")
                }

                bookshelfOptionsMenu

                NavigationLink {
                    SettingsView(embeddedInNavigation: true)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 32, height: 32)
                        .background(Color(uiColor: .secondarySystemFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("打开设置")
            }
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var bookshelfOptionsMenu: some View {
        Menu {
            Section("书架视图排布") {
                ForEach(BookshelfLayoutStyle.allCases) { style in
                    Button {
                        guard store.bookshelfLayoutStyle != style else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            store.bookshelfLayoutStyle = style
                        }
                        BookshelfHaptics.light()
                        showHud("已切换：\(style.displayName)")
                    } label: {
                        Label {
                            Text(style.displayName)
                        } icon: {
                            Image(systemName: store.bookshelfLayoutStyle == style ? "checkmark" : style.iconName)
                        }
                    }
                }
            }

            Section("排序方式") {
                ForEach(BookshelfSortOrder.allCases) { order in
                    Button {
                        guard store.bookshelfSortOrder != order else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            store.bookshelfSortOrder = order
                        }
                        BookshelfHaptics.light()
                        showHud("排序：\(order.displayName)")
                    } label: {
                        Label {
                            Text(order.displayName)
                        } icon: {
                            Image(systemName: store.bookshelfSortOrder == order ? "checkmark" : order.iconName)
                        }
                    }
                }
            }

            Divider()

            Button {
                DispatchQueue.main.async {
                    showingLocalFileImporter = true
                }
            } label: {
                Label("导入本地漫画 (CBZ/ZIP/PDF/EPUB)", systemImage: "doc.badge.plus")
            }

            if !store.bookshelf.isEmpty {
                Button {
                    showingGroupManagerSheet = true
                } label: {
                    Label("管理书架分组", systemImage: "folder.badge.plus")
                }

                Button {
                    Task {
                        await checkBookshelfUpdates(forceAll: false, silent: false)
                    }
                } label: {
                    Label(
                        isCheckingUpdates ? "正在检查更新..." : "检查章节更新",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isCheckingUpdates)

                Button {
                    enterEditMode()
                } label: {
                    Label("批量管理", systemImage: "checkmark.circle")
                }
            }
        } label: {
            Image(systemName: store.bookshelfLayoutStyle.iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("切换书架视图与排序，当前为\(store.bookshelfLayoutStyle.displayName)")
    }

    // MARK: - Search Bar

    private var bookshelfSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            TextField("搜索收藏的漫画", text: $searchText)
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

    // MARK: - Custom Group Bar

    private var ungroupedBookCount: Int {
        sortedBooks.reduce(into: 0) { count, manga in
            if store.groupIDs(for: manga).isEmpty {
                count += 1
            }
        }
    }

    private func bookCount(in groupID: String) -> Int {
        sortedBooks.reduce(into: 0) { count, manga in
            if store.groupIDs(for: manga).contains(groupID) {
                count += 1
            }
        }
    }

    private var bookshelfGroupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                groupFilterChip(
                    title: "全部",
                    iconName: "square.grid.2x2",
                    count: sortedBooks.count,
                    isSelected: selectedGroupFilter == .all
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedGroupFilter = .all
                    }
                    BookshelfHaptics.light()
                }

                ForEach(store.bookshelfGroups) { group in
                    let isSelected = (selectedGroupFilter == .group(group.id))
                    let count = bookCount(in: group.id)

                    groupFilterChip(
                        title: group.name,
                        iconName: group.iconName,
                        count: count,
                        isSelected: isSelected
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGroupFilter = .group(group.id)
                        }
                        BookshelfHaptics.light()
                    }
                    .contextMenu {
                        Button {
                            showingGroupManagerSheet = true
                        } label: {
                            Label("重命名 / 管理分组", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.deleteBookshelfGroup(id: group.id)
                            BookshelfHaptics.medium()
                            showHud("已删除分组「\(group.name)」")
                        } label: {
                            Label("删除此分组", systemImage: "trash")
                        }
                    }
                }

                let ungroupedCount = ungroupedBookCount
                if ungroupedCount > 0 || selectedGroupFilter == .ungrouped {
                    groupFilterChip(
                        title: "未分组",
                        iconName: "tray",
                        count: ungroupedCount,
                        isSelected: selectedGroupFilter == .ungrouped
                    ) {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedGroupFilter = .ungrouped
                        }
                        BookshelfHaptics.light()
                    }
                }

                Button {
                    showingGroupManagerSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color(uiColor: .secondarySystemFill)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建或管理书架分组")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func groupFilterChip(
        title: String,
        iconName: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let fgColor: Color = isSelected ? .white : .primary
        let bgColor: Color = isSelected ? Color.accentColor : Color(uiColor: .secondarySystemFill)

        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .opacity(isSelected ? 0.9 : 0.65)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundColor(fgColor)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(bgColor))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Batch Action Floating Bar & HUD

    private var batchActionBar: some View {
        let count = activeSelectedKeys.count
        let disabled = count == 0

        return HStack(spacing: 0) {
            Button {
                batchAssignGroups()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .semibold))
                    Text("分组")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)

            Divider()
                .frame(height: 26)

            Button {
                batchMarkCompleted()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 16, weight: .semibold))
                    Text("标为已读")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)

            Divider()
                .frame(height: 26)

            Button {
                batchResetProgress()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .semibold))
                    Text("重置进度")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)

            Divider()
                .frame(height: 26)

            Button(role: .destructive) {
                batchRemoveSelected()
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                    Text(count > 0 ? "移出(\(count))" : "移出")
                        .font(.system(size: 11, weight: .bold))
                        .monospacedDigit()
                }
                .foregroundStyle(Color.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .liquidGlassRoundedRect(cornerRadius: 20, interactive: true)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func bookshelfHudBanner(message: String, showsUndo: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(showsUndo ? Color.orange : Color.green)
                .frame(width: 6, height: 6)

            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if showsUndo {
                Button {
                    undoLastRemove()
                } label: {
                    Text("撤销")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(red: 0.25, green: 0.65, blue: 1.0))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.84), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
    }

    // MARK: - Empty States

    private var emptySearchResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("未找到匹配的收藏漫画")
                .font(.headline)
            Text("试试其他关键词，或清空搜索条件。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                searchText = ""
            } label: {
                Text("清空搜索")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyGroupResultView: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("当前分组暂无漫画")
                .font(.headline)
            Text("长按任意漫画或点击右上角「选择」即可批量移入此分组。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedGroupFilter = .all
                }
            } label: {
                Text("查看全部收藏")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("书架还是空的")
                .font(.title3.weight(.semibold))
            Text("从在线图源发现并收藏漫画，即可在此快速追更与续读。")
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

            Button {
                showingLocalFileImporter = true
            } label: {
                Label("导入本地漫画 (CBZ / ZIP / PDF)", systemImage: "doc.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func progressSortScore(_ progress: ReadingProgress?) -> Double {
        guard let progress else { return -1.0 }
        if let ratio = progress.progressRatio {
            return ratio
        }
        return 0.01
    }

    private func enterEditMode() {
        selectedKeys.removeAll()
        isEditing = true
        BookshelfHaptics.light()
    }

    private func exitEditMode() {
        isEditing = false
        selectedKeys.removeAll()
    }

    private func toggleSelect(_ manga: Manga) {
        let key = manga.compositeKey
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
        } else {
            selectedKeys.insert(key)
        }
        BookshelfHaptics.light()
    }

    private func toggleSelectAll() {
        if isAllVisibleSelected {
            selectedKeys.removeAll()
        } else {
            selectedKeys = visibleKeySet
        }
        BookshelfHaptics.light()
    }

    private func batchAssignGroups() {
        let keys = activeSelectedKeys
        let targets = displayedBooks.filter { keys.contains($0.compositeKey) }
        guard !targets.isEmpty else { return }
        groupPickerContext = .batch(targets)
    }

    private func batchMarkCompleted() {
        let keys = activeSelectedKeys
        let targets = displayedBooks.filter { keys.contains($0.compositeKey) }
        guard !targets.isEmpty else { return }
        store.markAsCompleted(targets)
        BookshelfHaptics.medium()
        exitEditMode()
        showHud("已将 \(targets.count) 本标为已读")
    }

    private func batchResetProgress() {
        let keys = activeSelectedKeys
        let targets = displayedBooks.filter { keys.contains($0.compositeKey) }
        guard !targets.isEmpty else { return }
        store.resetProgress(for: targets)
        BookshelfHaptics.medium()
        exitEditMode()
        showHud("已重置 \(targets.count) 本阅读进度")
    }

    private func batchRemoveSelected() {
        let keys = activeSelectedKeys
        guard !keys.isEmpty else { return }
        let removed = store.removeFromBookshelf(keys: keys)
        guard !removed.isEmpty else { return }
        lastRemovedSnapshot = removed
        BookshelfHaptics.medium()
        exitEditMode()
        showHud("已移出 \(removed.count) 本漫画", showsUndo: true, duration: 3.8)
    }

    private func markSingleCompleted(_ manga: Manga) {
        store.markAsCompleted([manga])
        BookshelfHaptics.light()
        showHud("已标为已读")
    }

    private func resetSingleProgress(_ manga: Manga) {
        store.resetProgress(for: [manga])
        BookshelfHaptics.light()
        showHud("已重置阅读进度")
    }

    private func removeSingle(_ manga: Manga) {
        let removed = store.removeFromBookshelf(keys: [manga.compositeKey])
        guard !removed.isEmpty else { return }
        lastRemovedSnapshot = removed
        BookshelfHaptics.medium()
        showHud("已移出书架", showsUndo: true, duration: 3.8)
    }

    private func undoLastRemove() {
        guard !lastRemovedSnapshot.isEmpty else { return }
        let count = lastRemovedSnapshot.count
        store.restoreToBookshelf(lastRemovedSnapshot)
        lastRemovedSnapshot = []
        BookshelfHaptics.light()
        showHud("已恢复 \(count) 本漫画")
    }

    private func showHud(_ message: String, showsUndo: Bool = false, duration: TimeInterval = 2.2) {
        hudDismissTask?.cancel()
        hudMessage = message
        hudShowsUndo = showsUndo

        hudDismissTask = Task { @MainActor in
            let nanos = UInt64(duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                hudMessage = nil
                hudShowsUndo = false
            }
        }
    }

    /// 一键续读：异步拉取最新章节列表并直达 ReaderView，规避必须先点进详情页的两步跳转
    private func quickResume(_ manga: Manga) {
        guard quickLaunchingMangaKey != manga.compositeKey else { return }

        let adapter = store.adapter(for: manga.sourceID)
        let cachedOfflineChapters = OfflineDownloadManager.shared.offlineChapters(for: manga.compositeKey)

        guard adapter != nil || !cachedOfflineChapters.isEmpty else {
            showHud("未找到对应在线图源")
            return
        }

        quickLaunchTask?.cancel()
        quickLaunchingMangaKey = manga.compositeKey
        BookshelfHaptics.light()

        quickLaunchTask = Task { @MainActor in
            defer {
                if quickLaunchingMangaKey == manga.compositeKey {
                    quickLaunchingMangaKey = nil
                }
            }

            @MainActor
            func launchReader(resolvedManga: Manga, chapters: [MangaChapter]) {
                guard let target = store.resolveResumeTarget(
                    for: resolvedManga,
                    fallbackManga: manga,
                    chapters: chapters,
                    allowRestartWhenCompleted: true
                ) else {
                    showHud("该漫画暂无可阅读章节")
                    return
                }

                readerLaunchPayload = BookshelfReaderLaunchPayload(
                    manga: resolvedManga,
                    chapters: chapters,
                    initialChapter: target.chapter,
                    initialPageIndex: target.pageIndex
                )
            }

            guard let adapter else {
                launchReader(resolvedManga: manga, chapters: cachedOfflineChapters)
                return
            }

            do {
                let detail = try await adapter.fetchDetail(for: manga)
                guard !Task.isCancelled else { return }

                let resolvedManga = detail.manga
                let chapters = detail.chapters
                store.syncBookshelfChapterMeta(
                    manga: resolvedManga,
                    chapters: chapters,
                    markUnreadIfIncreased: false
                )
                launchReader(resolvedManga: resolvedManga, chapters: chapters)
            } catch {
                guard !Task.isCancelled else { return }
                let offlineChapters = OfflineDownloadManager.shared.offlineChapters(for: manga.compositeKey)
                if !offlineChapters.isEmpty {
                    showHud("网络不可用，已切入离线缓存章节", duration: 2.2)
                    launchReader(resolvedManga: manga, chapters: offlineChapters)
                } else {
                    showHud("章节载入失败：\(error.localizedDescription)", duration: 3.0)
                }
            }
        }
    }

    /// 进入书架时静默补齐空白话数，并在距上次自动追更满 6 小时后静默检查连载更新
    private func scheduleSilentChapterSyncIfNeeded() {
        guard !isCheckingUpdates else { return }
        let onlineBooks = store.bookshelf.filter { $0.sourceID != LocalMangaSource.sourceID }
        guard !onlineBooks.isEmpty else { return }

        let hasUnsynced = onlineBooks.contains { store.chapterMeta(for: $0) == nil }
        let shouldAutoCheckOngoing = store.shouldRunAutoBookshelfUpdateCheck() && onlineBooks.contains { manga in
            if let meta = store.chapterMeta(for: manga) {
                return meta.isOngoing || MangaSerialStatusHelper.isOngoingStatus(manga.statusText)
            }
            return true
        }
        guard hasUnsynced || shouldAutoCheckOngoing else { return }

        backgroundSyncTask?.cancel()
        backgroundSyncTask = Task {
            await checkBookshelfUpdates(forceAll: false, silent: true)
        }
    }

    /// 受控并发检查书架章节更新（下拉刷新 / 手动检查 / 静默补齐与定时追更）
    private func checkBookshelfUpdates(forceAll: Bool, silent: Bool) async {
        guard !isCheckingUpdates, !store.bookshelf.isEmpty else { return }

        let allBooks = store.bookshelf.filter { $0.sourceID != LocalMangaSource.sourceID }
        guard !allBooks.isEmpty else {
            if !silent {
                showHud("本地漫画无需检查在线更新")
            }
            return
        }
        let includeAutoOngoing = silent && store.shouldRunAutoBookshelfUpdateCheck()
        let targets: [Manga]
        if silent {
            targets = allBooks.filter { manga in
                guard let meta = store.chapterMeta(for: manga) else { return true }
                guard includeAutoOngoing else { return false }
                return meta.isOngoing || MangaSerialStatusHelper.isOngoingStatus(manga.statusText)
            }
        } else if forceAll {
            targets = allBooks
        } else {
            let prioritized = allBooks.filter { manga in
                guard let meta = store.chapterMeta(for: manga) else { return true }
                return meta.isOngoing || MangaSerialStatusHelper.isOngoingStatus(manga.statusText)
            }
            targets = prioritized.isEmpty ? allBooks : prioritized
        }

        guard !targets.isEmpty else {
            if !silent {
                showHud("书架已是最新")
            }
            return
        }

        isCheckingUpdates = true
        defer { isCheckingUpdates = false }

        if !silent {
            BookshelfHaptics.light()
        }

        // 预先在主线程构建待请求的 (manga, adapter) 列表，避免后台并发访问 MainActor 状态
        let workItems: [(manga: Manga, adapter: any MangaSourceProtocol)] = targets.compactMap { manga in
            guard let adapter = store.adapter(for: manga.sourceID) else { return nil }
            return (manga, adapter)
        }
        guard !workItems.isEmpty else { return }

        let maxConcurrency = silent ? 2 : 3
        var updatedCount = 0
        var syncedCount = 0
        var nextIndex = 0

        await withTaskGroup(of: (Manga, [MangaChapter])?.self) { group in
            let initialCount = min(maxConcurrency, workItems.count)
            for _ in 0..<initialCount {
                let item = workItems[nextIndex]
                nextIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    do {
                        let detail = try await item.adapter.fetchDetail(for: item.manga)
                        return (detail.manga, detail.chapters)
                    } catch {
                        return nil
                    }
                }
            }

            for await result in group {
                if let (resolvedManga, chapters) = result, !chapters.isEmpty {
                    syncedCount += 1
                    let didIncrease = store.syncBookshelfChapterMeta(
                        manga: resolvedManga,
                        chapters: chapters,
                        markUnreadIfIncreased: true
                    )
                    if didIncrease {
                        updatedCount += 1
                    }
                }

                if nextIndex < workItems.count, !Task.isCancelled {
                    let item = workItems[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        do {
                            let detail = try await item.adapter.fetchDetail(for: item.manga)
                            return (detail.manga, detail.chapters)
                        } catch {
                            return nil
                        }
                    }
                }
            }
        }

        if syncedCount > 0 && (!silent || includeAutoOngoing) {
            store.markAutoBookshelfUpdateChecked()
        }

        guard !silent, !Task.isCancelled else { return }
        if updatedCount > 0 {
            BookshelfHaptics.medium()
            showHud("发现 \(updatedCount) 部漫画有新章节", duration: 2.8)
        } else if syncedCount > 0 {
            showHud("书架已是最新（已同步 \(syncedCount) 部）", duration: 2.2)
        } else {
            showHud("检查更新失败，请检查网络", duration: 2.4)
        }
    }
}

private struct BookshelfReaderLaunchPayload: Identifiable {
    let id = UUID()
    let manga: Manga
    let chapters: [MangaChapter]
    let initialChapter: MangaChapter
    let initialPageIndex: Int?
}

struct MangaGridCard: View {
    let manga: Manga
    let progress: ReadingProgress?
    var sourceBadge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncMangaCoverView(
                urlString: manga.coverURL,
                headers: manga.coverHeaders,
                cornerRadius: 10
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(0.7, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if let sourceBadge, !sourceBadge.isEmpty {
                    Text(sourceBadge)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(.black.opacity(0.62), in: Capsule())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let progress {
                    Text(progress.isManuallyMarkedCompleted ? "已读" : "P\(progress.pageIndex + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }
            }
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

            Text(manga.title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .compatLineLimitReservesSpace(2, fallbackHeight: 38)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            HStack(spacing: 3) {
                if !manga.statusText.isEmpty {
                    if MangaSerialStatusHelper.isOngoingStatus(manga.statusText) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 4, height: 4)
                    } else if MangaSerialStatusHelper.isCompletedStatus(manga.statusText) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 4, height: 4)
                    }
                    Text(manga.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                ReadingProgressRingView(
                    hasProgress: progress != nil,
                    progress: progress?.progressRatio,
                    isExact: progress?.totalPages != nil
                )
            }
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 封面卡片底部微缩圆环阅读进度条
struct ReadingProgressRingView: View {
    let hasProgress: Bool
    let progress: Double?
    let isExact: Bool
    var size: CGFloat = 12
    var isOnDarkBackground: Bool = false

    var body: some View {
        let trackColor = isOnDarkBackground
            ? Color.white.opacity(0.32)
            : Color.secondary.opacity(0.26)
        let activeColor: Color = isOnDarkBackground
            ? (isExact ? Color.white.opacity(0.95) : Color.white.opacity(0.75))
            : (isExact ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.55))
        let strokeWidth: CGFloat = size <= 10 ? 1.4 : 1.6

        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: strokeWidth)

            if hasProgress {
                let ratio = min(1.0, max(0.05, progress ?? 0.05))
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(
                        activeColor,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard hasProgress else { return "未读" }
        if isExact, let progress {
            return "阅读进度 \(Int((progress * 100).rounded()))%"
        }
        return "已有阅读记录"
    }
}
