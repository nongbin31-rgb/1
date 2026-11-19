import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 在线图源发现与搜索页（支持双模式分页：经典单页翻阅 + 瀑布流滚动追加，集成上一页/下一页/指定页快速跳转）
public struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore

    @State private var mangas: [Manga] = []
    @State private var searchQuery = ""
    @State private var selectedCategoryID = ""
    @State private var currentPage = 1
    @State private var canLoadMore = false
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var errorMessage: String?

    // 分页跳页状态
    @State private var showingJumpSheet = false
    @State private var jumpTargetPageInput = "1"
    @State private var noticeMessage: String?
    @State private var showNoticeBanner = false

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 14)
    ]

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

    /// 当前图源每页估算获取条数描述
    private var sourcePageSizeDescription: String {
        switch activeSource?.kind {
        case .jm:
            return "80 部/页"
        case .wnacg:
            return "12 部/页"
        default:
            return ""
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    if store.enabledSources.count > 1 {
                        sourcePickerBar
                    }

                    if !activeCategories.isEmpty && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        categoryPickerBar
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

                                LazyVGrid(columns: columns, spacing: 18) {
                                    ForEach(mangas) { manga in
                                        NavigationLink(value: manga) {
                                            MangaGridCard(
                                                manga: manga,
                                                progress: store.progress(for: manga)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .onAppear {
                                            if store.discoverPaginationMode == .infiniteScroll,
                                               manga.id == mangas.last?.id,
                                               canLoadMore,
                                               !isLoadingMore {
                                                Task { await loadMore() }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)

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
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: $searchQuery, prompt: "在当前在线源搜索漫画")
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        // 顶部快速跳页胶囊
                        Button {
                            jumpTargetPageInput = "\(currentPage)"
                            showingJumpSheet = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "number.square")
                                Text("P.\(currentPage)")
                                    .font(.caption.weight(.bold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(.secondarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        // 浏览与分页模式切换菜单
                        Menu {
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
                                    Task { await switchToPage(1, scrollProxy: scrollProxy) }
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
                            Image(systemName: store.discoverPaginationMode.iconName)
                                .font(.subheadline)
                        }
                    }
                }
                .onSubmit(of: .search) {
                    Task { await reload(scrollProxy: scrollProxy) }
                }
                .onChange(of: searchQuery) { newValue in
                    if newValue.isEmpty {
                        Task { await reload(scrollProxy: scrollProxy) }
                    }
                }
                .onChange(of: store.selectedSourceID) { _ in
                    selectedCategoryID = activeCategories.first?.id ?? ""
                    Task { await reload(scrollProxy: scrollProxy) }
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
                .sheet(isPresented: $showingJumpSheet) {
                    jumpPageSheet(scrollProxy: scrollProxy)
                }
            }
            .navigationDestination(for: Manga.self) { manga in
                MangaDetailView(manga: manga)
            }
        }
    }

    // MARK: - Subviews

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

    private var categoryPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(activeCategories) { cat in
                    let current = selectedCategoryID.isEmpty ? (activeCategories.first?.id ?? "") : selectedCategoryID
                    let isSelected = cat.id == current
                    Button {
                        selectedCategoryID = cat.id
                        Task { await reload() }
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

                if !sourcePageSizeDescription.isEmpty {
                    Text(sourcePageSizeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("· 点击页码快速跳页")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

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
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("跳转到指定页")
                        .font(.title3.weight(.bold))
                    Text("当前处于第 \(currentPage) 页 · \(activeSource?.name ?? "在线图源") (\(sourcePageSizeDescription))")
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
            .presentationDetents([.height(380)])
            .presentationDragIndicator(.visible)
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

    private func reload(scrollProxy: ScrollViewProxy? = nil) async {
        guard let sourceID = activeSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            mangas = []
            canLoadMore = false
            errorMessage = "当前没有启用的在线图源，请先在「在线源」页启用或添加。"
            return
        }

        isLoading = true
        errorMessage = nil
        currentPage = 1
        defer { isLoading = false }

        do {
            let fetched = try await fetchPage(adapter: adapter, page: 1)
            mangas = fetched
            canLoadMore = !fetched.isEmpty && activeSource?.kind != .demo
            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy?.scrollTo("discover_top_anchor", anchor: .top)
            }
        } catch {
            errorMessage = error.localizedDescription
            mangas = []
            canLoadMore = false
        }
    }

    private func switchToPage(_ targetPage: Int, scrollProxy: ScrollViewProxy? = nil) async {
        guard targetPage >= 1, !isLoading else { return }
        guard let sourceID = activeSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let fetched = try await fetchPage(adapter: adapter, page: targetPage)
            if fetched.isEmpty {
                showNotice("第 \(targetPage) 页暂无更多漫画")
                if targetPage > currentPage {
                    canLoadMore = false
                }
                return
            }

            mangas = fetched
            currentPage = targetPage
            canLoadMore = !fetched.isEmpty && activeSource?.kind != .demo

            withAnimation(.easeInOut(duration: 0.25)) {
                scrollProxy?.scrollTo("discover_top_anchor", anchor: .top)
            }
            triggerHaptic()
        } catch {
            showNotice("加载第 \(targetPage) 页失败: \(error.localizedDescription)")
        }
    }

    private func loadMore() async {
        guard !isLoading, !isLoadingMore, canLoadMore,
              let sourceID = activeSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }
        let nextPage = currentPage + 1

        do {
            let fetched = try await fetchPage(adapter: adapter, page: nextPage)
            if fetched.isEmpty {
                canLoadMore = false
                showNotice("已到底部，无更多漫画")
                return
            }
            var seen = Set(mangas.map(\.compositeKey))
            let uniqueNew = fetched.filter { seen.insert($0.compositeKey).inserted }
            if uniqueNew.isEmpty {
                canLoadMore = false
            } else {
                mangas.append(contentsOf: uniqueNew)
                currentPage = nextPage
                triggerHaptic()
            }
        } catch {
            canLoadMore = false
            showNotice("加载下一页出错: \(error.localizedDescription)")
        }
    }

    private func fetchPage(adapter: any MangaSourceProtocol, page: Int) async throws -> [Manga] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return try await adapter.search(query: trimmed, page: page)
        }
        let category = selectedCategoryID.isEmpty ? (adapter.exploreCategories.first?.id ?? "") : selectedCategoryID
        if category.isEmpty {
            return try await adapter.fetchPopular(page: page)
        }
        return try await adapter.fetchPopular(category: category, page: page)
    }

    private func showNotice(_ text: String) {
        noticeMessage = text
        withAnimation { showNoticeBanner = true }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
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
