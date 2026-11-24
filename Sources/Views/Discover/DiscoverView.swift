import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 在线图源发现页（支持常驻全源/单源搜索入口、分类筛选与双模式分页：经典单页翻阅 + 瀑布流滚动追加）
public struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore

    @State private var mangas: [Manga] = []
    @State private var selectedCategoryID = ""
    @State private var currentPage = 1
    @State private var totalPages: Int?
    @State private var canLoadMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?
    @State private var requestGeneration = 0
    @State private var loadTask: Task<Void, Never>?

    // 分页跳页状态
    @State private var showingJumpSheet = false
    @State private var jumpTargetPageInput = "1"
    @State private var noticeMessage: String?
    @State private var showNoticeBanner = false
    @State private var noticeDismissTask: Task<Void, Never>?

    private var activeSource: MangaSourceConfig? {
        store.enabledSources.first(where: { $0.id == store.selectedSourceID })
            ?? store.enabledSources.first
    }

    private var activeCategories: [MangaCategoryOption] {
        guard let sourceID = activeSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            return []
        }
        return adapter.exploreCategories
    }

    /// 从当前已加载漫画中提取高频标签，供搜索页快捷标签使用
    private var suggestedSearchTags: [String] {
        var counts: [String: Int] = [:]
        for manga in mangas {
            for rawTag in manga.tags {
                let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty,
                      tag.count <= 12,
                      !MangaSerialStatusHelper.isStatusTag(tag),
                      tag != "绅士漫画",
                      tag != "禁漫单行本" else {
                    continue
                }
                counts[tag, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(8)
            .map(\.key)
    }

    private var currentSearchRoute: MangaSearchRoute {
        MangaSearchRoute(
            initialSourceID: activeSource?.id,
            suggestedTags: suggestedSearchTags
        )
    }

    private var searchDestinationView: some View {
        MangaSearchView(
            initialQuery: currentSearchRoute.initialQuery,
            initialSourceID: currentSearchRoute.initialSourceID,
            suggestedTags: currentSearchRoute.suggestedTags,
            autoSubmit: currentSearchRoute.autoSubmit
        )
    }

    /// 当前图源每页估算获取条数描述
    private var sourcePageSizeDescription: String {
        switch activeSource?.kind {
        case .jm, .wnacg:
            return "\(UniformPaginator.defaultPageSize) 部/页"
        default:
            return ""
        }
    }

    private var paginationFooterInfoText: String {
        var parts: [String] = []
        if !sourcePageSizeDescription.isEmpty {
            parts.append(sourcePageSizeDescription)
        }
        if let totalPages {
            parts.append("共 \(totalPages) 页")
            parts.append("点击跳页")
        } else {
            parts.append("点击页码快速跳页")
        }
        return parts.joined(separator: " · ")
    }

    public var body: some View {
        CompatNavigationContainer {
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    discoverHeaderBar(scrollProxy: scrollProxy)

                    discoverSearchEntryBar

                    if store.enabledSources.count > 1 {
                        sourcePickerBar
                    }

                    if !activeCategories.isEmpty {
                        categoryPickerBar(scrollProxy: scrollProxy)
                    }

                    if showNoticeBanner, let noticeMessage {
                        noticeBannerView(noticeMessage)
                    }

                    Group {
                        if isLoading && mangas.isEmpty {
                            ProgressView("正在拉取第 \(currentPage) 页...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let errorMessage, mangas.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "wifi.exclamationmark")
                                    .font(.largeTitle)
                                    .foregroundStyle(.orange)
                                Text("加载在线源失败")
                                    .font(.headline)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                Button("重试") {
                                    Task { await reload(scrollProxy: scrollProxy) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if mangas.isEmpty {
                            VStack(spacing: 14) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 44))
                                    .foregroundStyle(.secondary)
                                Text("当前页暂无漫画")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)

                                if currentPage > 1 {
                                    Button {
                                        Task { await switchToPage(1, scrollProxy: scrollProxy) }
                                    } label: {
                                        Label("返回第 1 页", systemImage: "arrow.counterclockwise")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                // 顶部平滑滚动锚点
                                Color.clear
                                    .frame(height: 0)
                                    .id("discover_top_anchor")

                                DiscoverLayoutCollectionView(
                                    style: store.discoverLayoutStyle,
                                    mangas: mangas,
                                    store: store
                                ) { manga in
                                    if store.discoverPaginationMode == .infiniteScroll,
                                       manga.id == mangas.last?.id,
                                       canLoadMore,
                                       !isLoadingMore {
                                        Task { await loadMore() }
                                    }
                                }
                                .animation(.easeInOut(duration: 0.22), value: store.discoverLayoutStyle)

                                // 分页控制器区（无论按页还是瀑布流均提供完整分页操作）
                                paginationBar(scrollProxy: scrollProxy)
                            }
                            .refreshable {
                                await reload(scrollProxy: scrollProxy)
                            }
                        }
                    }
                }
                .navigationTitle(activeSource?.name ?? "发现")
                .navigationBarTitleDisplayMode(.inline)
                .compatNavigationBarHidden(true)
                .onChange(of: store.selectedSourceID) { _ in
                    selectedCategoryID = activeCategories.first?.id ?? ""
                    scheduleReload(scrollProxy: scrollProxy)
                }
                .task {
                    if store.selectedSourceID.isEmpty, let first = store.enabledSources.first {
                        store.selectedSourceID = first.id
                    }
                    if selectedCategoryID.isEmpty {
                        selectedCategoryID = activeCategories.first?.id ?? ""
                    }
                    if mangas.isEmpty {
                        await reload(scrollProxy: scrollProxy)
                    }
                }
                .onDisappear {
                    noticeDismissTask?.cancel()
                }
                .sheet(isPresented: $showingJumpSheet) {
                    jumpPageSheet(scrollProxy: scrollProxy)
                }
            }
        }
    }

    // MARK: - Subviews

    private func discoverHeaderBar(scrollProxy: ScrollViewProxy) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(activeSource?.name ?? "发现")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                // 顶部常驻搜索按钮（滚动至页面深处时亦可随时搜索）
                NavigationLink(destination: searchDestinationView) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("搜索漫画")

                // 顶部快速跳页胶囊
                Button {
                    jumpTargetPageInput = "\(currentPage)"
                    showingJumpSheet = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "number.square")
                            .font(.callout)
                        Text("P.\(currentPage)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("当前第 \(currentPage) 页，点击跳页")

                // 视图排布与分页模式切换菜单
                Menu {
                    Section("视图排布") {
                        ForEach(DiscoverLayoutStyle.allCases) { style in
                            Button {
                                guard store.discoverLayoutStyle != style else { return }
                                withAnimation(.easeInOut(duration: 0.22)) {
                                    store.discoverLayoutStyle = style
                                }
                                triggerHaptic()
                                showNotice("已切换：\(style.displayName)")
                            } label: {
                                Label {
                                    Text(style.displayName)
                                } icon: {
                                    Image(systemName: store.discoverLayoutStyle == style ? "checkmark" : style.iconName)
                                }
                            }
                        }
                    }

                    Section("浏览与分页模式") {
                        ForEach(DiscoverPaginationMode.allCases) { mode in
                            Button {
                                store.discoverPaginationMode = mode
                            } label: {
                                HStack {
                                    Text(mode.displayName)
                                    if store.discoverPaginationMode == mode {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }

                    Section("快速分页跳转") {
                        Button {
                            scheduleReload(scrollProxy: scrollProxy)
                        } label: {
                            Label("跳转到第 1 页", systemImage: "arrow.up.to.line")
                        }
                        .disabled(currentPage == 1)

                        Button {
                            jumpTargetPageInput = "\(currentPage)"
                            showingJumpSheet = true
                        } label: {
                            Label("跳转到指定页...", systemImage: "arrow.triangle.turn.up.right.diamond")
                        }
                    }
                } label: {
                    Image(systemName: store.discoverLayoutStyle.iconName)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .accessibilityLabel("视图排布与分页模式，当前为\(store.discoverLayoutStyle.displayName)")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var discoverSearchEntryBar: some View {
        NavigationLink(destination: searchDestinationView) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                Text(
                    activeSource.map { "在「\($0.name)」或全部源搜索漫画..." }
                        ?? "搜索漫画名、作者、标签或编号..."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer()

                if store.enabledSources.count > 1 {
                    Text("全源")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("搜索在线漫画")
    }

    private var sourcePickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.enabledSources) { src in
                    let isSelected = src.id == activeSource?.id
                    Button {
                        store.selectedSourceID = src.id
                    } label: {
                        Text(src.name)
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? Color.accentColor : Color(.secondarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private func categoryPickerBar(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeCategories) { cat in
                    let current = selectedCategoryID.isEmpty ? (activeCategories.first?.id ?? "") : selectedCategoryID
                    let isSelected = cat.id == current
                    Button {
                        selectedCategoryID = cat.id
                        scheduleReload(scrollProxy: scrollProxy)
                    } label: {
                        Text(cat.title)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func noticeBannerView(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.bold))
            Text(text)
                .font(.caption.weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.15))
        .foregroundStyle(.orange)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Pagination Bar

    @ViewBuilder
    private func paginationBar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            if isLoadingMore {
                ProgressView("正在载入下一页...")
                    .padding(.vertical, 8)
            }

            // 核心翻页按键条：[上一页] [第 X 页] [下一页]
            HStack(spacing: 12) {
                // 上一页按钮
                Button {
                    Task { await switchToPage(currentPage - 1, scrollProxy: scrollProxy) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("上一页")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        currentPage > 1 ? Color(.secondarySystemFill) : Color(.tertiarySystemFill).opacity(0.4),
                        in: Capsule()
                    )
                    .foregroundStyle(currentPage > 1 ? Color.primary : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(currentPage <= 1 || isLoading || isLoadingMore)

                // 当前页码展示与点击跳页弹窗
                Button {
                    jumpTargetPageInput = "\(currentPage)"
                    showingJumpSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Text("第 \(currentPage) 页")
                            .font(.subheadline.weight(.bold))
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2.weight(.bold))
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                // 下一页按钮
                Button {
                    if store.discoverPaginationMode == .pageByPage {
                        Task { await switchToPage(currentPage + 1, scrollProxy: scrollProxy) }
                    } else {
                        Task { await loadMore() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(store.discoverPaginationMode == .pageByPage ? "下一页" : "加载更多")
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        canLoadMore ? Color.accentColor : Color(.tertiarySystemFill).opacity(0.4),
                        in: Capsule()
                    )
                    .foregroundStyle(canLoadMore ? Color.white : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canLoadMore || isLoading || isLoadingMore)
            }

            // 模式信息与单页规格脚标
            HStack(spacing: 8) {
                Text(store.discoverPaginationMode.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))

                Text(paginationFooterInfoText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 6)

                // 回到顶部快捷操作
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("discover_top_anchor", anchor: .top)
                    }
                    triggerHaptic()
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up")
                        Text("回顶部")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 16)
    }

    // MARK: - Jump Page Sheet

    private func jumpPageSheet(scrollProxy: ScrollViewProxy) -> some View {
        CompatNavigationContainer {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("跳转到指定页")
                        .font(.title3.weight(.bold))
                    let totalSuffix = totalPages.map { " · 共 \($0) 页" } ?? ""
                    let sizeSuffix = sourcePageSizeDescription.isEmpty ? "" : " (\(sourcePageSizeDescription))"
                    Text("当前处于第 \(currentPage) 页\(totalSuffix) · \(activeSource?.name ?? "在线图源")\(sizeSuffix)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 10)

                // 输入框与微调步进器
                HStack(spacing: 14) {
                    Button {
                        if let num = Int(jumpTargetPageInput), num > 1 {
                            jumpTargetPageInput = "\(num - 1)"
                            triggerHaptic()
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Text("第")
                            .foregroundStyle(.secondary)
                        TextField("页码", text: $jumpTargetPageInput)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.center)
                            .font(.title2.weight(.bold).monospacedDigit())
                            .frame(width: 80)
                        Text("页")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                    Button {
                        let num = Int(jumpTargetPageInput) ?? currentPage
                        jumpTargetPageInput = "\(num + 1)"
                        triggerHaptic()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                // 快速跳页步进标签按钮
                VStack(alignment: .leading, spacing: 10) {
                    Text("快速步进")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        quickStepButton(delta: -10)
                        quickStepButton(delta: -5)
                        quickStepButton(delta: -1)
                        quickStepButton(delta: 1)
                        quickStepButton(delta: 5)
                        quickStepButton(delta: 10)
                    }

                    HStack(spacing: 8) {
                        Button("回到第 1 页") {
                            jumpTargetPageInput = "1"
                            triggerHaptic()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.medium))

                        Button("当前页 (\(currentPage))") {
                            jumpTargetPageInput = "\(currentPage)"
                            triggerHaptic()
                        }
                        .buttonStyle(.bordered)
                        .font(.caption.weight(.medium))

                        if let totalPages, totalPages > 1 {
                            Button("末页 (\(totalPages))") {
                                jumpTargetPageInput = "\(totalPages)"
                                triggerHaptic()
                            }
                            .buttonStyle(.bordered)
                            .font(.caption.weight(.medium))
                        }
                    }
                }
                .padding(.horizontal, 20)

                Spacer()

                // 操作按钮
                VStack(spacing: 12) {
                    Button {
                        let target = Int(jumpTargetPageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? currentPage
                        showingJumpSheet = false
                        Task {
                            await switchToPage(max(1, target), scrollProxy: scrollProxy)
                        }
                    } label: {
                        Text("立即跳转至该页")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button("取消") {
                        showingJumpSheet = false
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .compatPresentationDetentsHeight(380)
            .compatPresentationDragIndicatorVisible()
        }
    }

    private func quickStepButton(delta: Int) -> some View {
        Button("\(delta > 0 ? "+\(delta)" : "\(delta)")") {
            let currentNum = Int(jumpTargetPageInput) ?? currentPage
            let updated = max(1, currentNum + delta)
            jumpTargetPageInput = "\(updated)"
            triggerHaptic()
        }
        .buttonStyle(.bordered)
        .font(.caption.weight(.medium))
    }

    // MARK: - Core Pagination Logic

    private func scheduleReload(scrollProxy: ScrollViewProxy? = nil) {
        loadTask?.cancel()
        loadTask = Task {
            await reload(scrollProxy: scrollProxy)
        }
    }

    private func reload(scrollProxy: ScrollViewProxy? = nil) async {
        guard let source = activeSource,
              let adapter = store.adapter(for: source.id) else {
            mangas = []
            totalPages = nil
            canLoadMore = false
            errorMessage = "当前没有启用的在线图源，请先在「设置 → 在线源」启用或添加。"
            return
        }

        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        currentPage = 1
        totalPages = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            await adapter.resetPaginationCache(scope: .explore)
            let result = try await fetchPagePaged(adapter: adapter, page: 1)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            mangas = result.items
            let hasMore = resolveHasMore(result: result, targetPage: 1, source: source)
            canLoadMore = hasMore
            totalPages = result.totalPages ?? (!hasMore && !result.items.isEmpty ? 1 : nil)
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy?.scrollTo("discover_top_anchor", anchor: .top)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            mangas = []
            totalPages = nil
            canLoadMore = false
        }
    }

    private func switchToPage(_ targetPage: Int, scrollProxy: ScrollViewProxy? = nil) async {
        guard targetPage >= 1, !isLoading else { return }
        guard let source = activeSource,
              let adapter = store.adapter(for: source.id) else {
            return
        }

        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        errorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let result = try await fetchPagePaged(adapter: adapter, page: targetPage)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if result.items.isEmpty {
                showNotice("第 \(targetPage) 页暂无更多漫画")
                if targetPage > currentPage {
                    canLoadMore = false
                    if targetPage == currentPage + 1 {
                        totalPages = totalPages ?? currentPage
                    }
                }
                return
            }

            mangas = result.items
            currentPage = targetPage
            let hasMore = resolveHasMore(result: result, targetPage: targetPage, source: source)
            canLoadMore = hasMore
            if let resolvedTotal = result.totalPages {
                totalPages = max(resolvedTotal, targetPage)
            } else if !hasMore {
                totalPages = targetPage
            }

            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy?.scrollTo("discover_top_anchor", anchor: .top)
            }
            triggerHaptic()
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            showNotice("加载第 \(targetPage) 页失败: \(error.localizedDescription)")
        }
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore,
              let source = activeSource,
              let adapter = store.adapter(for: source.id) else {
            return
        }

        let generation = requestGeneration
        isLoadingMore = true
        defer {
            if generation == requestGeneration {
                isLoadingMore = false
            }
        }
        let nextPage = currentPage + 1

        do {
            let result = try await fetchPagePaged(adapter: adapter, page: nextPage)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if result.items.isEmpty {
                canLoadMore = false
                totalPages = totalPages ?? currentPage
                showNotice("已到底部，无更多漫画")
                return
            }
            var seen = Set(mangas.map(\.compositeKey))
            let uniqueNew = result.items.filter { seen.insert($0.compositeKey).inserted }
            if uniqueNew.isEmpty {
                canLoadMore = false
                totalPages = totalPages ?? currentPage
            } else {
                mangas.append(contentsOf: uniqueNew)
                currentPage = nextPage
                let hasMore = resolveHasMore(result: result, targetPage: nextPage, source: source)
                canLoadMore = hasMore
                if let resolvedTotal = result.totalPages {
                    totalPages = max(resolvedTotal, nextPage)
                } else if !hasMore {
                    totalPages = nextPage
                }
                triggerHaptic()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            canLoadMore = false
            showNotice("加载下一页出错: \(error.localizedDescription)")
        }
    }

    private func resolveHasMore(
        result: MangaPagedResult,
        targetPage: Int,
        source: MangaSourceConfig
    ) -> Bool {
        if let hasMore = result.hasMore {
            return hasMore
        }
        if let total = result.totalPages {
            return targetPage < total && !result.items.isEmpty
        }
        return hasMorePages(fetchedCount: result.items.count, source: source)
    }

    private func hasMorePages(fetchedCount: Int, source: MangaSourceConfig) -> Bool {
        switch source.kind {
        case .demo:
            return false
        case .jm, .wnacg:
            return fetchedCount >= UniformPaginator.defaultPageSize
        case .genericJSON:
            return fetchedCount > 0
        }
    }

    private func fetchPagePaged(adapter: any MangaSourceProtocol, page: Int) async throws -> MangaPagedResult {
        let category = selectedCategoryID.isEmpty ? (adapter.exploreCategories.first?.id ?? "") : selectedCategoryID
        if category.isEmpty {
            return try await adapter.fetchPopularPaged(page: page)
        }
        return try await adapter.fetchPopularPaged(category: category, page: page)
    }

    private func showNotice(_ text: String) {
        noticeDismissTask?.cancel()
        noticeMessage = text
        withAnimation { showNoticeBanner = true }
        noticeDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { showNoticeBanner = false }
        }
    }

    private func triggerHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        #endif
    }
}
