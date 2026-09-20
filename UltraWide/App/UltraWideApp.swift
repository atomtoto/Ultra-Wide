import SwiftUI

@main
struct UltraWideApp: App {
    @StateObject private var model = CaptureModel()
    @StateObject private var library = PanoramaLibrary()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(model)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Palette.mint)
        }
    }
}
