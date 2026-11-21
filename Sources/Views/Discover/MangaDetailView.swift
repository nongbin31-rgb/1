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

                configCardsSection

                chaptersSection
            }
            .padding(.vertical, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("漫画详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task {
            await loadChapters()
        }
        .fullScreenCover(item: $launchPayload) { payload in
            ReaderView(
                manga: currentManga,
                chapters: payload.chapters,
                initialChapter: payload.initialChapter,
                initialPageIndex: payload.initialPageIndex
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

            VStack(alignment: .leading, spacing: 6) {
                Text(currentManga.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                let displayAuthor = currentManga.displayAuthor
                if !displayAuthor.isEmpty {
                    let isSearchableAuthor = displayAuthor != "佚名" && displayAuthor != "绅士本"
                    if isSearchableAuthor {
                        NavigationLink(
                            value: MangaSearchRoute(
                                initialQuery: displayAuthor,
                                initialSourceID: currentManga.sourceID,
                                autoSubmit: true
                            )
                        ) {
                            HStack(spacing: 4) {
                                Label(displayAuthor, systemImage: "person")
                                Image(systemName: "magnifyingglass")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Label(displayAuthor, systemImage: "person")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                let status = currentStatusText
                if !status.isEmpty {
                    mangaStatusBadge(status)
                }

                let tags = cleanTags
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tags, id: \.self) { tag in
                                NavigationLink(
                                    value: MangaSearchRoute(
                                        initialQuery: tag,
                                        initialSourceID: currentManga.sourceID,
                                        autoSubmit: true
                                    )
                                ) {
                                    mangaTagBadge(tag)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 10) {
                    Button {
                        if let progress = store.progress(for: currentManga),
                           let resumeChapter = chapters.first(where: { $0.id == progress.chapterID }) {
                            launchPayload = ReaderLaunchPayload(
                                chapters: chapters,
                                initialChapter: resumeChapter,
                                initialPageIndex: progress.pageIndex
                            )
                        } else if let first = chapters.first {
                            launchPayload = ReaderLaunchPayload(
                                chapters: chapters,
                                initialChapter: first,
                                initialPageIndex: 0
                            )
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

    private var configCardsSection: some View {
        HStack(spacing: 10) {
            upscalerBanner
            readingModeBanner
        }
        .padding(.horizontal, 16)
    }

    private var upscalerBanner: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("画质超分")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(store.enableImageUpscaler ? store.upscalerConfig.model.displayName : "原图直出")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCardStyle(cornerRadius: 12)
    }

    private var readingModeBanner: some View {
        let currentMode = store.layoutMode(for: currentManga)
        let category = store.detectedCategory(for: currentManga)
        let isCustomized = store.customLayoutMode(for: currentManga) != nil

        return Menu {
            ForEach(ReaderLayoutMode.allCases) { mode in
                Button {
                    store.setLayoutMode(mode, for: currentManga)
                } label: {
                    HStack {
                        Text(mode.displayName)
                        if currentMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if isCustomized {
                Divider()
                Button("恢复智能识别") {
                    store.setLayoutMode(nil, for: currentManga)
                }
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: currentMode == .verticalWebtoon ? "rectangle.portrait.and.arrow.forward" : "book.closed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("阅读排版")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if isCustomized {
                            Text("自定")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        } else if store.autoDetectMangaLayout {
                            Text(category == .koreanWebtoon ? "韩漫" : (category == .japaneseManga ? "日漫" : "默认"))
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.green)
                        }
                    }
                    HStack(spacing: 2) {
                        Text(currentMode.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetCardStyle(cornerRadius: 12)
            .foregroundStyle(Color.primary)
        }
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
                        let saved = store.progress(for: currentManga)
                        let isCurrent = saved?.chapterID == chapter.id
                        Button {
                            launchPayload = ReaderLaunchPayload(
                                chapters: chapters,
                                initialChapter: chapter,
                                initialPageIndex: isCurrent ? saved?.pageIndex : 0
                            )
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(chapter.title)
                                        .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                                        .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
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
                                        .foregroundStyle(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .insetCardStyle(cornerRadius: 11)
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

    private var cleanTags: [String] {
        MangaSerialStatusHelper.sanitizeTags(currentManga.tags)
    }

    private var currentStatusText: String {
        let status = currentManga.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty {
            return status
        }
        return MangaSerialStatusHelper.inferStatusText(
            title: currentManga.title,
            tags: currentManga.tags,
            chapterCount: chapters.count
        )
    }

    @ViewBuilder
    private func mangaStatusBadge(_ status: String) -> some View {
        let isOngoing = MangaSerialStatusHelper.isOngoingStatus(status)
        let isCompleted = MangaSerialStatusHelper.isCompletedStatus(status)
        let color: Color = isOngoing ? .green : (isCompleted ? .orange : .blue)

        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(status)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }

    @ViewBuilder
    private func mangaTagBadge(_ tag: String) -> some View {
        Text(tag)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}

private struct ReaderLaunchPayload: Identifiable {
    let id = UUID()
    let chapters: [MangaChapter]
    let initialChapter: MangaChapter
    let initialPageIndex: Int?
}

private struct InsetCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(
                        color: colorScheme == .dark
                            ? Color.black.opacity(0.35)
                            : Color.black.opacity(0.045),
                        radius: colorScheme == .dark ? 3 : 5,
                        x: 0,
                        y: colorScheme == .dark ? 1.5 : 2
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        colorScheme == .dark
                            ? Color.white.opacity(0.08)
                            : Color.black.opacity(0.05),
                        lineWidth: 0.8
                    )
            )
    }
}

private extension View {
    func insetCardStyle(cornerRadius: CGFloat = 12) -> some View {
        modifier(InsetCardModifier(cornerRadius: cornerRadius))
    }
}
