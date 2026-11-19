import SwiftUI

@main
public struct KedaOnlineReaderApp: App {
    @StateObject private var store = AppStore()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
        }
    }
}
