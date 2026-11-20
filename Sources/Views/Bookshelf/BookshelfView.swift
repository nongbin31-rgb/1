import SwiftUI

/// 在线收藏书架
public struct BookshelfView: View {
    @EnvironmentObject private var store: AppStore
    @Binding var selectedTab: AppTab

    @State private var searchText = ""
    @State private var isGridMode = true

    private var filteredBooks: [Manga] {
        let kw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return store.bookshelf }
        return store.bookshelf.filter {
            $0.title.localizedCaseInsensitiveContains(kw) ||
            $0.displayAuthor.localizedCaseInsensitiveContains(kw)
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 112, maximum: 165), spacing: 14, alignment: .top)
    ]

    public var body: some View {
        NavigationView {
            Group {
                if store.bookshelf.isEmpty {
                    emptyStateView
                } else if isGridMode {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(filteredBooks) { manga in
                                NavigationLink(destination: MangaDetailView(manga: manga)) {
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
                } else {
                    List {
                        ForEach(filteredBooks) { manga in
                            NavigationLink(destination: MangaDetailView(manga: manga)) {
                                HStack(spacing: 12) {
                                    AsyncMangaCoverView(urlString: manga.coverURL, cornerRadius: 8)
                                        .frame(width: 56, height: 80)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(manga.title)
                                            .font(.headline)
                                            .lineLimit(2)
                                        if !manga.displayAuthor.isEmpty {
                                            Text(manga.displayAuthor)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let progress = store.progress(for: manga) {
                                            Text("上次读到：\(progress.chapterTitle) · 第 \(progress.pageIndex + 1) 页")
                                                .font(.caption2)
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            for idx in offsets {
                                store.toggleBookshelf(filteredBooks[idx])
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("书架")
            .searchable(text: $searchText, prompt: "搜索收藏的漫画")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isGridMode.toggle()
                        }
                    } label: {
                        Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                    }
                    .accessibilityLabel(isGridMode ? "切换列表视图" : "切换网格视图")
                }
            }
        }
        .navigationViewStyle(.stack)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
                    Text("P\(progress.pageIndex + 1)")
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
                .lineLimit(2)
                .frame(height: 38, alignment: .topLeading)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            if !manga.statusText.isEmpty {
                HStack(spacing: 3) {
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
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
