import Foundation
import SwiftUI

/// 单话离线缓存持久化记录（包含完整页面清单，支持完全断网秒开阅读器）
public struct OfflineChapterRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let mangaKey: String
    public let manga: Manga
    public let chapter: MangaChapter
    public let pages: [MangaPage]
    public let imageHashes: [String]
    public let totalBytes: Int64
    public let downloadedAt: Date

    public init(
        mangaKey: String,
        manga: Manga,
        chapter: MangaChapter,
        pages: [MangaPage],
        imageHashes: [String],
        totalBytes: Int64,
        downloadedAt: Date = Date()
    ) {
        self.id = Self.makeRecordKey(mangaKey: mangaKey, chapterID: chapter.id)
        self.mangaKey = mangaKey
        self.manga = manga
        self.chapter = chapter
        self.pages = pages
        self.imageHashes = imageHashes
        self.totalBytes = totalBytes
        self.downloadedAt = downloadedAt
    }

    public static func makeRecordKey(mangaKey: String, chapterID: String) -> String {
        "\(mangaKey)::\(chapterID)"
    }
}

/// 章节离线下载任务运行态
public enum ChapterDownloadState: Equatable, Sendable {
    case queued
    case fetchingPages
    case downloading(completed: Int, total: Int)
    case failed(String)

    public var isInProgress: Bool {
        switch self {
        case .queued, .fetchingPages, .downloading:
            return true
        case .failed:
            return false
        }
    }

    public var progressRatio: Double {
        switch self {
        case .queued:
            return 0
        case .fetchingPages:
            return 0.04
        case let .downloading(completed, total):
            guard total > 0 else { return 0 }
            return min(1.0, max(0.0, Double(completed) / Double(total)))
        case .failed:
            return 0
        }
    }

    public var shortStatusText: String {
        switch self {
        case .queued:
            return "排队中"
        case .fetchingPages:
            return "解析中"
        case let .downloading(completed, total):
            guard total > 0 else { return "下载中" }
            return "\(completed)/\(total)"
        case let .failed(message):
            return message
        }
    }
}

/// 在途下载任务条目
public struct ChapterDownloadTaskInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let manga: Manga
    public let chapter: MangaChapter
    public var state: ChapterDownloadState

    public var mangaKey: String { manga.compositeKey }
}

/// 按漫画聚合的离线下载摘要（供设置页离线管理展示）
public struct OfflineMangaSummary: Identifiable, Sendable {
    public let id: String
    public let manga: Manga
    public let chapters: [OfflineChapterRecord]
    public let totalBytes: Int64
    public let latestDownloadedAt: Date
}

/// 全局轻量章节离线缓存下载调度器
/// - 物理存储隔离于 Application Support/OfflineMangaDownloads，不受 iOS Caches 清理与「清理临时缓存」影响
/// - 章节间串行排队、单话内严格限流 3 并发（防 JM / WNACG 图床限流封禁）
/// - 自动落盘 [MangaPage] 清单与封面图，支持彻底断网阅读与断点续传
@MainActor
public final class OfflineDownloadManager: ObservableObject {
    public static let shared = OfflineDownloadManager()

    private struct PendingJob {
        let key: String
        let manga: Manga
        let chapter: MangaChapter
        let adapter: any MangaSourceProtocol
    }

    private struct ManifestPayload: Codable {
        var version: Int = 1
        var records: [OfflineChapterRecord]
    }

    /// 单话内最大并发图片下载数（克制限流，避免触发图床反爬与内存尖峰）
    private let maxConcurrentImagesPerChapter = 3

    @Published public private(set) var downloadedChapters: [String: OfflineChapterRecord] = [:]
    @Published public private(set) var activeTasks: [String: ChapterDownloadTaskInfo] = [:]

    private let manifestURL: URL
    private var pendingQueue: [PendingJob] = []
    private var currentJobKey: String?
    private var currentJobTask: Task<Void, Never>?
    private var isProcessingQueue = false

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var rootDir = appSupport.appendingPathComponent("OfflineMangaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootDir.setResourceValues(values)

        self.manifestURL = rootDir.appendingPathComponent("manifest_v1.json")
        loadManifest()
    }

    // MARK: - 状态查询 API

    public func recordKey(mangaKey: String, chapterID: String) -> String {
        OfflineChapterRecord.makeRecordKey(mangaKey: mangaKey, chapterID: chapterID)
    }

    public func isDownloaded(mangaKey: String, chapterID: String) -> Bool {
        downloadedChapters[recordKey(mangaKey: mangaKey, chapterID: chapterID)] != nil
    }

    public func taskInfo(mangaKey: String, chapterID: String) -> ChapterDownloadTaskInfo? {
        activeTasks[recordKey(mangaKey: mangaKey, chapterID: chapterID)]
    }

    /// 供 ReaderView 离线秒开使用：若本话已离线完成，直接返回持久化的页面清单
    public func offlinePages(mangaKey: String, chapterID: String) -> [MangaPage]? {
        downloadedChapters[recordKey(mangaKey: mangaKey, chapterID: chapterID)]?.pages
    }

    /// 供详情页与书架断网降级使用：返回某漫画全部已离线缓存的章节（按章节序号排序）
    public func offlineChapters(for mangaKey: String) -> [MangaChapter] {
        downloadedChapters.values
            .filter { $0.mangaKey == mangaKey }
            .sorted { lhs, rhs in
                if lhs.chapter.number != rhs.chapter.number {
                    return lhs.chapter.number < rhs.chapter.number
                }
                return lhs.downloadedAt < rhs.downloadedAt
            }
            .map(\.chapter)
    }

    public func downloadedCount(for mangaKey: String) -> Int {
        downloadedChapters.values.reduce(0) { $0 + ($1.mangaKey == mangaKey ? 1 : 0) }
    }

    public func activeTaskCount(for mangaKey: String) -> Int {
        activeTasks.values.reduce(0) { count, info in
            count + (info.mangaKey == mangaKey && info.state.isInProgress ? 1 : 0)
        }
    }

    public var totalDownloadedChapterCount: Int {
        downloadedChapters.count
    }

    public var totalActiveDownloadCount: Int {
        activeTasks.values.filter { $0.state.isInProgress }.count
    }

    public var totalEstimatedBytes: Int64 {
        downloadedChapters.values.reduce(0) { $0 + $1.totalBytes }
    }

    public var groupedDownloadedMangas: [OfflineMangaSummary] {
        let grouped = Dictionary(grouping: downloadedChapters.values, by: \.mangaKey)
        return grouped.compactMap { mangaKey, records in
            guard let latest = records.max(by: { $0.downloadedAt < $1.downloadedAt }) else { return nil }
            let sortedChapters = records.sorted { lhs, rhs in
                if lhs.chapter.number != rhs.chapter.number {
                    return lhs.chapter.number < rhs.chapter.number
                }
                return lhs.downloadedAt < rhs.downloadedAt
            }
            let bytes = records.reduce(Int64(0)) { $0 + $1.totalBytes }
            return OfflineMangaSummary(
                id: mangaKey,
                manga: latest.manga,
                chapters: sortedChapters,
                totalBytes: bytes,
                latestDownloadedAt: latest.downloadedAt
            )
        }
        .sorted { $0.latestDownloadedAt > $1.latestDownloadedAt }
    }

    // MARK: - 下载调度 API

    /// 将单个章节加入离线缓存队列（已下载或在途的章节自动忽略；失败状态可重试）
    public func enqueue(
        manga: Manga,
        chapter: MangaChapter,
        adapter: any MangaSourceProtocol
    ) {
        let key = recordKey(mangaKey: manga.compositeKey, chapterID: chapter.id)
        guard downloadedChapters[key] == nil else { return }

        if let existing = activeTasks[key], existing.state.isInProgress {
            return
        }

        let job = PendingJob(key: key, manga: manga, chapter: chapter, adapter: adapter)
        pendingQueue.removeAll { $0.key == key }
        pendingQueue.append(job)
        activeTasks[key] = ChapterDownloadTaskInfo(
            id: key,
            manga: manga,
            chapter: chapter,
            state: .queued
        )

        kickQueueIfNeeded()
    }

    /// 批量将多个章节加入离线缓存队列（自动跳过已下载或进行中章节）
    @discardableResult
    public func enqueueBatch(
        manga: Manga,
        chapters: [MangaChapter],
        adapter: any MangaSourceProtocol
    ) -> Int {
        var added = 0
        for chapter in chapters {
            let key = recordKey(mangaKey: manga.compositeKey, chapterID: chapter.id)
            if downloadedChapters[key] != nil { continue }
            if let existing = activeTasks[key], existing.state.isInProgress { continue }

            pendingQueue.removeAll { $0.key == key }
            pendingQueue.append(PendingJob(key: key, manga: manga, chapter: chapter, adapter: adapter))
            activeTasks[key] = ChapterDownloadTaskInfo(
                id: key,
                manga: manga,
                chapter: chapter,
                state: .queued
            )
            added += 1
        }
        if added > 0 {
            kickQueueIfNeeded()
        }
        return added
    }

    /// 取消单话下载或清除失败状态
    public func cancelDownload(mangaKey: String, chapterID: String) {
        let key = recordKey(mangaKey: mangaKey, chapterID: chapterID)
        pendingQueue.removeAll { $0.key == key }
        activeTasks.removeValue(forKey: key)

        if currentJobKey == key {
            currentJobTask?.cancel()
        }
    }

    /// 取消指定漫画的所有排队与下载中任务
    public func cancelDownloads(for mangaKey: String) {
        let keysToRemove = activeTasks.values
            .filter { $0.mangaKey == mangaKey }
            .map(\.id)
        pendingQueue.removeAll { $0.manga.compositeKey == mangaKey }
        for key in keysToRemove {
            activeTasks.removeValue(forKey: key)
        }
        if let running = currentJobKey, keysToRemove.contains(running) {
            currentJobTask?.cancel()
        }
    }

    /// 取消全局所有在途下载任务
    public func cancelAllDownloads() {
        pendingQueue.removeAll()
        activeTasks.removeAll()
        currentJobTask?.cancel()
    }

    // MARK: - 删除与孤立文件回收

    /// 删除单话离线缓存，并精确回收不再被其他已下载章节引用的图片文件
    public func deleteChapter(mangaKey: String, chapterID: String) {
        let key = recordKey(mangaKey: mangaKey, chapterID: chapterID)
        cancelDownload(mangaKey: mangaKey, chapterID: chapterID)

        guard let removed = downloadedChapters.removeValue(forKey: key) else { return }
        saveManifest()
        reclaimOrphanImages(candidateHashes: Set(removed.imageHashes))
    }

    /// 删除整本漫画的全部离线章节
    public func deleteManga(mangaKey: String) {
        cancelDownloads(for: mangaKey)

        let keys = downloadedChapters.values
            .filter { $0.mangaKey == mangaKey }
            .map(\.id)
        guard !keys.isEmpty else { return }

        var candidateHashes = Set<String>()
        for key in keys {
            if let removed = downloadedChapters.removeValue(forKey: key) {
                candidateHashes.formUnion(removed.imageHashes)
            }
        }
        saveManifest()
        reclaimOrphanImages(candidateHashes: candidateHashes)
    }

    /// 清空所有离线下载章节与永久图片目录
    public func deleteAllDownloads() {
        cancelAllDownloads()
        downloadedChapters.removeAll()
        saveManifest()
        Task {
            await OnlineImageLoader.shared.clearAllOfflineImages()
        }
    }

    // MARK: - 队列执行内核

    private func kickQueueIfNeeded() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        processNextJob()
    }

    private func processNextJob() {
        guard !pendingQueue.isEmpty else {
            isProcessingQueue = false
            currentJobKey = nil
            currentJobTask = nil
            return
        }

        let job = pendingQueue.removeFirst()
        guard activeTasks[job.key] != nil else {
            processNextJob()
            return
        }

        currentJobKey = job.key
        activeTasks[job.key]?.state = .fetchingPages

        currentJobTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.executeJob(job)
            self.currentJobKey = nil
            self.currentJobTask = nil
            self.processNextJob()
        }
    }

    private func executeJob(_ job: PendingJob) async {
        do {
            try Task.checkCancellation()

            // 1. 拉取章节页面清单
            let pages = try await job.adapter.fetchPages(for: job.chapter)
            try Task.checkCancellation()

            guard !pages.isEmpty else {
                activeTasks[job.key]?.state = .failed("章节无页面")
                return
            }

            let totalCount = pages.count
            activeTasks[job.key]?.state = .downloading(completed: 0, total: totalCount)

            // 2. 顺手持久化封面图，保障断网后书架/详情页封面可读
            var collectedHashes = Set<String>()
            var totalBytes: Int64 = 0
            if !job.manga.coverURL.isEmpty {
                if let coverResult = try? await OnlineImageLoader.shared.downloadImageToOfflineStore(
                    urlString: job.manga.coverURL,
                    headers: job.manga.coverHeaders
                ) {
                    collectedHashes.insert(coverResult.hash)
                }
            }

            // 3. 受控滑动窗口并发下载页面图片（最大并发 = 3，避免图床封 IP）
            let concurrency = maxConcurrentImagesPerChapter
            var completedCount = 0

            try await withThrowingTaskGroup(of: (String, Int64).self) { group in
                var nextPageIdx = 0
                let initialBatch = min(concurrency, totalCount)

                for _ in 0..<initialBatch {
                    let page = pages[nextPageIdx]
                    nextPageIdx += 1
                    group.addTask {
                        let res = try await OnlineImageLoader.shared.downloadImageToOfflineStore(
                            urlString: page.imageURL,
                            headers: page.headers
                        )
                        return (res.hash, res.sizeBytes)
                    }
                }

                while let result = try await group.next() {
                    try Task.checkCancellation()
                    collectedHashes.insert(result.0)
                    totalBytes += result.1
                    completedCount += 1

                    if activeTasks[job.key] != nil {
                        activeTasks[job.key]?.state = .downloading(completed: completedCount, total: totalCount)
                    }

                    if nextPageIdx < totalCount {
                        let page = pages[nextPageIdx]
                        nextPageIdx += 1
                        group.addTask {
                            let res = try await OnlineImageLoader.shared.downloadImageToOfflineStore(
                                urlString: page.imageURL,
                                headers: page.headers
                            )
                            return (res.hash, res.sizeBytes)
                        }
                    }
                }
            }

            try Task.checkCancellation()

            // 4. 全部图片下载成功：写入持久化离线记录并清理在途任务状态
            let record = OfflineChapterRecord(
                mangaKey: job.manga.compositeKey,
                manga: job.manga,
                chapter: job.chapter,
                pages: pages,
                imageHashes: Array(collectedHashes),
                totalBytes: totalBytes,
                downloadedAt: Date()
            )
            downloadedChapters[job.key] = record
            activeTasks.removeValue(forKey: job.key)
            saveManifest()
        } catch is CancellationError {
            activeTasks.removeValue(forKey: job.key)
        } catch {
            if activeTasks[job.key] != nil {
                activeTasks[job.key]?.state = .failed("下载失败")
            }
        }
    }

    // MARK: - 持久化与垃圾回收

    private func reclaimOrphanImages(candidateHashes: Set<String>) {
        guard !candidateHashes.isEmpty else { return }
        var stillReferenced = Set<String>()
        for record in downloadedChapters.values {
            stillReferenced.formUnion(record.imageHashes)
        }
        let orphans = candidateHashes.subtracting(stillReferenced)
        guard !orphans.isEmpty else { return }
        Task {
            await OnlineImageLoader.shared.removeOfflineImages(hashes: orphans)
        }
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestURL),
              let payload = try? JSONDecoder().decode(ManifestPayload.self, from: data) else {
            return
        }
        var map: [String: OfflineChapterRecord] = [:]
        for record in payload.records {
            map[record.id] = record
        }
        self.downloadedChapters = map
    }

    private func saveManifest() {
        let payload = ManifestPayload(records: Array(downloadedChapters.values))
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }
}
