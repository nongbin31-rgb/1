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

            if isValidImagePath(rawPath), (compressionMethod == 0 || compressionMethod == 8) {
                let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
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
                        path: rawPath,
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

        entries.sort { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
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

    private static func isValidImagePath(_ rawPath: String) -> Bool {
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
