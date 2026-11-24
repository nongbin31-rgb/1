import Foundation
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// 本地导入漫画文件格式
public enum LocalMangaFormat: String, Codable, Equatable, Sendable {
    case cbz = "cbz"
    case zip = "zip"
    case pdf = "pdf"

    public var displayTag: String {
        rawValue.uppercased()
    }

    public static func detect(from url: URL) -> LocalMangaFormat? {
        switch url.pathExtension.lowercased() {
        case "cbz": return .cbz
        case "zip": return .zip
        case "pdf": return .pdf
        default: return nil
        }
    }
}

/// 本地漫画章节索引记录
public struct LocalChapterRecord: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let number: Double
    public let zipEntries: [LocalZipImageEntry]
    public let pdfPageCount: Int

    public init(
        id: String,
        title: String,
        number: Double,
        zipEntries: [LocalZipImageEntry] = [],
        pdfPageCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.number = number
        self.zipEntries = zipEntries
        self.pdfPageCount = pdfPageCount
    }
}

/// 已导入本地漫画库的持久化元数据
public struct LocalMangaRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var title: String
    public let format: LocalMangaFormat
    public let archiveFileName: String
    public let fileSizeBytes: Int64
    public let pageCount: Int
    public let chapters: [LocalChapterRecord]
    public let importedAt: Date

    public var chapterCount: Int {
        max(chapters.count, 1)
    }

    public func toManga() -> Manga {
        let formattedSize = ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
        return Manga(
            id: id,
            sourceID: LocalMangaSource.sourceID,
            title: title,
            author: "本地导入",
            coverURL: LocalMangaLibraryManager.coverURLString(for: id),
            coverHeaders: [:],
            summary: "本地 \(format.displayTag) 漫画 · 共 \(chapterCount) 话 · \(pageCount) 页（\(formattedSize)）",
            tags: ["本地", format.displayTag],
            statusText: chapterCount > 1 ? "全 \(chapterCount) 话" : "单本"
        )
    }
}

/// 本地漫画库持久化管理器（CBZ / ZIP / PDF 导入、封面提取、索引缓存与按需图像渲染）
@MainActor
public final class LocalMangaLibraryManager: ObservableObject {
    public static let shared = LocalMangaLibraryManager()

    /// 支持导入的 UniformTypeIdentifier 列表（供 SwiftUI .fileImporter 使用）
    public static var supportedImportContentTypes: [UTType] {
        var types: [UTType] = [.zip, .pdf]
        if let cbzType = UTType(filenameExtension: "cbz") {
            types.insert(cbzType, at: 0)
        }
        return types
    }

    @Published public private(set) var records: [LocalMangaRecord] = []
    @Published public private(set) var isImporting = false

    private let baseDirectory: URL
    private let archivesDirectory: URL
    private let coversDirectory: URL
    private let indexFileURL: URL

    /// 线程安全只读快照盒，供 OnlineImageLoader 后台线程按需解图使用
    private nonisolated let snapshotBox = LocalRecordCacheBox()

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        var base = appSupport.appendingPathComponent("LocalMangaLibrary", isDirectory: true)
        let archives = base.appendingPathComponent("Archives", isDirectory: true)
        let covers = base.appendingPathComponent("Covers", isDirectory: true)

        try? FileManager.default.createDirectory(at: archives, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)

        self.baseDirectory = base
        self.archivesDirectory = archives
        self.coversDirectory = covers
        self.indexFileURL = base.appendingPathComponent("index.json")

        loadIndex()
    }

    // MARK: - Virtual URL Scheme Builders

    public nonisolated static func coverURLString(for mangaID: String) -> String {
        "localmanga://cover/\(mangaID)"
    }

    public nonisolated static func zipPageURLString(mangaID: String, chapterIndex: Int, pageIndex: Int) -> String {
        "localmanga://zip/\(mangaID)/\(chapterIndex)/\(pageIndex)"
    }

    public nonisolated static func pdfPageURLString(mangaID: String, pageIndex: Int) -> String {
        "localmanga://pdf/\(mangaID)/\(pageIndex)"
    }

    // MARK: - Query APIs

    public nonisolated func recordSnapshot(for mangaID: String) -> LocalMangaRecord? {
        snapshotBox.record(for: mangaID)
    }

    public nonisolated func allRecordSnapshots() -> [LocalMangaRecord] {
        snapshotBox.allRecords()
    }

    public func totalDiskSizeBytes() -> Int64 {
        records.reduce(0) { $0 + $1.fileSizeBytes }
    }

    // MARK: - Import & Delete

    /// 批量导入本地 CBZ / ZIP / PDF 文件（自动安全拷贝进沙盒并提取封面）
    public func importFiles(from urls: [URL]) async -> (imported: [Manga], failedNames: [String]) {
        guard !urls.isEmpty else { return ([], []) }
        isImporting = true
        defer { isImporting = false }

        let archivesDir = self.archivesDirectory
        let coversDir = self.coversDirectory

        let results: [(LocalMangaRecord?, String?)] = await Task.detached(priority: .userInitiated) {
            var output: [(LocalMangaRecord?, String?)] = []
            for sourceURL in urls {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let fileName = sourceURL.lastPathComponent
                do {
                    let record = try Self.importSingleFileSync(
                        sourceURL: sourceURL,
                        archivesDir: archivesDir,
                        coversDir: coversDir
                    )
                    output.append((record, nil))
                } catch {
                    output.append((nil, fileName))
                }
            }
            return output
        }.value

        var importedMangas: [Manga] = []
        var failedNames: [String] = []

        for (record, failed) in results {
            if let record {
                records.insert(record, at: 0)
                importedMangas.append(record.toManga())
            } else if let failed {
                failedNames.append(failed)
            }
        }

        if !importedMangas.isEmpty {
            syncSnapshot()
            saveIndex()
        }

        return (importedMangas, failedNames)
    }

    /// 彻底删除单个本地漫画源文件与封面（释放磁盘空间）
    public func deleteRecord(id: String) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        let target = records.remove(at: idx)
        let archiveURL = archivesDirectory.appendingPathComponent(target.archiveFileName)
        let coverURL = coversDirectory.appendingPathComponent("\(target.id).jpg")
        try? FileManager.default.removeItem(at: archiveURL)
        try? FileManager.default.removeItem(at: coverURL)
        syncSnapshot()
        saveIndex()
    }

    /// 清空全部本地漫画源文件
    public func deleteAllRecords() {
        for record in records {
            let archiveURL = archivesDirectory.appendingPathComponent(record.archiveFileName)
            let coverURL = coversDirectory.appendingPathComponent("\(record.id).jpg")
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: coverURL)
        }
        records.removeAll()
        syncSnapshot()
        saveIndex()
    }

    // MARK: - On-Demand Image Rendering (Thread-Safe, Nonisolated)

    #if canImport(UIKit)
    public nonisolated func renderImage(for urlString: String) -> UIImage? {
        guard urlString.hasPrefix("localmanga://") else { return nil }
        let stripped = String(urlString.dropFirst("localmanga://".count))
        let parts = stripped.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let kind = parts[0]
        let mangaID = parts[1]

        switch kind {
        case "cover":
            let coverURL = coversDirectory.appendingPathComponent("\(mangaID).jpg")
            if let data = try? Data(contentsOf: coverURL), let img = UIImage(data: data) {
                return img
            }
            return renderFallbackCover(mangaID: mangaID)

        case "zip":
            guard parts.count >= 4,
                  let chIdx = Int(parts[2]),
                  let pgIdx = Int(parts[3]),
                  let record = recordSnapshot(for: mangaID),
                  record.chapters.indices.contains(chIdx),
                  record.chapters[chIdx].zipEntries.indices.contains(pgIdx) else {
                return nil
            }
            let entry = record.chapters[chIdx].zipEntries[pgIdx]
            let archiveURL = archivesDirectory.appendingPathComponent(record.archiveFileName)
            guard let data = try? LocalZipArchiveReader.extractData(at: archiveURL, entry: entry) else {
                return nil
            }
            return UIImage(data: data)

        case "pdf":
            guard parts.count >= 3,
                  let pgIdx = Int(parts[2]),
                  let record = recordSnapshot(for: mangaID) else {
                return nil
            }
            let archiveURL = archivesDirectory.appendingPathComponent(record.archiveFileName)
            return LocalPDFArchiveReader.renderPage(at: archiveURL, pageIndex: pgIdx, targetLongEdge: 2200)

        default:
            return nil
        }
    }

    private nonisolated func renderFallbackCover(mangaID: String) -> UIImage? {
        guard let record = recordSnapshot(for: mangaID) else { return nil }
        let archiveURL = archivesDirectory.appendingPathComponent(record.archiveFileName)
        switch record.format {
        case .cbz, .zip:
            guard let firstEntry = record.chapters.first?.zipEntries.first,
                  let data = try? LocalZipArchiveReader.extractData(at: archiveURL, entry: firstEntry) else {
                return nil
            }
            return UIImage(data: data)
        case .pdf:
            return LocalPDFArchiveReader.renderPage(at: archiveURL, pageIndex: 0, targetLongEdge: 900)
        }
    }
    #endif

    // MARK: - Internal Import Worker

    private nonisolated static func importSingleFileSync(
        sourceURL: URL,
        archivesDir: URL,
        coversDir: URL
    ) throws -> LocalMangaRecord {
        guard let format = LocalMangaFormat.detect(from: sourceURL) else {
            throw NSError(domain: "LocalManga", code: -1, userInfo: [NSLocalizedDescriptionKey: "不支持的文件格式"])
        }

        let id = UUID().uuidString.lowercased()
        let rawTitle = sourceURL.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? "本地漫画" : rawTitle
        let archiveFileName = "\(id).\(format.rawValue)"
        let destArchiveURL = archivesDir.appendingPathComponent(archiveFileName)

        let fm = FileManager.default
        if fm.fileExists(atPath: destArchiveURL.path) {
            try? fm.removeItem(at: destArchiveURL)
        }
        try fm.copyItem(at: sourceURL, to: destArchiveURL)

        let attrs = try? fm.attributesOfItem(atPath: destArchiveURL.path)
        let fileSizeBytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        let chapters: [LocalChapterRecord]
        let totalPages: Int

        switch format {
        case .cbz, .zip:
            let entries = try LocalZipArchiveReader.listImageEntries(at: destArchiveURL)
            guard !entries.isEmpty else {
                try? fm.removeItem(at: destArchiveURL)
                throw NSError(domain: "LocalManga", code: -2, userInfo: [NSLocalizedDescriptionKey: "压缩包中未发现图片"])
            }
            chapters = buildZipChapters(mangaID: id, entries: entries)
            totalPages = entries.count

            #if canImport(UIKit)
            if let firstEntry = chapters.first?.zipEntries.first,
               let rawData = try? LocalZipArchiveReader.extractData(at: destArchiveURL, entry: firstEntry),
               let img = UIImage(data: rawData) {
                saveCoverThumbnail(img, to: coversDir.appendingPathComponent("\(id).jpg"))
            }
            #endif

        case .pdf:
            let count = LocalPDFArchiveReader.pageCount(at: destArchiveURL)
            guard count > 0 else {
                try? fm.removeItem(at: destArchiveURL)
                throw NSError(domain: "LocalManga", code: -3, userInfo: [NSLocalizedDescriptionKey: "无效或空 PDF 文件"])
            }
            chapters = [
                LocalChapterRecord(
                    id: "\(id)::pdf",
                    title: "全本阅读",
                    number: 1,
                    zipEntries: [],
                    pdfPageCount: count
                )
            ]
            totalPages = count

            #if canImport(UIKit)
            if let coverImg = LocalPDFArchiveReader.renderPage(at: destArchiveURL, pageIndex: 0, targetLongEdge: 900) {
                saveCoverThumbnail(coverImg, to: coversDir.appendingPathComponent("\(id).jpg"))
            }
            #endif
        }

        return LocalMangaRecord(
            id: id,
            title: title,
            format: format,
            archiveFileName: archiveFileName,
            fileSizeBytes: fileSizeBytes,
            pageCount: totalPages,
            chapters: chapters,
            importedAt: Date()
        )
    }

    private nonisolated static func buildZipChapters(
        mangaID: String,
        entries: [LocalZipImageEntry]
    ) -> [LocalChapterRecord] {
        // 按所在文件夹分组；若存在多个不同子文件夹则自动识别为多话章节
        var folderOrder: [String] = []
        var grouped: [String: [LocalZipImageEntry]] = [:]

        for entry in entries {
            let folder = entry.folderName
            if grouped[folder] == nil {
                folderOrder.append(folder)
            }
            grouped[folder, default: []].append(entry)
        }

        let sortedFolders = folderOrder.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if sortedFolders.count <= 1 {
            return [
                LocalChapterRecord(
                    id: "\(mangaID)::ch0",
                    title: "全一话",
                    number: 1,
                    zipEntries: entries
                )
            ]
        }

        return sortedFolders.enumerated().map { idx, folder in
            let folderEntries = (grouped[folder] ?? []).sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
            let displayName: String
            if folder.isEmpty {
                displayName = "第 \(idx + 1) 话"
            } else {
                displayName = (folder as NSString).lastPathComponent
            }
            return LocalChapterRecord(
                id: "\(mangaID)::ch\(idx)",
                title: displayName,
                number: Double(idx + 1),
                zipEntries: folderEntries
            )
        }
    }

    #if canImport(UIKit)
    private nonisolated static func saveCoverThumbnail(_ image: UIImage, to url: URL) {
        let maxLongEdge: CGFloat = 720
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }

        let scale = min(1.0, maxLongEdge / max(size.width, size.height))
        let targetSize = CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let thumb = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        if let jpeg = thumb.jpegData(compressionQuality: 0.84) {
            try? jpeg.write(to: url, options: .atomic)
        }
    }
    #endif

    // MARK: - Persistence

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexFileURL),
              let decoded = try? JSONDecoder().decode([LocalMangaRecord].self, from: data) else {
            records = []
            syncSnapshot()
            return
        }
        // 自动过滤掉磁盘上已丢失源文件的孤立索引
        let valid = decoded.filter {
            FileManager.default.fileExists(atPath: archivesDirectory.appendingPathComponent($0.archiveFileName).path)
        }
        records = valid
        syncSnapshot()
    }

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexFileURL, options: .atomic)
        }
    }

    private func syncSnapshot() {
        snapshotBox.replaceAll(with: records)
    }
}

private final class LocalRecordCacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: LocalMangaRecord] = [:]

    func record(for id: String) -> LocalMangaRecord? {
        lock.lock()
        defer { lock.unlock() }
        return map[id]
    }

    func allRecords() -> [LocalMangaRecord] {
        lock.lock()
        defer { lock.unlock() }
        return Array(map.values).sorted { $0.importedAt > $1.importedAt }
    }

    func replaceAll(with records: [LocalMangaRecord]) {
        let updated = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        lock.lock()
        map = updated
        lock.unlock()
    }
}
