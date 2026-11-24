import SwiftUI

public enum AppTab: Hashable {
    case bookshelf
    case discover
    case history
    case settings
}

public struct RootTabView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab: AppTab = .discover
    @State private var externalImportBanner: String?
    @State private var bannerDismissTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        TabView(selection: $selectedTab) {
            BookshelfView(selectedTab: $selectedTab)
                .tabItem {
                    Label("书架", systemImage: "books.vertical")
                }
                .tag(AppTab.bookshelf)

            DiscoverView()
                .tabItem {
                    Label("发现", systemImage: "safari")
                }
                .tag(AppTab.discover)

            ReadingHistoryView(selectedTab: $selectedTab)
                .tabItem {
                    Label("足迹", systemImage: "clock.arrow.circlepath")
                }
                .tag(AppTab.history)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .tag(AppTab.settings)
        }
        .overlay(alignment: .top) {
            if let message = externalImportBanner {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.84)))
                .shadow(color: Color.black.opacity(0.24), radius: 10, y: 4)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: externalImportBanner)
        .onOpenURL { url in
            guard url.isFileURL, LocalMangaFormat.detect(from: url) != nil else { return }
            Task {
                let outcome = await store.importLocalMangaFiles(urls: [url])
                if let first = outcome.imported.first {
                    selectedTab = .bookshelf
                    showExternalBanner("已导入本地漫画「\(first.title)」")
                } else {
                    showExternalBanner("外部文件导入失败，请确认格式有效")
                }
            }
        }
    }

    private func showExternalBanner(_ text: String) {
        bannerDismissTask?.cancel()
        externalImportBanner = text
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            externalImportBanner = nil
        }
    }
}
