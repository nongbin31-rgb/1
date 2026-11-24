import Compression
import Foundation
import PDFKit
#if canImport(UIKit)
import UIKit
#endif

/// 本地压缩包单条图片目录索引
public struct LocalZipImageEntry: Codable, Equatable, Hashable, Sendable {
    public let path: String
    public let folderName: String
    public let fileName: String
    public let compressionMethod: UInt16
    public let compressedSize: UInt64
    public let uncompressedSize: UInt64
    public let localHeaderOffset: UInt64
}

/// 零第三方依赖只读 CBZ / ZIP 解析器（基于 FileHandle 随机寻址 + Apple 原生 Compression 框架）
/// 特点：
/// 1. 无需整包解压至磁盘，仅解析 Central Directory 目录表；
/// 2. 支持 STORED (0) 与 DEFLATED (8) 两种标准 ZIP 压缩方式；
/// 3. 自动跳过 __MACOSX 与隐藏文件，兼容 UTF-8 / GB18030 / Shift-JIS 文件名并自然排序。
public enum LocalZipArchiveReader {
    private static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif",
    ]

    public enum ZipError: LocalizedError {
        case cannotOpenFile
        case invalidArchive
        case unsupportedCompression(UInt16)
        case decompressionFailed
        case entryNotFound

        public var errorDescription: String? {
            switch self {
            case .cannotOpenFile:
                return "无法打开本地压缩包文件"
            case .invalidArchive:
                return "无效或已损坏的 CBZ / ZIP 文件"
            case .unsupportedCompression(let method):
                return "不支持的 ZIP 压缩算法（method=\(method)）"
            case .decompressionFailed:
                return "ZIP 页面解压失败"
            case .entryNotFound:
                return "压缩包中未找到目标图片页"
            }
        }
    }

    /// 扫描 ZIP / CBZ 内的全部图片条目（按自然顺序排序）
    public static func listImageEntries(at url: URL) throws -> [LocalZipImageEntry] {
        let all = try listAllEntries(at: url)
        var entries = all.filter { isValidImagePath($0.path) }
        entries.sort { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
        return entries
    }

    /// 扫描 ZIP / CBZ / EPUB 内的全部非目录文件条目（支持 STORED 与 DEFLATED）
    public static func listAllEntries(at url: URL) throws -> [LocalZipImageEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.cannotOpenFile
        }
        defer { try? handle.close() }

        let fileSize = try seekToEnd(handle)
        guard fileSize >= 22 else {
            throw ZipError.invalidArchive
        }

        // 从文件末尾最多回溯 65557 字节定位 End of Central Directory (0x06054b50)
        let tailLen = Int(min(fileSize, 65557))
        let tailOffset = fileSize - UInt64(tailLen)
        try seek(handle, to: tailOffset)
        let tailData = try readBytes(handle, count: tailLen)

        guard let eocdRelPos = findSignatureBackward(in: tailData, signature: 0x06054b50) else {
            throw ZipError.invalidArchive
        }

        let totalEntries16 = readUInt16(tailData, at: eocdRelPos + 10)
        let cdSize32 = readUInt32(tailData, at: eocdRelPos + 12)
        let cdOffset32 = readUInt32(tailData, at: eocdRelPos + 16)

        var totalEntries = UInt64(totalEntries16)
        var cdSize = UInt64(cdSize32)
        var cdOffset = UInt64(cdOffset32)

        // 兼容 ZIP64
        if totalEntries16 == 0xFFFF || cdSize32 == 0xFFFFFFFF || cdOffset32 == 0xFFFFFFFF {
            let eocdAbsPos = tailOffset + UInt64(eocdRelPos)
            if eocdAbsPos >= 20 {
                try seek(handle, to: eocdAbsPos - 20)
                let locator = try readBytes(handle, count: 20)
                if locator.count == 20, readUInt32(locator, at: 0) == 0x07064b50 {
                    let zip64EocdOffset = readUInt64(locator, at: 8)
                    if zip64EocdOffset + 56 <= fileSize {
                        try seek(handle, to: zip64EocdOffset)
                        let z64 = try readBytes(handle, count: 56)
                        if z64.count == 56, readUInt32(z64, at: 0) == 0x06064b50 {
                            totalEntries = readUInt64(z64, at: 32)
                            cdSize = readUInt64(z64, at: 40)
                            cdOffset = readUInt64(z64, at: 48)
                        }
                    }
                }
            }
        }

        guard cdSize > 0, cdOffset + cdSize <= fileSize, cdSize <= 64 * 1024 * 1024 else {
            throw ZipError.invalidArchive
        }

        try seek(handle, to: cdOffset)
        let cdData = try readBytes(handle, count: Int(cdSize))

        var entries: [LocalZipImageEntry] = []
        var cursor = 0
        var parsedCount: UInt64 = 0

        while cursor + 46 <= cdData.count && parsedCount < totalEntries {
            guard readUInt32(cdData, at: cursor) == 0x02014b50 else {
                break
            }

            let compressionMethod = readUInt16(cdData, at: cursor + 10)
            var compSize = UInt64(readUInt32(cdData, at: cursor + 20))
            var uncompSize = UInt64(readUInt32(cdData, at: cursor + 24))
            let nameLen = Int(readUInt16(cdData, at: cursor + 28))
            let extraLen = Int(readUInt16(cdData, at: cursor + 30))
            let commentLen = Int(readUInt16(cdData, at: cursor + 32))
            var localHeaderOffset = UInt64(readUInt32(cdData, at: cursor + 42))

            let nameStart = cursor + 46
            let extraStart = nameStart + nameLen
            let nextCursor = extraStart + extraLen + commentLen
            guard nextCursor <= cdData.count else { break }

            let nameBytes = cdData.subdata(in: nameStart..<extraStart)
            let rawPath = decodeEntryPath(nameBytes)

            // 解析 ZIP64 Extra Field (0x0001)
            if extraLen >= 4,
               (uncompSize == 0xFFFFFFFF || compSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF) {
                var ePos = extraStart
                let extraEnd = extraStart + extraLen
                while ePos + 4 <= extraEnd {
                    let headerID = readUInt16(cdData, at: ePos)
                    let dataSize = Int(readUInt16(cdData, at: ePos + 2))
                    let fieldStart = ePos + 4
                    let fieldEnd = fieldStart + dataSize
                    if fieldEnd > extraEnd { break }
                    if headerID == 0x0001 {
                        var fCursor = fieldStart
                        if uncompSize == 0xFFFFFFFF, fCursor + 8 <= fieldEnd {
                            uncompSize = readUInt64(cdData, at: fCursor)
                            fCursor += 8
                        }
                        if compSize == 0xFFFFFFFF, fCursor + 8 <= fieldEnd {
                            compSize = readUInt64(cdData, at: fCursor)
                            fCursor += 8
                        }
                        if localHeaderOffset == 0xFFFFFFFF, fCursor + 8 <= fieldEnd {
                            localHeaderOffset = readUInt64(cdData, at: fCursor)
                        }
                        break
                    }
                    ePos = fieldEnd
                }
            }

            let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
            if !normalized.isEmpty,
               !normalized.hasSuffix("/"),
               (compressionMethod == 0 || compressionMethod == 8) {
                let components = normalized.split(separator: "/").map(String.init)
                let fileName = components.last ?? normalized
                let folderName: String
                if components.count >= 2 {
                    folderName = components.dropLast().joined(separator: "/")
                } else {
                    folderName = ""
                }
                entries.append(
                    LocalZipImageEntry(
                        path: normalized,
                        folderName: folderName,
                        fileName: fileName,
                        compressionMethod: compressionMethod,
                        compressedSize: compSize,
                        uncompressedSize: uncompSize,
                        localHeaderOffset: localHeaderOffset
                    )
                )
            }

            cursor = nextCursor
            parsedCount += 1
        }

        return entries
    }

    /// 随机寻址读取并解压单个图片条目数据
    public static func extractData(at url: URL, entry: LocalZipImageEntry) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.cannotOpenFile
        }
        defer { try? handle.close() }

        try seek(handle, to: entry.localHeaderOffset)
        let localHeader = try readBytes(handle, count: 30)
        guard localHeader.count == 30, readUInt32(localHeader, at: 0) == 0x04034b50 else {
            throw ZipError.invalidArchive
        }

        let localNameLen = UInt64(readUInt16(localHeader, at: 26))
        let localExtraLen = UInt64(readUInt16(localHeader, at: 28))
        let dataOffset = entry.localHeaderOffset + 30 + localNameLen + localExtraLen

        try seek(handle, to: dataOffset)
        let compressedData = try readBytes(handle, count: Int(entry.compressedSize))

        switch entry.compressionMethod {
        case 0:
            return compressedData
        case 8:
            return try inflateRawDeflate(compressedData, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedCompression(entry.compressionMethod)
        }
    }

    // MARK: - Raw Deflate Decompression (Apple Compression)

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard !compressed.isEmpty else { return Data() }

        var dstCapacity = max(expectedSize + 1024, compressed.count * 4, 64 * 1024)
        let maxCapacity = 80 * 1024 * 1024

        while dstCapacity <= maxCapacity {
            var destination = Data(count: dstCapacity)
            let decodedCount: Int = compressed.withUnsafeBytes { srcRaw in
                guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return destination.withUnsafeMutableBytes { dstRaw in
                    guard let dstPtr = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstPtr,
                        dstCapacity,
                        srcPtr,
                        compressed.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                }
            }

            if decodedCount > 0 && decodedCount < dstCapacity {
                destination.count = decodedCount
                return destination
            }

            if decodedCount == expectedSize && expectedSize > 0 {
                destination.count = decodedCount
                return destination
            }

            dstCapacity *= 2
        }

        throw ZipError.decompressionFailed
    }

    // MARK: - Path & Binary Helpers

    static func isValidImagePath(_ rawPath: String) -> Bool {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasSuffix("/") else { return false }
        let parts = normalized.split(separator: "/")
        for part in parts {
            let segment = String(part)
            if segment == "__MACOSX" || segment.hasPrefix(".") {
                return false
            }
        }
        let ext = (normalized as NSString).pathExtension.lowercased()
        return supportedImageExtensions.contains(ext)
    }

    private static func decodeEntryPath(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        )
        if let gbk = String(data: data, encoding: gbkEncoding) {
            return gbk
        }
        if let sjis = String(data: data, encoding: .shiftJIS) {
            return sjis
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    private static func findSignatureBackward(in data: Data, signature: UInt32) -> Int? {
        guard data.count >= 22 else { return nil }
        let b0 = UInt8(signature & 0xFF)
        let b1 = UInt8((signature >> 8) & 0xFF)
        let b2 = UInt8((signature >> 16) & 0xFF)
        let b3 = UInt8((signature >> 24) & 0xFF)

        var idx = data.count - 22
        while idx >= 0 {
            if data[idx] == b0 && data[idx + 1] == b1 && data[idx + 2] == b2 && data[idx + 3] == b3 {
                return idx
            }
            if idx == 0 { break }
            idx -= 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let low = UInt64(readUInt32(data, at: offset))
        let high = UInt64(readUInt32(data, at: offset + 4))
        return low | (high << 32)
    }

    private static func seekToEnd(_ handle: FileHandle) throws -> UInt64 {
        try handle.seekToEnd()
    }

    private static func seek(_ handle: FileHandle, to offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    private static func readBytes(_ handle: FileHandle, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        return try handle.read(upToCount: count) ?? Data()
    }
}

/// 零第三方依赖本地 PDF 解析与高清光栅化引擎（基于原生 PDFKit）
public enum LocalPDFArchiveReader {
    public static func pageCount(at url: URL) -> Int {
        guard let doc = PDFDocument(url: url) else { return 0 }
        return doc.pageCount
    }

    #if canImport(UIKit)
    public static func renderPage(
        at url: URL,
        pageIndex: Int,
        targetLongEdge: CGFloat = 2200
    ) -> UIImage? {
        guard let doc = PDFDocument(url: url),
              pageIndex >= 0,
              pageIndex < doc.pageCount,
              let page = doc.page(at: pageIndex) else {
            return nil
        }

        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        let maxSide = max(bounds.width, bounds.height)
        let scale = min(max(targetLongEdge / maxSide, 1.0), 4.0)
        let renderSize = CGSize(
            width: max(1, (bounds.width * scale).rounded()),
            height: max(1, (bounds.height * scale).rounded())
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: renderSize))

            let cgContext = ctx.cgContext
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: renderSize.height)
            cgContext.scaleBy(x: scale, y: -scale)
            cgContext.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
            cgContext.interpolationQuality = .high
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }
    }
    #endif
}

/// EPUB 漫画解析结果
public struct LocalEPUBParseResult: Sendable {
    public let title: String?
    public let author: String?
    public let coverEntry: LocalZipImageEntry?
    public let orderedPages: [LocalZipImageEntry]
}

/// 零第三方依赖本地 EPUB 漫画解析器（解析 container.xml -> OPF manifest & spine -> XHTML/SVG 图像序列，失败自动降级扫描包内图片）
public enum LocalEPUBArchiveReader {
    private struct ManifestItem {
        let id: String
        let href: String
        let mediaType: String
        let properties: String
    }

    public static func parse(at url: URL) throws -> LocalEPUBParseResult {
        let allEntries = try LocalZipArchiveReader.listAllEntries(at: url)
        var entryByLowerPath: [String: LocalZipImageEntry] = [:]
        entryByLowerPath.reserveCapacity(allEntries.count)
        for entry in allEntries {
            let key = normalizeZipPath(entry.path).lowercased()
            entryByLowerPath[key] = entry
        }

        // 1. 定位 OPF 文件（优先读取 META-INF/container.xml，找不到则直接找包内首个 .opf）
        var opfPath: String?
        if let containerEntry = entryByLowerPath["meta-inf/container.xml"],
           let containerData = try? LocalZipArchiveReader.extractData(at: url, entry: containerEntry),
           let containerXML = String(data: containerData, encoding: .utf8) ?? String(data: containerData, encoding: .isoLatin1) {
            opfPath = extractFirstAttribute(named: "full-path", in: containerXML)
        }
        if opfPath == nil {
            opfPath = allEntries.first(where: { $0.path.lowercased().hasSuffix(".opf") })?.path
        }

        var parsedTitle: String?
        var parsedAuthor: String?
        var coverEntry: LocalZipImageEntry?
        var orderedPages: [LocalZipImageEntry] = []
        var seenPagePaths: Set<String> = []

        if let rawOPFPath = opfPath {
            let normalizedOPF = normalizeZipPath(rawOPFPath)
            if let opfEntry = entryByLowerPath[normalizedOPF.lowercased()],
               let opfData = try? LocalZipArchiveReader.extractData(at: url, entry: opfEntry),
               let opfXML = String(data: opfData, encoding: .utf8) ?? String(data: opfData, encoding: .isoLatin1) {
                let opfDir = parentDirectory(of: normalizedOPF)

                parsedTitle = decodeXMLEntities(extractFirstTagText(tagPattern: "(?:dc:)?title", in: opfXML))
                parsedAuthor = decodeXMLEntities(extractFirstTagText(tagPattern: "(?:dc:)?creator", in: opfXML))

                let manifestItems = parseManifestItems(in: opfXML)
                var manifestByID: [String: ManifestItem] = [:]
                for item in manifestItems {
                    manifestByID[item.id] = item
                }

                // 识别封面图（EPUB3 properties="cover-image" 或 EPUB2 <meta name="cover" content="..."/>）
                if let coverItem = manifestItems.first(where: { $0.properties.lowercased().contains("cover-image") }) {
                    let resolved = resolveRelativePath(coverItem.href, baseDir: opfDir)
                    coverEntry = entryByLowerPath[resolved.lowercased()]
                }
                if coverEntry == nil, let coverMetaID = extractCoverMetaID(in: opfXML),
                   let coverItem = manifestByID[coverMetaID] {
                    let resolved = resolveRelativePath(coverItem.href, baseDir: opfDir)
                    coverEntry = entryByLowerPath[resolved.lowercased()]
                }

                // 按 <spine> 顺序解析每个页面引用的漫画图片
                let spineIDRefs = parseSpineIDRefs(in: opfXML)
                for idref in spineIDRefs {
                    guard let item = manifestByID[idref] else { continue }
                    let resolvedItemPath = resolveRelativePath(item.href, baseDir: opfDir)
                    guard let entry = entryByLowerPath[resolvedItemPath.lowercased()] else { continue }

                    // 某些特殊 EPUB 的 spine 直接指向图片本身
                    if LocalZipArchiveReader.isValidImagePath(entry.path) {
                        let key = entry.path.lowercased()
                        if seenPagePaths.insert(key).inserted {
                            orderedPages.append(entry)
                        }
                        continue
                    }

                    // 标准 EPUB：读取 XHTML/HTML 页面并提取 <img> / <image> 引用
                    guard let xhtmlData = try? LocalZipArchiveReader.extractData(at: url, entry: entry),
                          let xhtml = String(data: xhtmlData, encoding: .utf8) ?? String(data: xhtmlData, encoding: .isoLatin1) else {
                        continue
                    }

                    let pageDir = parentDirectory(of: resolvedItemPath)
                    let imageHrefs = extractImageReferences(in: xhtml)
                    for rawHref in imageHrefs {
                        let resolvedImgPath = resolveRelativePath(rawHref, baseDir: pageDir)
                        if let imgEntry = entryByLowerPath[resolvedImgPath.lowercased()],
                           LocalZipArchiveReader.isValidImagePath(imgEntry.path) {
                            let key = imgEntry.path.lowercased()
                            if seenPagePaths.insert(key).inserted {
                                orderedPages.append(imgEntry)
                            }
                        }
                    }
                }
            }
        }

        // 2. 兜底降级：若 OPF / Spine 未解析到图片，直接扫描包内所有图片自然排序
        if orderedPages.isEmpty {
            var fallback = allEntries.filter { LocalZipArchiveReader.isValidImagePath($0.path) }
            fallback.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            orderedPages = fallback
        }

        if coverEntry == nil {
            coverEntry = orderedPages.first
        } else if let cover = coverEntry, !seenPagePaths.contains(cover.path.lowercased()) {
            // 若封面未包含在 spine 中，保留为封面且不强行污染正文；若正文为空则作为唯一页
            if orderedPages.isEmpty {
                orderedPages = [cover]
            }
        }

        return LocalEPUBParseResult(
            title: parsedTitle?.isEmpty == true ? nil : parsedTitle,
            author: parsedAuthor?.isEmpty == true ? nil : parsedAuthor,
            coverEntry: coverEntry,
            orderedPages: orderedPages
        )
    }

    // MARK: - Lightweight XML / Path Helpers

    private static func parseManifestItems(in xml: String) -> [ManifestItem] {
        guard let regex = try? NSRegularExpression(pattern: "<item\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        var result: [ManifestItem] = []
        result.reserveCapacity(matches.count)

        for match in matches {
            let tag = ns.substring(with: match.range)
            guard let id = extractFirstAttribute(named: "id", in: tag),
                  let href = extractFirstAttribute(named: "href", in: tag) else {
                continue
            }
            let mediaType = extractFirstAttribute(named: "media-type", in: tag) ?? ""
            let properties = extractFirstAttribute(named: "properties", in: tag) ?? ""
            result.append(ManifestItem(id: id, href: href, mediaType: mediaType, properties: properties))
        }
        return result
    }

    private static func parseSpineIDRefs(in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<itemref\\b[^>]*>", options: [.caseInsensitive]) else {
            return []
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let tag = ns.substring(with: match.range)
            return extractFirstAttribute(named: "idref", in: tag)
        }
    }

    private static func extractCoverMetaID(in xml: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]) else {
            return nil
        }
        let ns = xml as NSString
        let matches = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        for match in matches {
            let tag = ns.substring(with: match.range)
            if extractFirstAttribute(named: "name", in: tag)?.lowercased() == "cover",
               let content = extractFirstAttribute(named: "content", in: tag),
               !content.isEmpty {
                return content
            }
        }
        return nil
    }

    private static func extractImageReferences(in xhtml: String) -> [String] {
        // 同时匹配 HTML <img src="..."> 与 SVG <image xlink:href="..."> / <image href="...">
        guard let regex = try? NSRegularExpression(
            pattern: "<(?:img|image)\\b[^>]*>",
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let ns = xhtml as NSString
        let matches = regex.matches(in: xhtml, range: NSRange(location: 0, length: ns.length))
        var refs: [String] = []
        for match in matches {
            let tag = ns.substring(with: match.range)
            if let src = extractFirstAttribute(named: "src", in: tag)
                ?? extractFirstAttribute(named: "xlink:href", in: tag)
                ?? extractFirstAttribute(named: "href", in: tag) {
                let cleaned = decodeXMLEntities(src)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? src
                if !cleaned.isEmpty, !cleaned.hasPrefix("data:") {
                    refs.append(cleaned)
                }
            }
        }
        return refs
    }

    private static func extractFirstTagText(tagPattern: String, in xml: String) -> String? {
        let pattern = "<\(tagPattern)\\b[^>]*>([\\s\\S]*?)</\(tagPattern)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = xml as NSString
        guard let match = regex.firstMatch(in: xml, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else {
            return nil
        }
        let raw = ns.substring(with: match.range(at: 1))
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func extractFirstAttribute(named name: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\\b\(escaped)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        if match.range(at: 1).location != NSNotFound {
            return ns.substring(with: match.range(at: 1))
        }
        if match.range(at: 2).location != NSNotFound {
            return ns.substring(with: match.range(at: 2))
        }
        return nil
    }

    private static func decodeXMLEntities(_ text: String?) -> String? {
        guard var value = text else { return nil }
        value = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeZipPath(_ path: String) -> String {
        let withoutQuery = path.split(separator: "#", maxSplits: 1).first.map(String.init) ?? path
        let clean = withoutQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? withoutQuery
        let decoded = clean.removingPercentEncoding ?? clean
        var parts: [String] = []
        for seg in decoded.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if seg == "." || seg.isEmpty { continue }
            if seg == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(seg))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func parentDirectory(of path: String) -> String {
        let normalized = normalizeZipPath(path)
        guard let lastSlash = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<lastSlash])
    }

    private static func resolveRelativePath(_ href: String, baseDir: String) -> String {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return normalizeZipPath(trimmed)
        }
        if baseDir.isEmpty {
            return normalizeZipPath(trimmed)
        }
        return normalizeZipPath("\(baseDir)/\(trimmed)")
    }
}
