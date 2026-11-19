import SwiftUI

/// 在线图源发现与搜索页
public struct DiscoverView: View {
    @EnvironmentObject private var store: AppStore

    @State private var mangas: [Manga] = []
    @State private var searchQuery = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 14)
    ]

    private var activeSource: MangaSourceConfig? {
        store.enabledSources.first(where: { $0.id == store.selectedSourceID })
            ?? store.enabledSources.first
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if store.enabledSources.count > 1 {
                    sourcePickerBar
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
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
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
                Task { await reload() }
            }
            .task {
                if store.selectedSourceID.isEmpty, let first = store.enabledSources.first {
                    store.selectedSourceID = first.id
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

    private func reload() async {
        guard let sourceID = activeSource?.id,
              let adapter = store.adapter(for: sourceID) else {
            mangas = []
            errorMessage = "当前没有启用的在线图源，请先在「书源」页启用或添加。"
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                mangas = try await adapter.fetchPopular(page: 1)
            } else {
                mangas = try await adapter.search(query: trimmed, page: 1)
            }
        } catch {
            errorMessage = error.localizedDescription
            mangas = []
        }
    }
}
