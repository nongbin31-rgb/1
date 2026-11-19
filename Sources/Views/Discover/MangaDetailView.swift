import SwiftUI

/// 漫画详情与章节列表页
public struct MangaDetailView: View {
    @EnvironmentObject private var store: AppStore

    let manga: Manga

    @State private var resolvedManga: Manga?
    @State private var chapters: [MangaChapter] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var launchPayload: ReaderLaunchPayload?

    private var currentManga: Manga {
        resolvedManga ?? manga
    }

    private var isSaved: Bool {
        store.isInBookshelf(currentManga)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerSection

                if !currentManga.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("简介")
                            .font(.headline)
                        Text(currentManga.summary)
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
        .fullScreenCover(item: $launchPayload) { payload in
            ReaderView(
                manga: currentManga,
                chapters: payload.chapters,
                initialChapter: payload.initialChapter
            )
            .environmentObject(store)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncMangaCoverView(
                urlString: currentManga.coverURL,
                headers: currentManga.coverHeaders,
                cornerRadius: 12
            )
                .frame(width: 118, height: 168)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(currentManga.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                let displayAuthor = currentManga.displayAuthor
                if !displayAuthor.isEmpty {
                    Label(displayAuthor, systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                let tags = displayedTags
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                mangaTagBadge(tag)
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        if let progress = store.progress(for: currentManga),
                           let resumeChapter = chapters.first(where: { $0.id == progress.chapterID }) {
                            launchPayload = ReaderLaunchPayload(chapters: chapters, initialChapter: resumeChapter)
                        } else if let first = chapters.first {
                            launchPayload = ReaderLaunchPayload(chapters: chapters, initialChapter: first)
                        }
                    } label: {
                        Label(
                            store.progress(for: currentManga) == nil ? "开始阅读" : "继续阅读",
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
                        store.toggleBookshelf(currentManga)
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
                            launchPayload = ReaderLaunchPayload(chapters: chapters, initialChapter: chapter)
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
            let detail = try await adapter.fetchDetail(for: manga)
            resolvedManga = detail.manga
            chapters = detail.chapters
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var displayedTags: [String] {
        var tags = currentManga.tags
        let status = currentManga.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty && !tags.contains(status) {
            tags = MangaSerialStatusHelper.ensureStatusTagInTags(tags: tags, statusText: status)
        }
        return tags
    }

    @ViewBuilder
    private func mangaTagBadge(_ tag: String) -> some View {
        if MangaSerialStatusHelper.isOngoingStatus(tag) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text(tag)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.green.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.green)
        } else if MangaSerialStatusHelper.isCompletedStatus(tag) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                Text(tag)
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(Color.orange)
        } else {
            Text(tag)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }
}

private struct ReaderLaunchPayload: Identifiable {
    let id = UUID()
    let chapters: [MangaChapter]
    let initialChapter: MangaChapter
}
