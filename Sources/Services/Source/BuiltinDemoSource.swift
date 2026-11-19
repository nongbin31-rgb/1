import Foundation

/// 内置在线演示源：
/// 1. 提供模拟低分辨率压缩漫画线稿与网点图（synthetic://），便于离线/零配置直接实测 Waifu2x 与 Anime4K 超分细节对比
/// 2. 提供真实 HTTPS 在线图片章节，用于测试在线流式加载与缓存
public struct BuiltinDemoSource: MangaSourceProtocol {
    public let config: MangaSourceConfig

    public init(config: MangaSourceConfig) {
        self.config = config
    }

    public func fetchPopular(page: Int) async throws -> [Manga] {
        guard page == 1 else { return [] }
        return [
            Manga(
                id: "demo-lineart",
                sourceID: config.id,
                title: "超分画质基准测试 · 线稿与网点",
                author: "内置测试图集",
                coverURL: "synthetic://cover/lineart",
                summary: "专门生成的低分辨率（640×960）带 JPEG 压缩噪点的黑白漫画线稿、斜线、圆弧与对白气泡，最适合对比 Anime4K（AAHQ/BBHQ/CAHQ、细化/加深线稿）与 Waifu2x 的 2x 超分效果。",
                tags: ["线稿测试", "超分对比", "黑白网点"],
                statusText: "内置基准"
            ),
            Manga(
                id: "demo-color",
                sourceID: config.id,
                title: "超分画质基准测试 · 彩漫与渐变",
                author: "内置测试图集",
                coverURL: "synthetic://cover/color",
                summary: "模拟低清彩色条漫与插画色块（600×900），包含高光边界、细线条与渐变阴影，用于检验 Anime4K Clamp_Highlights 与 Waifu2x 动漫/照片降噪表现。",
                tags: ["彩漫测试", "高光钳制", "降噪"],
                statusText: "内置基准"
            ),
            Manga(
                id: "demo-online",
                sourceID: config.id,
                title: "在线图片流式加载示例",
                author: "HTTPS 在线测试",
                coverURL: "https://picsum.photos/id/1018/480/680",
                summary: "通过标准 HTTPS 网络请求实时拉取图片并进入超分管线，用于验证在线图源异步加载、磁盘缓存与边看边超分流程。",
                tags: ["HTTPS", "在线流式", "缓存测试"],
                statusText: "在线源"
            ),
        ]
    }

    public func search(query: String, page: Int) async throws -> [Manga] {
        let all = try await fetchPopular(page: page)
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(keyword)
            || $0.author.localizedCaseInsensitiveContains(keyword)
            || $0.summary.localizedCaseInsensitiveContains(keyword)
            || $0.statusText.localizedCaseInsensitiveContains(keyword)
            || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(keyword) })
        }
    }

    public func fetchChapters(for manga: Manga) async throws -> [MangaChapter] {
        switch manga.id {
        case "demo-lineart":
            return [
                MangaChapter(id: "lineart-ch1", mangaID: manga.id, title: "第 1 话 · 压缩线稿与对白", number: 1, updatedAt: "内置"),
                MangaChapter(id: "lineart-ch2", mangaID: manga.id, title: "第 2 话 · 细密速度线测试", number: 2, updatedAt: "内置"),
            ]
        case "demo-color":
            return [
                MangaChapter(id: "color-ch1", mangaID: manga.id, title: "第 1 话 · 彩漫色块与轮廓", number: 1, updatedAt: "内置"),
            ]
        default:
            return [
                MangaChapter(id: "online-ch1", mangaID: manga.id, title: "第 1 话 · HTTPS 远程图集", number: 1, updatedAt: "在线"),
            ]
        }
    }

    public func fetchPages(for chapter: MangaChapter) async throws -> [MangaPage] {
        switch chapter.id {
        case "lineart-ch1":
            return [
                MangaPage(index: 0, imageURL: "synthetic://page/lineart/1"),
                MangaPage(index: 1, imageURL: "synthetic://page/lineart/2"),
                MangaPage(index: 2, imageURL: "synthetic://page/lineart/3"),
            ]
        case "lineart-ch2":
            return [
                MangaPage(index: 0, imageURL: "synthetic://page/speedline/1"),
                MangaPage(index: 1, imageURL: "synthetic://page/speedline/2"),
            ]
        case "color-ch1":
            return [
                MangaPage(index: 0, imageURL: "synthetic://page/color/1"),
                MangaPage(index: 1, imageURL: "synthetic://page/color/2"),
            ]
        default:
            return [
                MangaPage(index: 0, imageURL: "https://picsum.photos/id/1018/640/960"),
                MangaPage(index: 1, imageURL: "https://picsum.photos/id/1025/640/960"),
                MangaPage(index: 2, imageURL: "https://picsum.photos/id/1039/640/960"),
                MangaPage(index: 3, imageURL: "https://picsum.photos/id/1043/640/960"),
            ]
        }
    }
}
