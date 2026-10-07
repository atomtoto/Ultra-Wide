import AVFoundation
import Observation
import UIKit

/// Presentation state consumed by the SwiftUI camera. The capture pipeline owns
/// the camera, motion sensor, stitching, and photo-library operations; the UI
/// only sends user intentions through `onAction`.
@MainActor
@Observable
final class CaptureUIModel {
    var phase: CaptureUIPhase = .setup
    var previewSession: AVCaptureSession?
    /// AVFoundation rotation angle fixed when the capture plan starts.
    var previewRotationAngle: CGFloat = 90
    /// Upright, screen-sized thumbnail of the central reference photo.
    var reanchorImage: UIImage?

    var selectedLens: CaptureLens = .wide
    var availableLenses: [CaptureLens] = [.wide]
    var selectedTarget: CaptureTarget = .half
    var availableTargets: [CaptureTarget] = [.half]
    var selectedLighting: CaptureLighting = .saved()
    var isSinglePhoto = false
    var isStarting = false
    var canAdjustCamera = false
    var exposureBias: Double = 0

    /// Angles normalized into the desired final field of view. Updated by the
    /// continuous sweep pipeline and rendered without exposing capture slots.
    var sweep = CaptureUISweep()
    /// Increases each time verified coverage grows noticeably. The view plays
    /// a selection haptic on change, when the photographer enabled haptics.
    var coverageFeedbackCount = 0

    var processingProgress: Double?
    var resultPreview: UIImage?
    var resultURL: URL?
    var resultPixelSize: CGSize?
    var resultWasCropped = false
    var resultMagnification: Double?
    var saveState: CaptureUISaveState = .idle

    var issue: CaptureUIIssue?
    /// Already localized guidance, such as an orientation correction.
    var banner: String?
    /// A capture already owns its lens and target, including while resuming.
    var hasActiveSession = false
    var hasRecoverableSession = false

    @ObservationIgnored var onAction: ((CaptureUIAction) -> Void)?

    func send(_ action: CaptureUIAction) {
        switch action {
        case .selectLens(let lens):
            selectedLens = lens
            // The new lens may support a different set of target fields.
            availableTargets = []
        case .selectTarget(let target): selectedTarget = target
        case .selectLighting(let lighting):
            guard phase == .setup, !hasActiveSession, !isStarting,
                  selectedLighting != lighting else { return }
            selectedLighting = lighting
        case .setExposureBias(let bias):
            guard canAdjustCamera, !isStarting, bias.isFinite else { return }
            exposureBias = min(2, max(-2, bias))
        case .setMeteringPoint:
            guard canAdjustCamera, !isStarting else { return }
        case .startSweep, .resume, .retry, .confirmReanchor:
            isStarting = true
        case .assemble, .useCapturedField:
            phase = .processing
        default: break
        }
        onAction?(action)
    }
}

enum CaptureUIPhase: Equatable {
    case setup
    case reanchor
    case capturing
    case passReview
    case processing
    case review
    case permission
    case unavailable
}

struct CaptureUISweep: Equatable {
    /// Current camera field of view inside the final field, in 0...1 units.
    var viewRect: CGRect = CGRect(x: 0.31, y: 0.31, width: 0.38, height: 0.38)
    /// Footprints whose image alignment has been checked, in 0...1 units.
    var coveredPolygons: [[CGPoint]] = []
    /// Progressive image assembled in the desired final field of view.
    var previewImage: UIImage?
    var coverageFraction: Double = 0
    var isRecording = false
    var isComplete = false
    var isFinishing = false
    var isVerifyingAlignment = false
    var missingTarget: CGPoint?
    var guidanceDirection: CGVector?
    var capturedField: CGRect?
    var blockReason: SweepCaptureBlockReason?
}

enum SweepCaptureBlockReason: Equatable, Sendable {
    case tooFast, tooDark, awaitingCamera, writing, insufficientDetail, alignmentFailed
}

enum CaptureUISaveState: Equatable {
    case idle
    case saving
    case saved
}

struct CaptureUIIssue {
    enum Kind {
        case cameraPermission
        case motionPermission
        case cameraUnavailable
        case captureFailure
        case stitchingFailure
        case photoLibraryPermission
        case saveFailure
    }

    var kind: Kind
    /// Already localized explanation shown below the issue title.
    var detail: String?
    var canRetry = false
}

enum CaptureUIAction {
    case prepare
    case selectLens(CaptureLens)
    case selectTarget(CaptureTarget)
    case selectLighting(CaptureLighting)
    case setMeteringPoint(CGPoint)
    case setExposureBias(Double)
    case startSweep
    case stopSweep
    case resume
    case confirmReanchor
    case assemble
    case useCapturedField
    case continueAfterCrop
    case pause
    case discard
    case saveToPhotos
    case retry
}

extension CaptureLens {
    var title: LocalizedStringResource {
        switch self {
        case .wide: "Main"
        case .tele: "Tele"
        }
    }
}

extension CaptureLighting {
    var title: LocalizedStringResource {
        switch self {
        case .automatic: "Auto (Region)"
        case .hz50: "50 Hz"
        case .hz60: "60 Hz"
        }
    }
}
