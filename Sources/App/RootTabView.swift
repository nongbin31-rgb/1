import SwiftUI

public enum AppTab: Hashable {
    case bookshelf
    case discover
    case sources
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

            SourceManagementView()
                .tabItem {
                    Label("在线源", systemImage: "network")
                }
                .tag(AppTab.sources)

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "slider.horizontal.3")
                }
                .tag(AppTab.settings)
        }
    }
}
