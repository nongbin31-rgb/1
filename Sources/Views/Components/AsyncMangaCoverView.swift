import SwiftUI

/// 异步在线封面加载视图
public struct AsyncMangaCoverView: View {
    let urlString: String
    var headers: [String: String] = [:]
    var cornerRadius: CGFloat = 10

    @State private var image: UIImage?
    @State private var isLoading = false

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(.secondarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "book.closed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: urlString) {
                guard !urlString.isEmpty else { return }
                isLoading = true
                defer { isLoading = false }
                image = try? await OnlineImageLoader.shared.loadImage(urlString: urlString, headers: headers)
            }
    }
}
