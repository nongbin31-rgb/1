import SwiftUI

public enum AppTab: Hashable {
    case bookshelf
    case discover
    case history
    case settings
}

public struct RootTabView: View {
    @State private var selectedTab: AppTab = .discover

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
    }
}
