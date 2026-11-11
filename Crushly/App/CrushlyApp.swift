import SwiftUI

@main
struct CrushlyApp: App {
    @State private var state = AppState.make()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
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
