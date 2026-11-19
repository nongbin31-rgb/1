import SwiftUI

/// 在线图源发现与搜索页
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

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.enabledSources.count > 1 {
                    sourcePickerBar
                }

                if !activeCategories.isEmpty && searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    categoryPickerBar
                }

                Group {
                    if isLoading && mangas.isEmpty {
                        ProgressView("正在拉取在线图源...")
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
                                Task { await reload() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if mangas.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("暂无匹配的在线漫画")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
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
                                        if manga.id == mangas.last?.id, canLoadMore, !isLoadingMore {
                                            Task { await loadMore() }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)

                            if isLoadingMore {
                                ProgressView("正在加载下一页...")
                                    .padding(.vertical, 14)
                            } else if canLoadMore {
                                Button("加载更多") {
                                    Task { await loadMore() }
                                }
                                .buttonStyle(.bordered)
                                .padding(.vertical, 12)
                            }
                        }
                        .refreshable {
                            await reload()
                        }
                    }
                }
            }
            .navigationTitle(activeSource?.name ?? "发现")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchQuery, prompt: "在当前在线源搜索漫画")
            .onSubmit(of: .search) {
                Task { await reload() }
            }
            .onChange(of: searchQuery) { newValue in
                if newValue.isEmpty {
                    Task { await reload() }
                }
            }
            .onChange(of: store.selectedSourceID) { _ in
                selectedCategoryID = activeCategories.first?.id ?? ""
                Task { await reload() }
            }
            .task {
                if store.selectedSourceID.isEmpty, let first = store.enabledSources.first {
                    store.selectedSourceID = first.id
                }
                if selectedCategoryID.isEmpty {
                    selectedCategoryID = activeCategories.first?.id ?? ""
                }
                if mangas.isEmpty {
                    await reload()
                }
            }
            .navigationDestination(for: Manga.self) { manga in
                MangaDetailView(manga: manga)
            }
        }
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
                            .foregroundStyle(isSelected ? .white : .primary)
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
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private func reload() async {
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
        } catch {
            errorMessage = error.localizedDescription
            mangas = []
            canLoadMore = false
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
                return
            }
            var seen = Set(mangas.map(\.compositeKey))
            let uniqueNew = fetched.filter { seen.insert($0.compositeKey).inserted }
            if uniqueNew.isEmpty {
                canLoadMore = false
            } else {
                mangas.append(contentsOf: uniqueNew)
                currentPage = nextPage
            }
        } catch {
            canLoadMore = false
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
}
