import SwiftUI

@main
struct UltraWideApp: App {
    @State private var coordinator = UltraWideCoordinator()

    var body: some Scene {
        WindowGroup {
            UltraWideRootView(model: coordinator.ui)
        }
    }
}
