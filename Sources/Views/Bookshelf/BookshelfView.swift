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
            VStack(spacing: 0) {
                bookshelfHeaderBar

                if !store.bookshelf.isEmpty {
                    bookshelfSearchBar
                }

                Group {
                    if store.bookshelf.isEmpty {
                        emptyStateView
                    } else if filteredBooks.isEmpty {
                        emptySearchResultView
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
            }
            .navigationTitle("书架")
            .navigationBarTitleDisplayMode(.inline)
            .compatNavigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }

    private var bookshelfHeaderBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("书架")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isGridMode.toggle()
                }
            } label: {
                Image(systemName: isGridMode ? "list.bullet" : "square.grid.2x2")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.leading, 5)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isGridMode ? "切换列表视图" : "切换网格视图")
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

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
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var emptySearchResultView: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("未找到匹配的收藏漫画")
                .font(.headline)
            Text("试试其他关键词，或清空搜索条件。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
private struct ReadingProgressRingView: View {
    let hasProgress: Bool
    let progress: Double?
    let isExact: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.26), lineWidth: 1.6)

            if hasProgress {
                let ratio = min(1.0, max(0.05, progress ?? 0.05))
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(
                        isExact ? Color.primary.opacity(0.72) : Color.secondary.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 12, height: 12)
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
