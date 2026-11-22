import SwiftUI

/// 离线缓存管理页（查看下载队列、按漫画管理已缓存章节、支持完全离线直接阅读与空间清理）
public struct OfflineDownloadsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var downloadManager = OfflineDownloadManager.shared

    @State private var showingClearAllAlert = false
    @State private var mangaToDelete: OfflineMangaSummary?
    @State private var launchPayload: OfflineReaderPayload?

    private var activeTaskList: [ChapterDownloadTaskInfo] {
        downloadManager.activeTasks.values.sorted { lhs, rhs in
            if lhs.state.isInProgress != rhs.state.isInProgress {
                return lhs.state.isInProgress
            }
            if lhs.manga.title != rhs.manga.title {
                return lhs.manga.title < rhs.manga.title
            }
            return lhs.chapter.number < rhs.chapter.number
        }
    }

    public init() {}

    public var body: some View {
        List {
            if !activeTaskList.isEmpty {
                Section {
                    ForEach(activeTaskList) { task in
                        HStack(spacing: 12) {
                            AsyncMangaCoverView(
                                urlString: task.manga.coverURL,
                                headers: task.manga.coverHeaders,
                                cornerRadius: 6
                            )
                            .frame(width: 38, height: 52)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(task.manga.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(task.chapter.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                switch task.state {
                                case .queued, .fetchingPages, .downloading:
                                    HStack(spacing: 6) {
                                        ProgressView(value: task.state.progressRatio)
                                            .tint(.accentColor)
                                        Text(task.state.shortStatusText)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                case let .failed(msg):
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }

                            Spacer(minLength: 4)

                            Button {
                                downloadManager.cancelDownload(
                                    mangaKey: task.mangaKey,
                                    chapterID: task.chapter.id
                                )
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("下载队列 (\(activeTaskList.count))")
                        Spacer()
                        Button("全部取消") {
                            downloadManager.cancelAllDownloads()
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                    }
                }
            }

            let summaries = downloadManager.groupedDownloadedMangas
            if summaries.isEmpty {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle.dotted")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("暂无离线缓存漫画")
                            .font(.subheadline.weight(.semibold))
                        Text("在漫画详情页的章节列表中，点击章节右侧下载图标或「缓存全部」即可将章节持久化保存到本地。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                Section {
                    ForEach(summaries) { summary in
                        DisclosureGroup {
                            ForEach(summary.chapters) { record in
                                HStack(spacing: 10) {
                                    Button {
                                        openOfflineReader(summary: summary, chapter: record.chapter)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(record.chapter.title)
                                                .font(.subheadline)
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Text("\(record.pages.count) 页 · \(OfflineDownloadManager.formatBytes(record.totalBytes))")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)

                                    Button(role: .destructive) {
                                        downloadManager.deleteChapter(
                                            mangaKey: summary.id,
                                            chapterID: record.chapter.id
                                        )
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .padding(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AsyncMangaCoverView(
                                    urlString: summary.manga.coverURL,
                                    headers: summary.manga.coverHeaders,
                                    cornerRadius: 7
                                )
                                .frame(width: 44, height: 60)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(summary.manga.title)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(2)
                                    HStack(spacing: 8) {
                                        Text("已缓存 \(summary.chapters.count) 话")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.green)
                                        Text(OfflineDownloadManager.formatBytes(summary.totalBytes))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 4)

                                Button {
                                    if let first = summary.chapters.first?.chapter {
                                        openOfflineReader(summary: summary, chapter: first)
                                    }
                                } label: {
                                    Image(systemName: "play.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("离线阅读")
                            }
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button(role: .destructive) {
                                    mangaToDelete = summary
                                } label: {
                                    Label("删除整本离线缓存", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                mangaToDelete = summary
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("已下载漫画 (\(summaries.count))")
                        Spacer()
                        Text("共 \(OfflineDownloadManager.formatBytes(downloadManager.totalEstimatedBytes))")
                            .font(.caption2.monospacedDigit())
                            .textCase(nil)
                    }
                } footer: {
                    Text("离线缓存保存在永久应用存储区，清理「临时浏览图片缓存」时不会被误删，断网时可直接打开阅读。")
                }
            }
        }
        .navigationTitle("离线缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !downloadManager.downloadedChapters.isEmpty || !activeTaskList.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空", role: .destructive) {
                        showingClearAllAlert = true
                    }
                    .foregroundStyle(.red)
                }
            }
        }
        .fullScreenCover(item: $launchPayload) { payload in
            ReaderView(
                manga: payload.manga,
                chapters: payload.chapters,
                initialChapter: payload.initialChapter,
                initialPageIndex: payload.initialPageIndex
            )
            .environmentObject(store)
        }
        .alert("删除整本离线缓存？", isPresented: Binding(
            get: { mangaToDelete != nil },
            set: { if !$0 { mangaToDelete = nil } }
        )) {
            Button("取消", role: .cancel) { mangaToDelete = nil }
            Button("删除", role: .destructive) {
                if let summary = mangaToDelete {
                    downloadManager.deleteManga(mangaKey: summary.id)
                }
                mangaToDelete = nil
            }
        } message: {
            Text("将删除《\(mangaToDelete?.manga.title ?? "")》的全部 \(mangaToDelete?.chapters.count ?? 0) 话离线图片。")
        }
        .alert("清空全部离线缓存？", isPresented: $showingClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("全部清空", role: .destructive) {
                downloadManager.deleteAllDownloads()
            }
        } message: {
            Text("将取消所有在途下载任务并移除本地所有已缓存漫画章节，释放存储空间。")
        }
    }

    private func openOfflineReader(summary: OfflineMangaSummary, chapter: MangaChapter) {
        let allChapters = summary.chapters.map(\.chapter)
        let saved = store.progress(for: summary.manga)
        let pageIndex = (saved?.chapterID == chapter.id) ? saved?.pageIndex : 0
        launchPayload = OfflineReaderPayload(
            manga: summary.manga,
            chapters: allChapters,
            initialChapter: chapter,
            initialPageIndex: pageIndex
        )
    }
}

private struct OfflineReaderPayload: Identifiable {
    let id = UUID()
    let manga: Manga
    let chapters: [MangaChapter]
    let initialChapter: MangaChapter
    let initialPageIndex: Int?
}
