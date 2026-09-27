import SwiftUI

@main
struct UltraWideApp: App {
    @State private var coordinator = UltraWideCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ui-sweep-preview") {
                UltraWideRootView(model: Self.sweepPreviewModel())
            } else {
                liveView
            }
#else
            liveView
#endif
        }
    }

    private var liveView: some View {
        UltraWideRootView(model: coordinator.ui)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    coordinator.ui.send(.prepare)
                } else {
                    coordinator.ui.send(.pause)
                }
            }
    }

#if DEBUG
    /// Lets the simulator render the camera interface without rear-camera hardware.
    private static func sweepPreviewModel() -> CaptureUIModel {
        let model = CaptureUIModel()
        model.phase = .capturing
        model.sweep = CaptureUISweep(
            viewRect: CGRect(x: 0.45, y: 0.12, width: 0.40, height: 0.46),
            coveredRects: [
                CGRect(x: 0.18, y: 0.28, width: 0.43, height: 0.46),
                CGRect(x: 0.36, y: 0.17, width: 0.43, height: 0.46)
            ],
            coverageFraction: 0.61,
            isRecording: true
        )
        return model
    }
#endif
}
