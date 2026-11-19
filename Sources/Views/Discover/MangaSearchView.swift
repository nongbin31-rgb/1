import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 发现页在线漫画搜索中心
/// 支持：单图源深度搜索（分页/跳页/瀑布流/排序）、全启用源并发聚合搜索、
/// 搜索历史持久化、热门标签推荐、JM/WNACG 编号直达。
public struct MangaSearchView: View {
    @EnvironmentObject private var store: AppStore

    public let initialQuery: String
    public let initialSourceID: String?
    public let suggestedTags: [String]
    public let autoSubmit: Bool

    @State private var queryText: String = ""
    @State private var submittedQuery: String = ""
    @State private var selectedScope: MangaSearchScope = .allEnabled
    @State private var selectedSort: MangaSearchSort = .latest
    @State private var hasInitialized = false
    @FocusState private var isSearchFieldFocused: Bool

    // 单图源搜索状态
    @State private var singleMangas: [Manga] = []
    @State private var currentPage = 1
    @State private var canLoadMore = false
    @State private var isLoadingSingle = false
    @State private var isLoadingMoreSingle = false
    @State private var singleErrorMessage: String?

    // 全源并发聚合搜索状态
    @State private var aggregateResults: [String: AggregateSourceState] = [:]
    @State private var aggregateSourceOrder: [String] = []
    @State private var aggregateFilterSourceID: String? = nil

    // 异步并发控制与弹窗状态
    @State private var activeTask: Task<Void, Never>?
    @State private var requestGeneration = 0
    @State private var showingJumpSheet = false
    @State private var jumpTargetPageInput = "1"
    @State private var noticeMessage: String?
    @State private var showNoticeBanner = false
    @State private var noticeDismissTask: Task<Void, Never>?

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 14)
    ]

    public init(
        initialQuery: String = "",
        initialSourceID: String? = nil,
        suggestedTags: [String] = [],
        autoSubmit: Bool = false
    ) {
        self.initialQuery = initialQuery
        self.initialSourceID = initialSourceID
        self.suggestedTags = suggestedTags
        self.autoSubmit = autoSubmit
    }

    // MARK: - Computed Properties

    private var enabledSources: [MangaSourceConfig] {
        store.enabledSources
    }

    private var activeSingleSource: MangaSourceConfig? {
        switch selectedScope {
        case .source(let id):
            return enabledSources.first(where: { $0.id == id }) ?? enabledSources.first
        case .allEnabled:
            return nil
        }
    }

    private var activeSingleSorts: [MangaSearchSort] {
        guard let sourceID = activeSingleSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            return [.latest]
        }
        return adapter.supportedSearchSorts
    }

    private var activeSourcePageSizeDescription: String {
        switch activeSingleSource?.kind {
        case .jm, .wnacg:
            return "\(UniformPaginator.defaultPageSize) 部/页"
        default:
            return ""
        }
    }

    private var hasSubmittedSearch: Bool {
        !submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isAggregateMode: Bool {
        if case .allEnabled = selectedScope {
            return enabledSources.count > 1
        }
        return false
    }

    private var aggregateTotalCount: Int {
        aggregateSourceOrder.reduce(0) { partial, id in
            partial + (aggregateResults[id]?.mangas.count ?? 0)
        }
    }

    private var isAnyAggregateLoading: Bool {
        aggregateSourceOrder.contains { aggregateResults[$0]?.isLoading == true }
    }

    private var quickKeywords: [String] {
        if let single = activeSingleSource, single.kind == .demo {
            return ["线稿", "彩漫", "HTTPS", "超分对比", "降噪", "在线流式"]
        }

        var result: [String] = []
        var seen = Set<String>()

        for tag in suggestedTags {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= 12,
                  !MangaSerialStatusHelper.isStatusTag(trimmed) else {
                continue
            }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
            if result.count >= 8 { break }
        }

        let presetTags = ["单行本", "同人", "汉化", "全彩", "韩漫", "短篇", "纯爱", "画集", "日常", "校园"]
        for tag in presetTags where seen.insert(tag).inserted {
            result.append(tag)
            if result.count >= 14 { break }
        }
        return result
    }

    // MARK: - Body

    public var body: some View {
        ScrollViewReader { scrollProxy in
            VStack(spacing: 0) {
                searchInputBar(scrollProxy: scrollProxy)

                if enabledSources.count > 1 {
                    scopePickerBar(scrollProxy: scrollProxy)
                }

                if showNoticeBanner, let noticeMessage {
                    noticeBannerView(noticeMessage)
                }

                if !hasSubmittedSearch {
                    searchLandingPanel(scrollProxy: scrollProxy)
                } else if isAggregateMode {
                    aggregateResultsContent(scrollProxy: scrollProxy)
                } else {
                    singleSourceResultsContent(scrollProxy: scrollProxy)
                }
            }
            .navigationTitle("搜索漫画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if hasSubmittedSearch && !isAggregateMode && !singleMangas.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
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
                    }
                }
            }
            .sheet(isPresented: $showingJumpSheet) {
                jumpPageSheet(scrollProxy: scrollProxy)
            }
            .task {
                guard !hasInitialized else { return }
                hasInitialized = true
                configureInitialState()
                let trimmedInitial = initialQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                if autoSubmit && !trimmedInitial.isEmpty {
                    submitSearch(trimmedInitial, scrollProxy: scrollProxy)
                } else {
                    try? await Task.sleep(nanoseconds: 160_000_000)
                    if !Task.isCancelled && !hasSubmittedSearch {
                        isSearchFieldFocused = true
                    }
                }
            }
            .onChange(of: queryText) { newValue in
                if newValue.isEmpty && hasSubmittedSearch {
                    clearSearchInput(refocus: false)
                }
            }
            .onDisappear {
                noticeDismissTask?.cancel()
                showNoticeBanner = false
            }
        }
    }

    // MARK: - Top Search Input Bar

    private func searchInputBar(scrollProxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)

                TextField(searchPlaceholder, text: $queryText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        submitSearch(queryText, scrollProxy: scrollProxy)
                    }

                if !queryText.isEmpty {
                    Button {
                        clearSearchInput()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索词")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                submitSearch(queryText, scrollProxy: scrollProxy)
            } label: {
                Text("搜索")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color(.tertiarySystemFill)
                            : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .foregroundStyle(
                        queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary
                            : Color.white
                    )
            }
            .buttonStyle(.plain)
            .disabled(queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchPlaceholder: String {
        if let single = activeSingleSource {
            switch single.kind {
            case .jm:
                return "搜漫画名、作者、标签或 JM 编号"
            case .wnacg:
                return "搜漫画名、标签或作品 AID"
            case .demo:
                return "搜索内置演示漫画（如：线稿 / 彩漫）"
            case .genericJSON:
                return "在「\(single.name)」中搜索漫画"
            }
        }
        return "跨源搜索漫画名、作者、标签或编号"
    }

    // MARK: - Scope Picker Bar

    private func scopePickerBar(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                scopeChip(
                    title: "全部源",
                    icon: "square.stack.3d.up",
                    isSelected: selectedScope == .allEnabled
                ) {
                    switchScope(to: .allEnabled, scrollProxy: scrollProxy)
                }

                ForEach(enabledSources) { src in
                    scopeChip(
                        title: src.name,
                        icon: nil,
                        isSelected: selectedScope == .source(src.id)
                    ) {
                        switchScope(to: .source(src.id), scrollProxy: scrollProxy)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func scopeChip(
        title: String,
        icon: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2.weight(.semibold))
                }
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isSelected ? Color.accentColor : Color(.secondarySystemFill),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search Landing Panel (History + Suggested Tags + Tips)

    private func searchLandingPanel(scrollProxy: ScrollViewProxy) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if enabledSources.isEmpty {
                    emptyNoSourceView
                } else {
                    if !store.searchHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("最近搜索", systemImage: "clock.arrow.circlepath")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        store.clearSearchHistory()
                                    }
                                    triggerHaptic()
                                } label: {
                                    Text("清空")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }

                            FlowChipLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(store.searchHistory, id: \.self) { term in
                                    HStack(spacing: 4) {
                                        Button {
                                            submitSearch(term, scrollProxy: scrollProxy)
                                        } label: {
                                            Text(term)
                                                .font(.caption.weight(.medium))
                                                .lineLimit(1)
                                                .foregroundStyle(.primary)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                store.removeSearchHistory(term)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.secondary)
                                                .padding(2)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("删除历史记录 \(term)")
                                    }
                                    .padding(.leading, 12)
                                    .padding(.trailing, 8)
                                    .padding(.vertical, 6)
                                    .background(Color(.secondarySystemFill), in: Capsule())
                                }
                            }
                        }
                    }

                    if !quickKeywords.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("快捷标签", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            FlowChipLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(quickKeywords, id: \.self) { keyword in
                                    Button {
                                        submitSearch(keyword, scrollProxy: scrollProxy)
                                    } label: {
                                        Text(keyword)
                                            .font(.caption.weight(.medium))
                                            .lineLimit(1)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(Color.accentColor.opacity(0.11), in: Capsule())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    searchTipsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var searchTipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("搜索技巧", systemImage: "lightbulb")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                tipRow("支持按漫画标题、作者名或题材标签关键词搜索。")
                if enabledSources.contains(where: { $0.kind == .jm }) {
                    tipRow("禁漫天堂支持输入车牌号（如 JM422866 或纯数字编号）精准直达。")
                }
                if enabledSources.contains(where: { $0.kind == .wnacg }) {
                    tipRow("绅士漫画支持关键词自动容错分词及 AID 编号直达。")
                }
                if enabledSources.count > 1 {
                    tipRow("选择「全部源」可并发搜索所有已启用在线源，并随时切入单源翻页。")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func tipRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("·")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Single Source Results Content

    @ViewBuilder
    private func singleSourceResultsContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            singleSourceMetaBar(scrollProxy: scrollProxy)

            if isLoadingSingle && singleMangas.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在「\(activeSingleSource?.name ?? "当前源")」中搜索「\(submittedQuery)」...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = singleErrorMessage, singleMangas.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text("搜索失败")
                        .font(.headline)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    HStack(spacing: 10) {
                        Button("重试") {
                            executeSingleSearch(page: 1, forceRefresh: true, scrollProxy: scrollProxy)
                        }
                        .buttonStyle(.borderedProminent)

                        if enabledSources.count > 1 {
                            Button("改用全部源搜索") {
                                switchScope(to: .allEnabled, scrollProxy: scrollProxy)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if singleMangas.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("未在「\(activeSingleSource?.name ?? "当前源")」找到「\(submittedQuery)」")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    Text("可以尝试缩短关键词、换用繁/简体写法，或切换其他在线源重试。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    HStack(spacing: 10) {
                        if enabledSources.count > 1 {
                            Button {
                                switchScope(to: .allEnabled, scrollProxy: scrollProxy)
                            } label: {
                                Label("在全部源中搜索", systemImage: "square.stack.3d.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        Button("重新输入") {
                            clearSearchInput()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("search_top_anchor")

                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(singleMangas) { manga in
                            NavigationLink(value: manga) {
                                MangaGridCard(
                                    manga: manga,
                                    progress: store.progress(for: manga)
                                )
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if store.discoverPaginationMode == .infiniteScroll,
                                   manga.id == singleMangas.last?.id,
                                   canLoadMore,
                                   !isLoadingMoreSingle,
                                   !isLoadingSingle {
                                    loadMoreSinglePage()
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    singlePaginationBar(scrollProxy: scrollProxy)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await performSingleSearchAsync(page: 1, isLoadMore: false, forceRefresh: true, scrollProxy: scrollProxy)
                }
            }
        }
    }

    private func singleSourceMetaBar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if isLoadingSingle && !singleMangas.isEmpty {
                    ProgressView()
                        .scaleEffect(0.75)
                }

                Text("「\(submittedQuery)」")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text("· \(activeSingleSource?.name ?? "") · 第 \(currentPage) 页 · \(singleMangas.count) 部")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                if activeSingleSorts.count > 1 {
                    Menu {
                        ForEach(activeSingleSorts) { sortOption in
                            Button {
                                guard selectedSort != sortOption else { return }
                                selectedSort = sortOption
                                executeSingleSearch(page: 1, forceRefresh: true, scrollProxy: scrollProxy)
                            } label: {
                                HStack {
                                    Text(sortOption.displayName)
                                    if selectedSort == sortOption {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                            Text(selectedSort.displayName)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            Divider()
        }
    }

    // MARK: - Aggregate (Multi-Source) Results Content

    @ViewBuilder
    private func aggregateResultsContent(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 0) {
            aggregateStatusBar

            Divider()

            if isAnyAggregateLoading && aggregateTotalCount == 0 {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在并发搜索 \(aggregateSourceOrder.count) 个在线源...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !isAnyAggregateLoading && aggregateTotalCount == 0 {
                aggregateEmptyView(scrollProxy: scrollProxy)
            } else {
                ScrollView {
                    Color.clear
                        .frame(height: 0)
                        .id("search_top_anchor")

                    if let filterID = aggregateFilterSourceID {
                        aggregateSingleFilteredBody(sourceID: filterID, scrollProxy: scrollProxy)
                    } else {
                        aggregateGroupedBody(scrollProxy: scrollProxy)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable {
                    await performAggregateSearchAsync(forceRefresh: true, scrollProxy: scrollProxy)
                }
            }
        }
    }

    private var aggregateStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    aggregateFilterSourceID = nil
                } label: {
                    HStack(spacing: 4) {
                        Text("全部")
                        Text("(\(aggregateTotalCount))")
                            .monospacedDigit()
                    }
                    .font(.caption.weight(aggregateFilterSourceID == nil ? .semibold : .regular))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        aggregateFilterSourceID == nil
                            ? Color.accentColor.opacity(0.16)
                            : Color(.tertiarySystemFill),
                        in: Capsule()
                    )
                    .foregroundStyle(aggregateFilterSourceID == nil ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)

                ForEach(aggregateSourceOrder, id: \.self) { srcID in
                    if let state = aggregateResults[srcID] {
                        let isSelected = aggregateFilterSourceID == srcID
                        Button {
                            aggregateFilterSourceID = isSelected ? nil : srcID
                        } label: {
                            HStack(spacing: 5) {
                                Text(state.sourceName)
                                if state.isLoading {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                } else if state.errorMessage != nil {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                } else {
                                    Text("(\(state.mangas.count))")
                                        .monospacedDigit()
                                }
                            }
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(.tertiarySystemFill),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
        }
    }

    private func aggregateGroupedBody(scrollProxy: ScrollViewProxy) -> some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(aggregateSourceOrder, id: \.self) { srcID in
                if let state = aggregateResults[srcID] {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(state.sourceName)
                                .font(.headline)

                            if state.isLoading {
                                ProgressView()
                                    .scaleEffect(0.75)
                                Text("搜索中...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if let err = state.errorMessage {
                                Text("请求失败")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("重试") {
                                    retrySingleSourceInAggregate(sourceID: srcID)
                                }
                                .font(.caption.weight(.semibold))
                                .buttonStyle(.bordered)
                                .accessibilityHint(err)
                            } else {
                                Text("\(state.mangas.count) 部")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !state.mangas.isEmpty {
                                    Button {
                                        switchScope(to: .source(srcID), scrollProxy: scrollProxy)
                                    } label: {
                                        HStack(spacing: 3) {
                                            Text(state.mangas.count > 12 ? "查看全部与分页" : "单源翻页")
                                            Image(systemName: "chevron.right")
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal, 16)

                        if let err = state.errorMessage, !state.isLoading {
                            Text(err)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                        } else if !state.mangas.isEmpty {
                            let previewItems = Array(state.mangas.prefix(12))
                            LazyVGrid(columns: columns, spacing: 16) {
                                ForEach(previewItems) { manga in
                                    NavigationLink(value: manga) {
                                        MangaGridCard(
                                            manga: manga,
                                            progress: store.progress(for: manga),
                                            sourceBadge: state.sourceName
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)

                            if state.mangas.count > 12 {
                                Button {
                                    switchScope(to: .source(srcID), scrollProxy: scrollProxy)
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("进入「\(state.sourceName)」查看全部 \(state.mangas.count)+ 部结果与翻页")
                                        Image(systemName: "arrow.right")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 16)
                            }
                        } else if !state.isLoading {
                            Text("该图源暂无匹配结果")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 16)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func aggregateSingleFilteredBody(sourceID: String, scrollProxy: ScrollViewProxy) -> some View {
        if let state = aggregateResults[sourceID] {
            VStack(spacing: 14) {
                if state.isLoading {
                    ProgressView("正在搜索「\(state.sourceName)」...")
                        .padding(.top, 48)
                } else if let err = state.errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("「\(state.sourceName)」搜索失败")
                            .font(.headline)
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重试该图源") {
                            retrySingleSourceInAggregate(sourceID: sourceID)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 48)
                } else if state.mangas.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("「\(state.sourceName)」未找到相关漫画")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 48)
                } else {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(state.mangas) { manga in
                            NavigationLink(value: manga) {
                                MangaGridCard(
                                    manga: manga,
                                    progress: store.progress(for: manga),
                                    sourceBadge: state.sourceName
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                    Button {
                        switchScope(to: .source(sourceID), scrollProxy: scrollProxy)
                    } label: {
                        HStack(spacing: 6) {
                            Text("切换到「\(state.sourceName)」单源模式查看更多分页与排序")
                            Image(systemName: "arrow.right")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
    }

    private func aggregateEmptyView(scrollProxy: ScrollViewProxy) -> some View {
        let failedStates = aggregateSourceOrder.compactMap { id -> AggregateSourceState? in
            guard let s = aggregateResults[id], s.errorMessage != nil else { return nil }
            return s
        }

        return VStack(spacing: 14) {
            Image(systemName: failedStates.isEmpty ? "magnifyingglass" : "wifi.exclamationmark")
                .font(.system(size: 42))
                .foregroundStyle(failedStates.isEmpty ? Color.secondary : Color.orange)

            Text(failedStates.isEmpty ? "全部图源均未找到「\(submittedQuery)」" : "未获取到搜索结果")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            if !failedStates.isEmpty {
                VStack(spacing: 4) {
                    ForEach(failedStates, id: \.sourceID) { item in
                        Text("\(item.sourceName)：\(item.errorMessage ?? "请求失败")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 24)
            } else {
                Text("尝试更换更简短的关键词，或检查在线源是否已启用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            HStack(spacing: 10) {
                Button("重新搜索") {
                    executeAggregateSearch(forceRefresh: true, scrollProxy: scrollProxy)
                }
                .buttonStyle(.borderedProminent)

                Button("修改关键词") {
                    clearSearchInput()
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyNoSourceView: some View {
        VStack(spacing: 12) {
            Image(systemName: "network.slash")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("当前没有启用的在线图源")
                .font(.headline)
            Text("请先在底部「在线源」标签页启用或添加图源后再搜索。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // MARK: - Single Source Pagination Bar & Jump Sheet

    @ViewBuilder
    private func singlePaginationBar(scrollProxy: ScrollViewProxy) -> some View {
        VStack(spacing: 12) {
            if isLoadingMoreSingle {
                ProgressView("正在载入下一页...")
                    .padding(.vertical, 8)
            }

            HStack(spacing: 12) {
                Button {
                    switchSinglePage(currentPage - 1, scrollProxy: scrollProxy)
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
                .disabled(currentPage <= 1 || isLoadingSingle || isLoadingMoreSingle)

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

                Button {
                    if store.discoverPaginationMode == .pageByPage {
                        switchSinglePage(currentPage + 1, scrollProxy: scrollProxy)
                    } else {
                        loadMoreSinglePage()
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
                .disabled(!canLoadMore || isLoadingSingle || isLoadingMoreSingle)
            }

            HStack(spacing: 8) {
                Text(store.discoverPaginationMode.displayName)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))

                if !activeSourcePageSizeDescription.isEmpty {
                    Text(activeSourcePageSizeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("search_top_anchor", anchor: .top)
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

    private func jumpPageSheet(scrollProxy: ScrollViewProxy) -> some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("搜索结果跳页")
                        .font(.title3.weight(.bold))
                    Text("「\(submittedQuery)」· 第 \(currentPage) 页 · \(activeSingleSource?.name ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 10)

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

                HStack(spacing: 8) {
                    quickStepButton(delta: -5)
                    quickStepButton(delta: -1)
                    quickStepButton(delta: 1)
                    quickStepButton(delta: 5)
                    quickStepButton(delta: 10)
                }

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        let target = Int(jumpTargetPageInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? currentPage
                        showingJumpSheet = false
                        switchSinglePage(max(1, target), scrollProxy: scrollProxy)
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
            .presentationDetents([.height(340)])
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

    // MARK: - Search Orchestration

    private func configureInitialState() {
        queryText = initialQuery
        if let initialSourceID,
           enabledSources.contains(where: { $0.id == initialSourceID }) {
            selectedScope = .source(initialSourceID)
        } else if enabledSources.count == 1, let only = enabledSources.first {
            selectedScope = .source(only.id)
        } else if !store.selectedSourceID.isEmpty,
                  enabledSources.contains(where: { $0.id == store.selectedSourceID }) {
            selectedScope = .source(store.selectedSourceID)
        } else {
            selectedScope = .allEnabled
        }
    }

    private func clearSearchInput(refocus: Bool = true) {
        activeTask?.cancel()
        requestGeneration += 1
        queryText = ""
        submittedQuery = ""
        singleMangas = []
        singleErrorMessage = nil
        isLoadingSingle = false
        isLoadingMoreSingle = false
        canLoadMore = false
        currentPage = 1
        aggregateResults = [:]
        aggregateSourceOrder = []
        aggregateFilterSourceID = nil
        if refocus {
            isSearchFieldFocused = true
        }
    }

    private func switchScope(to newScope: MangaSearchScope, scrollProxy: ScrollViewProxy) {
        guard selectedScope != newScope else { return }
        selectedScope = newScope
        aggregateFilterSourceID = nil

        if !activeSingleSorts.contains(selectedSort) {
            selectedSort = .latest
        }

        guard hasSubmittedSearch else { return }
        if isAggregateMode {
            executeAggregateSearch(scrollProxy: scrollProxy)
        } else {
            executeSingleSearch(page: 1, scrollProxy: scrollProxy)
        }
    }

    private func submitSearch(_ rawQuery: String, scrollProxy: ScrollViewProxy) {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        queryText = trimmed
        submittedQuery = trimmed
        isSearchFieldFocused = false
        store.recordSearchHistory(trimmed)
        triggerHaptic()

        if isAggregateMode {
            executeAggregateSearch(forceRefresh: true, scrollProxy: scrollProxy)
        } else {
            executeSingleSearch(page: 1, forceRefresh: true, scrollProxy: scrollProxy)
        }
    }

    private func executeSingleSearch(
        page: Int,
        forceRefresh: Bool = false,
        scrollProxy: ScrollViewProxy? = nil
    ) {
        activeTask?.cancel()
        activeTask = Task {
            await performSingleSearchAsync(
                page: page,
                isLoadMore: false,
                forceRefresh: forceRefresh,
                scrollProxy: scrollProxy
            )
        }
    }

    private func switchSinglePage(_ targetPage: Int, scrollProxy: ScrollViewProxy? = nil) {
        guard targetPage >= 1 else { return }
        executeSingleSearch(page: targetPage, forceRefresh: false, scrollProxy: scrollProxy)
    }

    private func loadMoreSinglePage() {
        guard !isLoadingSingle, !isLoadingMoreSingle, canLoadMore else { return }
        let nextPage = currentPage + 1
        activeTask?.cancel()
        activeTask = Task {
            await performSingleSearchAsync(
                page: nextPage,
                isLoadMore: true,
                forceRefresh: false,
                scrollProxy: nil
            )
        }
    }

    private func performSingleSearchAsync(
        page: Int,
        isLoadMore: Bool,
        forceRefresh: Bool = false,
        scrollProxy: ScrollViewProxy?
    ) async {
        let query = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        guard let source = activeSingleSource,
              let adapter = store.adapter(for: source.id) else {
            singleMangas = []
            canLoadMore = false
            singleErrorMessage = "当前没有启用的在线图源，请先在「在线源」页启用或添加。"
            return
        }

        requestGeneration += 1
        let generation = requestGeneration
        let sort = selectedSort

        if isLoadMore {
            isLoadingMoreSingle = true
        } else {
            isLoadingSingle = true
            singleErrorMessage = nil
            if page == 1 {
                singleMangas = []
                currentPage = 1
            }
        }

        defer {
            if generation == requestGeneration {
                if isLoadMore {
                    isLoadingMoreSingle = false
                } else {
                    isLoadingSingle = false
                }
            }
        }

        do {
            if forceRefresh {
                await adapter.resetPaginationCache(scope: .search)
            }
            let rawFetched = try await adapter.search(query: query, sort: sort, page: page)
            guard !Task.isCancelled, generation == requestGeneration else { return }
            let fetched = deduplicateMangas(rawFetched)

            if isLoadMore {
                if fetched.isEmpty {
                    canLoadMore = false
                    showNotice("已到底部，无更多搜索结果")
                    return
                }
                var seen = Set(singleMangas.map(\.compositeKey))
                let uniqueNew = fetched.filter { seen.insert($0.compositeKey).inserted }
                if uniqueNew.isEmpty {
                    canLoadMore = false
                    showNotice("已到底部，无更多搜索结果")
                } else {
                    singleMangas.append(contentsOf: uniqueNew)
                    currentPage = page
                    canLoadMore = hasMorePages(fetchedCount: rawFetched.count, source: source)
                    triggerHaptic()
                }
            } else {
                if page > 1 && fetched.isEmpty {
                    showNotice("第 \(page) 页暂无更多搜索结果")
                    if page > currentPage {
                        canLoadMore = false
                    }
                    return
                }
                singleMangas = fetched
                currentPage = page
                canLoadMore = hasMorePages(fetchedCount: rawFetched.count, source: source)
                if let scrollProxy {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scrollProxy.scrollTo("search_top_anchor", anchor: .top)
                    }
                }
                if page > 1 {
                    triggerHaptic()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if isLoadMore {
                canLoadMore = false
                showNotice("加载下一页出错: \(error.localizedDescription)")
            } else if page > 1 && !singleMangas.isEmpty {
                showNotice("加载第 \(page) 页失败: \(error.localizedDescription)")
            } else {
                singleErrorMessage = error.localizedDescription
                singleMangas = []
                canLoadMore = false
            }
        }
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

    private func executeAggregateSearch(forceRefresh: Bool = false, scrollProxy: ScrollViewProxy? = nil) {
        activeTask?.cancel()
        activeTask = Task {
            await performAggregateSearchAsync(forceRefresh: forceRefresh, scrollProxy: scrollProxy)
        }
    }

    private func performAggregateSearchAsync(forceRefresh: Bool = false, scrollProxy: ScrollViewProxy?) async {
        let query = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        let targets: [(config: MangaSourceConfig, adapter: any MangaSourceProtocol)] = enabledSources.compactMap { src in
            guard let adapter = store.adapter(for: src.id) else { return nil }
            return (src, adapter)
        }
        guard !targets.isEmpty else { return }

        requestGeneration += 1
        let generation = requestGeneration

        aggregateFilterSourceID = nil
        aggregateSourceOrder = targets.map(\.config.id)
        var initialMap: [String: AggregateSourceState] = [:]
        for entry in targets {
            initialMap[entry.config.id] = AggregateSourceState(
                sourceID: entry.config.id,
                sourceName: entry.config.name,
                isLoading: true,
                mangas: [],
                errorMessage: nil
            )
        }
        aggregateResults = initialMap

        if let scrollProxy {
            withAnimation(.easeInOut(duration: 0.2)) {
                scrollProxy.scrollTo("search_top_anchor", anchor: .top)
            }
        }

        defer {
            if generation == requestGeneration {
                for srcID in aggregateSourceOrder {
                    if var state = aggregateResults[srcID], state.isLoading {
                        state.isLoading = false
                        aggregateResults[srcID] = state
                    }
                }
            }
        }

        await withTaskGroup(of: SourceSearchOutcome.self) { group in
            for entry in targets {
                let config = entry.config
                let adapter = entry.adapter
                group.addTask {
                    do {
                        if forceRefresh {
                            await adapter.resetPaginationCache(scope: .search)
                        }
                        let items = try await adapter.search(query: query, sort: .latest, page: 1)
                        return SourceSearchOutcome(
                            sourceID: config.id,
                            sourceName: config.name,
                            mangas: items,
                            errorMessage: nil,
                            wasCancelled: false
                        )
                    } catch is CancellationError {
                        return SourceSearchOutcome(
                            sourceID: config.id,
                            sourceName: config.name,
                            mangas: [],
                            errorMessage: nil,
                            wasCancelled: true
                        )
                    } catch {
                        return SourceSearchOutcome(
                            sourceID: config.id,
                            sourceName: config.name,
                            mangas: [],
                            errorMessage: error.localizedDescription,
                            wasCancelled: false
                        )
                    }
                }
            }

            for await outcome in group {
                guard !Task.isCancelled, generation == requestGeneration, !outcome.wasCancelled else { continue }
                aggregateResults[outcome.sourceID] = AggregateSourceState(
                    sourceID: outcome.sourceID,
                    sourceName: outcome.sourceName,
                    isLoading: false,
                    mangas: deduplicateMangas(outcome.mangas),
                    errorMessage: outcome.errorMessage
                )
            }
        }
    }

    private func retrySingleSourceInAggregate(sourceID: String) {
        let query = submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              let config = enabledSources.first(where: { $0.id == sourceID }),
              let adapter = store.adapter(for: sourceID) else {
            return
        }

        let generation = requestGeneration
        aggregateResults[sourceID] = AggregateSourceState(
            sourceID: config.id,
            sourceName: config.name,
            isLoading: true,
            mangas: [],
            errorMessage: nil
        )

        Task {
            do {
                await adapter.resetPaginationCache(scope: .search)
                let items = try await adapter.search(query: query, sort: .latest, page: 1)
                guard generation == requestGeneration else { return }
                aggregateResults[sourceID] = AggregateSourceState(
                    sourceID: config.id,
                    sourceName: config.name,
                    isLoading: false,
                    mangas: deduplicateMangas(items),
                    errorMessage: nil
                )
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration else { return }
                aggregateResults[sourceID] = AggregateSourceState(
                    sourceID: config.id,
                    sourceName: config.name,
                    isLoading: false,
                    mangas: [],
                    errorMessage: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Helpers

    private func deduplicateMangas(_ items: [Manga]) -> [Manga] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.compositeKey).inserted }
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

// MARK: - Supporting Types

private struct AggregateSourceState: Equatable {
    let sourceID: String
    let sourceName: String
    var isLoading: Bool
    var mangas: [Manga]
    var errorMessage: String?
}

private struct SourceSearchOutcome: Sendable {
    let sourceID: String
    let sourceName: String
    let mangas: [Manga]
    let errorMessage: String?
    let wasCancelled: Bool
}

/// iOS 16 原生自适应自动换行流式标签布局（用于搜索历史与快捷标签）
private struct FlowChipLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let itemProposal = ProposedViewSize(
            width: maxWidth.isFinite ? maxWidth : nil,
            height: nil
        )

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(itemProposal)
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            maxLineWidth = max(maxLineWidth, currentX + size.width)
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }

        let totalHeight = subviews.isEmpty ? 0 : (currentY + lineHeight)
        let resolvedWidth = proposal.width ?? maxLineWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let itemProposal = ProposedViewSize(width: bounds.width, height: nil)
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(itemProposal)
            if currentX > bounds.minX && currentX + size.width > bounds.maxX {
                currentX = bounds.minX
                currentY += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
            )
            currentX += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
