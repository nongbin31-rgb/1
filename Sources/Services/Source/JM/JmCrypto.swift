import CommonCrypto
import CryptoKit
import Foundation

/// 在线漫画源 J 移动端 API 签名、AES-256-ECB 响应解密与切片计算工具
public enum JmCrypto {
    public static let defaultAppTokenSecret = "185Hcomic3PAPP7R"
    public static let defaultAppTokenSecret2 = "18comicAPPContent"
    public static let defaultAppDataSecret = "185Hcomic3PAPP7R"
    public static let defaultApiDomainServerSecret = "diosfjckwpqpdfjkvnqQjsik"
    public static let defaultAppVersion = "2.1.13"
    public static let defaultScrambleId = 220980

    public static let defaultUserAgent =
        "Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36"

    public static let apiDomainServerUrls: [String] = [
        "https://rup4a04-c01.tos-ap-southeast-1.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c02.tos-cn-hongkong.bytepluses.com/newsvr-2025.txt",
        "https://rup4a04-c03.tos-cn-beijing.bytepluses.com.cn/newsvr-2025.txt",
    ]

    public static let defaultApiDomains: [String] = [
        "www.cdnutc.cc",
        "www.cdngwc.net",
        "www.cdnutc.me",
        "www.cdnbtd.cc",
        "www.cdngwc.club",
    ]

    public static let defaultImageDomains: [String] = [
        "cdn-msp2.jmapiproxy3.cc",
        "cdn-msp.jmapiproxy3.cc",
        "cdn-msp3.jmapiproxy3.cc",
        "cdn-msp2.jmapiproxy2.cc",
        "cdn-msp.jmapiproxy2.cc",
        "cdn-msp3.jmapiproxy2.cc",
        "cdn-msp.jmapiproxy1.cc",
        "cdn-msp2.jmapiproxy1.cc",
        "cdn-msp3.jmapiproxy1.cc",
    ]

    public static func currentTimestampSeconds() -> Int {
        Int(Date().timeIntervalSince1970)
    }

    public static func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func buildHeaders(
        timestamp ts: Int,
        appVersion: String = defaultAppVersion,
        tokenSecret: String = defaultAppTokenSecret,
        cookie: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "token": md5Hex("\(ts)\(tokenSecret)"),
            "tokenparam": "\(ts),\(appVersion)",
            "User-Agent": defaultUserAgent,
            "Accept": "application/json",
        ]
        if let cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    /// 派生 AES-256-ECB 密钥：md5(seed) 的 32 位小写 hex UTF-8 字节
    public static func deriveAesKey(fromSeed seed: String) -> Data {
        Data(md5Hex(seed).utf8)
    }

    public static func decryptBase64(
        _ encryptedBase64: String,
        keyData: Data
    ) throws -> String {
        let strippedBom = encryptedBase64.replacingOccurrences(of: "\u{FEFF}", with: "")
        let normalized = strippedBom.components(separatedBy: .whitespacesAndNewlines).joined()
        if normalized.isEmpty { return "" }

        guard let cipherData = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]) else {
            throw MangaSourceError.decodingFailed("Base64 密文解码失败")
        }
        guard keyData.count == kCCKeySizeAES256 else {
            throw MangaSourceError.decodingFailed("AES 密钥长度无效：\(keyData.count)")
        }

        let outLength = cipherData.count + kCCBlockSizeAES128
        var plainData = Data(count: outLength)
        var numBytesDecrypted = 0

        let status = plainData.withUnsafeMutableBytes { outPtr in
            cipherData.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyPtr.baseAddress,
                        keyData.count,
                        nil,
                        inPtr.baseAddress,
                        cipherData.count,
                        outPtr.baseAddress,
                        outLength,
                        &numBytesDecrypted
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw MangaSourceError.decodingFailed("AES-256-ECB 解密失败 (CCCrypt=\(status))")
        }

        plainData.removeSubrange(numBytesDecrypted..<plainData.count)
        guard let result = String(data: plainData, encoding: .utf8) else {
            throw MangaSourceError.decodingFailed("明文 UTF-8 解码失败")
        }
        return result
    }

    public static func decryptData(
        _ encryptedBase64: String,
        timestamp ts: Int,
        dataSecret: String = defaultAppDataSecret
    ) throws -> String {
        try decryptBase64(encryptedBase64, keyData: deriveAesKey(fromSeed: "\(ts)\(dataSecret)"))
    }

    public static func decryptDomainServerPayload(
        _ encryptedBase64: String,
        secret: String = defaultApiDomainServerSecret
    ) -> [String] {
        guard let plain = try? decryptBase64(encryptedBase64, keyData: deriveAesKey(fromSeed: secret)) else {
            return []
        }
        return parseDomainServerJson(plain)
    }

    public static func parseDomainServerJson(_ plainJson: String) -> [String] {
        let trimmed = plainJson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var domains: [String] = []
        func addDomain(_ raw: Any?) {
            guard let raw else { return }
            var cleaned = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.lowercased().hasPrefix("https://") {
                cleaned = String(cleaned.dropFirst(8))
            } else if cleaned.lowercased().hasPrefix("http://") {
                cleaned = String(cleaned.dropFirst(7))
            }
            while cleaned.hasSuffix("/") { cleaned.removeLast() }
            if !cleaned.isEmpty, cleaned != "<null>", !domains.contains(cleaned) {
                domains.append(cleaned)
            }
        }

        for key in ["Server", "Setting"] {
            if let list = decoded[key] as? [Any] {
                for item in list { addDomain(item) }
            }
        }

        if let jm3Servers = decoded["jm3_Server"] as? [Any] {
            for item in jm3Servers {
                if let nested = item as? [Any], let first = nested.first {
                    addDomain(first)
                } else {
                    addDomain(item)
                }
            }
        }

        return domains
    }

    /// 计算图片纵向切割块数；返回 0 表示无需还原
    public static func scrambleNum(
        photoId: Int,
        fileStem: String,
        scrambleId: Int = defaultScrambleId
    ) -> Int {
        if photoId < scrambleId { return 0 }
        if photoId < 268850 { return 10 }
        let mod = photoId < 421926 ? 10 : 8
        let hex = md5Hex("\(photoId)\(fileStem)")
        guard let lastByte = hex.utf8.last else { return 0 }
        return (Int(lastByte) % mod) * 2 + 2
    }
}
