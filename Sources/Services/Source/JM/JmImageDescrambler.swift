import CoreGraphics
import Foundation
import UIKit

/// 分块图片元数据（从 URL fragment 解析）
public struct JmImageMeta: Sendable {
    public let cleanURL: String
    public let photoId: Int
    public let scrambleId: Int
    public let fileStem: String
    public let fileExtension: String

    public var scrambleNum: Int {
        JmCrypto.scrambleNum(photoId: photoId, fileStem: fileStem, scrambleId: scrambleId)
    }

    public static func tryParse(_ urlString: String) -> JmImageMeta? {
        guard let components = URLComponents(string: urlString),
              let fragment = components.fragment,
              fragment.hasPrefix("jm=") else {
            return nil
        }

        let payload = String(fragment.dropFirst(3))
        let parts = payload.split(separator: ",")
        guard let firstPart = parts.first,
              let photoId = Int(firstPart),
              photoId > 0 else {
            return nil
        }

        let scrambleId: Int
        if parts.count > 1, let parsedScramble = Int(parts[1]) {
            scrambleId = parsedScramble
        } else {
            scrambleId = JmCrypto.defaultScrambleId
        }

        var cleanComps = components
        cleanComps.fragment = nil
        let cleanURL = cleanComps.string ?? urlString.components(separatedBy: "#").first ?? urlString

        let path = components.path
        let nsFileName = (path as NSString).lastPathComponent
        let fileName = nsFileName.isEmpty ? "image.jpg" : nsFileName
        let ext = (fileName as NSString).pathExtension.lowercased()
        let fileExtension = ext.isEmpty ? ".jpg" : ".\(ext)"
        let fileStem = (fileName as NSString).deletingPathExtension

        return JmImageMeta(
            cleanURL: cleanURL,
            photoId: photoId,
            scrambleId: scrambleId,
            fileStem: fileStem,
            fileExtension: fileExtension
        )
    }
}

/// 图片切片还原器（基于 CoreGraphics 块级拷贝）
public enum JmImageDescrambler {
    public static func descrambleIfNeeded(
        data: Data,
        meta: JmImageMeta?
    ) -> (image: UIImage, cacheData: Data)? {
        guard let rawImage = UIImage(data: data) else { return nil }
        guard let meta else {
            return (rawImage, data)
        }
        let num = meta.scrambleNum
        if num <= 1 || meta.fileExtension == ".gif" {
            return (rawImage, data)
        }

        guard let restored = descramble(image: rawImage, num: num) else {
            return (rawImage, data)
        }

        let encodedData: Data
        if meta.fileExtension == ".png", let png = restored.pngData() {
            encodedData = png
        } else if let jpg = restored.jpegData(compressionQuality: 0.88) {
            encodedData = jpg
        } else {
            encodedData = data
        }
        return (restored, encodedData)
    }

    public static func descramble(image: UIImage, num: Int) -> UIImage? {
        if num <= 1 { return image }
        guard let srcCG = image.cgImage else { return image }

        let w = srcCG.width
        let h = srcCG.height
        guard w > 0, h > 0, h >= num else { return image }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return image
        }

        let over = h % num
        let baseMove = h / num

        for i in 0..<num {
            var move = baseMove
            // top-down 坐标：源图从下往上取切片
            let ySrcTop = h - move * (i + 1) - over
            var yDstTop = move * i
            if i == 0 {
                move += over
            } else {
                yDstTop += over
            }

            // CGImage.cropping(to:) 使用左上角原点；CGContext.draw(in:) 使用左下角原点
            let cropRect = CGRect(x: 0, y: ySrcTop, width: w, height: move)
            guard let slice = srcCG.cropping(to: cropRect) else { continue }
            let cgDstY = h - yDstTop - move
            let dstRect = CGRect(x: 0, y: cgDstY, width: w, height: move)
            ctx.draw(slice, in: dstRect)
        }

        guard let outCG = ctx.makeImage() else { return image }
        return UIImage(cgImage: outCG, scale: image.scale, orientation: .up)
    }
}
