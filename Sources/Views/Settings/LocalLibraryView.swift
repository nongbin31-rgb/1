import SwiftUI

/// 设置页「本地漫画库」管理视图（查看空间占用、继续导入、一键放回书架、彻底删除本地文件）
public struct LocalLibraryView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var library = LocalMangaLibraryManager.shared

    @State private var showingImporter = false
    @State private var showingClearAllAlert = false
    @State private var pendingDeleteRecord: LocalMangaRecord?
    @State private var noticeText: String?

    public init() {}

    public var body: some View {
        List {
            Section {
                HStack {
                    Label("已导入本地漫画", systemImage: "doc.zipper")
                    Spacer()
                    Text("\(library.records.count) 部 · \(OfflineDownloadManager.formatBytes(library.totalDiskSizeBytes()))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    showingImporter = true
                } label: {
                    HStack {
                        Label("导入本地漫画 (CBZ / ZIP / PDF)", systemImage: "plus.circle.fill")
                        Spacer()
                        if library.isImporting {
                            ProgressView()
                        }
                    }
                }
                .disabled(library.isImporting)
            } footer: {
                Text("支持一次多选导入多个 .cbz、.zip 或 .pdf 文件，也支持在系统「文件」App 中选择用 FristLove 直接打开。导入后无需解压占双倍空间，且完整支持 AI 超分、滤镜与全部翻页特效。")
            }

            if let noticeText {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(noticeText)
                            .font(.footnote)
                        Spacer()
                        Button("关闭") {
                            self.noticeText = nil
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }

            if !library.records.isEmpty {
                Section("本地漫画文件") {
                    ForEach(library.records) { record in
                        let manga = record.toManga()
                        let inShelf = store.isInBookshelf(manga)

                        HStack(spacing: 12) {
                            NavigationLink(destination: MangaDetailView(manga: manga)) {
                                HStack(spacing: 12) {
                                    AsyncMangaCoverView(
                                        urlString: manga.coverURL,
                                        headers: [:],
                                        cornerRadius: 6
                                    )
                                    .frame(width: 44, height: 62)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)

                                        HStack(spacing: 6) {
                                            Text(record.format.displayTag)
                                                .font(.system(size: 10, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                        .fill(Color.accentColor.opacity(0.14))
                                                )
                                                .foregroundColor(.accentColor)

                                            Text("\(record.chapterCount)话 · \(record.pageCount)页 · \(OfflineDownloadManager.formatBytes(record.fileSizeBytes))")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }

                            if !inShelf {
                                Button {
                                    restoreToShelf(record)
                                } label: {
                                    Text("放回书架")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteRecord = record
                            } label: {
                                Label("删除文件", systemImage: "trash")
                            }
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showingClearAllAlert = true
                    } label: {
                        Label("清空全部本地漫画文件", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("本地漫画库")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: LocalMangaLibraryManager.supportedImportContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    let outcome = await store.importLocalMangaFiles(urls: urls)
                    if !outcome.imported.isEmpty {
                        if outcome.failedNames.isEmpty {
                            noticeText = "已导入 \(outcome.imported.count) 部本地漫画并加入书架"
                        } else {
                            noticeText = "成功 \(outcome.imported.count) 部，失败 \(outcome.failedNames.count) 部"
                        }
                    } else if !outcome.failedNames.isEmpty {
                        noticeText = "导入失败：\(outcome.failedNames.joined(separator: "、"))"
                    }
                }
            case .failure(let error):
                noticeText = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .alert(
            "彻底删除「\(pendingDeleteRecord?.title ?? "")」？",
            isPresented: Binding(
                get: { pendingDeleteRecord != nil },
                set: { if !$0 { pendingDeleteRecord = nil } }
            )
        ) {
            Button("取消", role: .cancel) { pendingDeleteRecord = nil }
            Button("彻底删除", role: .destructive) {
                if let target = pendingDeleteRecord {
                    deleteRecordCompletely(target)
                }
                pendingDeleteRecord = nil
            }
        } message: {
            Text("将从设备永久删除该本地漫画文件以释放存储空间，并同步移出书架。")
        }
        .alert("清空全部本地漫画文件？", isPresented: $showingClearAllAlert) {
            Button("取消", role: .cancel) {}
            Button("全部删除", role: .destructive) {
                let keys = Set(library.records.map { $0.toManga().compositeKey })
                store.removeFromBookshelf(keys: keys)
                library.deleteAllRecords()
                noticeText = "已清空全部本地漫画文件"
            }
        } message: {
            Text("将永久删除所有已导入的本地 CBZ / ZIP / PDF 源文件并移出书架，不影响在线收藏。")
        }
    }

    private func restoreToShelf(_ record: LocalMangaRecord) {
        let manga = record.toManga()
        if !store.isInBookshelf(manga) {
            store.toggleBookshelf(manga)
            let chapters = record.chapters.map {
                MangaChapter(id: $0.id, mangaID: record.id, title: $0.title, number: $0.number)
            }
            store.syncBookshelfChapterMeta(manga: manga, chapters: chapters, markUnreadIfIncreased: false)
            noticeText = "已将「\(record.title)」放回书架"
        }
    }

    private func deleteRecordCompletely(_ record: LocalMangaRecord) {
        let key = record.toManga().compositeKey
        store.removeFromBookshelf(keys: [key])
        library.deleteRecord(id: record.id)
        noticeText = "已彻底删除「\(record.title)」"
    }
}
