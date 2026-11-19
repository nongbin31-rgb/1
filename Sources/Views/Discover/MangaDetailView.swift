import SwiftUI

/// 漫画详情与章节列表页
public struct MangaDetailView: View {
    @EnvironmentObject private var store: AppStore

    let manga: Manga

    @State private var chapters: [MangaChapter] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var activeChapter: MangaChapter?

    private var isSaved: Bool {
        store.isInBookshelf(manga)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection

                if !manga.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介")
                            .font(.headline)
                        Text(manga.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }

                upscalerBanner
                    .padding(.horizontal, 16)

                chaptersSection
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("漫画详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadChapters()
        }
        .fullScreenCover(item: $activeChapter) { chapter in
            ReaderView(
                manga: manga,
                chapters: chapters,
                initialChapter: chapter
            )
            .environmentObject(store)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncMangaCoverView(urlString: manga.coverURL, cornerRadius: 12)
                .frame(width: 118, height: 168)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(manga.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if !manga.author.isEmpty {
                    Label(manga.author, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !manga.tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(manga.tags, id: \.self) { tag in
                                Text(tag)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color(.tertiarySystemFill), in: Capsule())
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        if let progress = store.progress(for: manga),
                           let resumeChapter = chapters.first(where: { $0.id == progress.chapterID }) {
                            activeChapter = resumeChapter
                        } else if let first = chapters.first {
                            activeChapter = first
                        }
                    } label: {
                        Label(
                            store.progress(for: manga) == nil ? "开始阅读" : "继续阅读",
                            systemImage: "play.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chapters.isEmpty)

                    Button {
                        store.toggleBookshelf(manga)
                    } label: {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .frame(width: 24, height: 22)
                    }
                    .buttonStyle(.bordered)
                    .tint(isSaved ? .orange : .accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var upscalerBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("当前超分管线")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(store.upscalerConfig.summaryText)
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("章节列表 (\(chapters.count))")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                }
            }
            .padding(.horizontal, 16)

            if let errorMessage {
                VStack(spacing: 8) {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("重新获取章节") {
                        Task { await loadChapters() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(chapters) { chapter in
                        let isCurrent = store.progress(for: manga)?.chapterID == chapter.id
                        Button {
                            activeChapter = chapter
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                    if !chapter.updatedAt.isEmpty {
                                        Text(chapter.updatedAt)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if isCurrent {
                                    Text("上次读到")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.tint)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func loadChapters() async {
        guard let adapter = store.adapter(for: manga.sourceID) else {
            errorMessage = "未找到对应在线图源"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            chapters = try await adapter.fetchChapters(for: manga)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
