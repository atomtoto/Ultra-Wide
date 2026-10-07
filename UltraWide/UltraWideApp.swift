import SwiftUI
import AVFoundation
import UIKit

@main
struct UltraWideApp: App {
    @State private var coordinator = UltraWideCoordinator()
#if DEBUG
    @State private var previewModel = Self.requestedPreviewModel()
#endif
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let previewModel {
                UltraWideRootView(model: previewModel)
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
    private static func requestedPreviewModel() -> CaptureUIModel? {
        let args = ProcessInfo.processInfo.arguments
        let previews = ["-ui-sweep-preview", "-ui-crop-preview", "-ui-review-preview",
                        "-ui-camera-preview", "-ui-settings-preview", "-ui-exposure-preview"]
        guard args.contains(where: previews.contains) else { return nil }
        let model = CaptureUIModel()
        model.phase = .capturing
        model.hasActiveSession = true
        model.sweep = CaptureUISweep(
            viewRect: CGRect(x: 0.45, y: 0.12, width: 0.40, height: 0.46),
            coveredPolygons: [
                [CGPoint(x: 0.18, y: 0.28), CGPoint(x: 0.61, y: 0.28),
                 CGPoint(x: 0.61, y: 0.74), CGPoint(x: 0.18, y: 0.74)],
                [CGPoint(x: 0.36, y: 0.17), CGPoint(x: 0.79, y: 0.17),
                 CGPoint(x: 0.79, y: 0.63), CGPoint(x: 0.36, y: 0.63)]
            ],
            coverageFraction: 0.61,
            isRecording: true,
            guidanceDirection: CGVector(dx: -0.4, dy: 0.35)
        )
        if args.contains("-ui-crop-preview") {
            let polygons = [[CGPoint(x: -0.1, y: -0.1), CGPoint(x: 0.96, y: -0.1),
                             CGPoint(x: 0.96, y: 1.1), CGPoint(x: -0.1, y: 1.1)],
                            [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.7, y: 0.1),
                             CGPoint(x: 0.7, y: 0.9), CGPoint(x: 0.1, y: 0.9)]]
            let coverage = VisualSweepCoverage(polygons: polygons)
            model.phase = .passReview
            model.sweep.coveredPolygons = polygons
            model.sweep.coverageFraction = coverage.fraction
            model.sweep.isRecording = false
            model.sweep.capturedField = SweepCoverageAnalysis(coverage: coverage).capturedField?.rect
        }
        if args.contains("-ui-camera-preview") || args.contains("-ui-settings-preview")
            || args.contains("-ui-exposure-preview") {
            model.phase = .setup
            model.hasActiveSession = false
            model.previewSession = AVCaptureSession()
            model.canAdjustCamera = true
            model.availableLenses = [.wide, .tele]
            model.availableTargets = [.half, .threeQuarters, .one, .onePointFive, .two]
        }
        if args.contains("-ui-review-preview") { configureReviewPreview(model) }
        model.onAction = { action in
            switch action {
            case .useCapturedField: configureReviewPreview(model); model.resultWasCropped = true; model.resultMagnification = 0.58
            case .startSweep, .continueAfterCrop: model.phase = .capturing; model.hasActiveSession = true; model.isStarting = false; model.canAdjustCamera = false
            case .stopSweep: model.phase = .passReview; model.sweep.isRecording = false
            case .saveToPhotos: model.saveState = .saved
            default: break
            }
        }
        return model
    }

    private static func configureReviewPreview(_ model: CaptureUIModel) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 3072, height: 2048)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.12, green: 0.27, blue: 0.32, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for index in 0..<96 {
                UIColor(white: index % 2 == 0 ? 0.85 : 0.12, alpha: 1).setFill()
                context.fill(CGRect(x: 500 + index * 8, y: 600, width: 8, height: 800))
            }
            for index in 0..<40 {
                UIColor(red: 0.8, green: 0.5, blue: 0.16, alpha: 1).setStroke()
                context.cgContext.strokeEllipse(in: CGRect(x: 1800 - index * 5, y: 900 - index * 5,
                    width: 20 + index * 10, height: 20 + index * 10))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("review-preview.jpg")
        try? image.jpegData(compressionQuality: 0.95)?.write(to: url, options: .atomic)
        model.phase = .review
        model.resultURL = url
        model.resultPreview = image
        model.resultPixelSize = size
    }
#endif
}
