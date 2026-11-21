import SwiftUI

@main
public struct KedaOnlineReaderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = AppStore()

    public init() {}

    public var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(store)
                .onAppear {
                    store.applyWindowInterfaceStyle()
                }
                .onChange(of: scenePhase) { newPhase in
                    if newPhase == .active {
                        store.applyWindowInterfaceStyle()
                    }
                }
        }
    }
}
