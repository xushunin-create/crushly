import SwiftUI

@main
struct CrushlyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                // App-switcher privacy cover: hides chats and profiles whenever the scene isn't active.
                .overlay { if scenePhase != .active { PrivacyCover().transition(.opacity) } }
                .task { await state.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await state.sceneBecameActive() }
                    case .background: state.sceneWentBackground()
                    default: break
                    }
                }
        }
    }
}
