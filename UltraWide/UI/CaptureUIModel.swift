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

    var selectedLens: CaptureUILens = .wide
    var availableLenses: [CaptureUILens] = [.wide]
    var selectedTarget: CaptureUITarget = .half
    var availableTargets: [CaptureUITarget] = [.half]
    var selectedLighting: CaptureLighting = .saved()
    var isSinglePhoto = false
    var estimatedPhotos = 9
    var isStarting = false

    var currentPass = 1
    var capturedPhotos = 0
    var plannedPhotos = 0
    var maximumPhotos = 30
    var refinementPhotos = 0
    var maximumRefinementPhotos = 6
    var remainingRetakes = 6
    var guidance = CaptureUIGuidance()
    var coverage: [CaptureUICoverageCell] = []
    /// Angles normalized into the desired final field of view. Updated by the
    /// continuous sweep pipeline and rendered without exposing capture slots.
    var sweep = CaptureUISweep()
    var canCapture = false
    var canFinishPass = false
    var canRefine = false

    var processingProgress: Double?
    var resultPreview: UIImage?
    var resultURL: URL?
    var resultPixelSize: CGSize?
    var saveState: CaptureUISaveState = .idle

    var issue: CaptureUIIssue?
    var banner: CaptureUIMessage?
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
        case .start, .startSweep, .resume, .retry, .confirmReanchor:
            isStarting = true
        case .finishPass:
            canFinishPass = false
        case .beginRefinementPass:
            canRefine = false
            isStarting = true
        case .assemble:
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

enum CaptureUILens: String, CaseIterable, Identifiable, Equatable {
    case wide
    case tele

    var id: String { rawValue }
}

enum CaptureUITarget: String, CaseIterable, Identifiable, Equatable {
    case half
    case threeQuarters
    case one
    case onePointFive
    case two

    var id: String { rawValue }

    func magnification(for locale: Locale) -> String {
        let separator = locale.captureLanguageIsFrench ? "," : "."
        return switch self {
        case .half: "0\(separator)5×"
        case .threeQuarters: "0\(separator)75×"
        case .one: "1×"
        case .onePointFive: "1\(separator)5×"
        case .two: "2×"
        }
    }
}

struct CaptureUIGuidance {
    /// Target position relative to the center of the live preview, in -1...1.
    var hasTarget = false
    var horizontalOffset: Double = 0
    var verticalOffset: Double = 0
    var isAligned = false
    var isStable = false
    var isCapturing = false
    var isAutoCaptureEnabled = true
}

struct CaptureUISweep {
    /// Current camera field of view inside the final field, in 0...1 units.
    var viewRect: CGRect = CGRect(x: 0.31, y: 0.31, width: 0.38, height: 0.38)
    /// Regions already captured with usable overlap, in the same coordinates.
    var coveredRects: [CGRect] = []
    /// Footprints whose image alignment has been checked, in 0...1 units.
    var coveredPolygons: [[CGPoint]] = []
    /// Progressive image assembled in the desired final field of view.
    var previewImage: UIImage?
    var coverageFraction: Double = 0
    var isRecording = false
    var isComplete = false
    var isFinishing = false
    var isVerifyingAlignment = false
}

struct CaptureUICoverageCell: Identifiable {
    enum State: Equatable {
        case pending
        case current
        case captured
        case needsRetake
    }

    var id: String
    var row: Int
    var column: Int
    var state: State
}

enum CaptureUISaveState: Equatable {
    case idle
    case saving
    case saved
}

struct CaptureUIMessage {
    var french: String
    var english: String

    func text(for locale: Locale) -> String {
        locale.captureLanguageIsFrench ? french : english
    }
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
    var detail: CaptureUIMessage?
    var canRetry = false
}

enum CaptureUIAction {
    case prepare
    case selectLens(CaptureUILens)
    case selectTarget(CaptureUITarget)
    case selectLighting(CaptureLighting)
    case start
    case startSweep
    case stopSweep
    case resume
    case confirmReanchor
    case capture
    case finishPass
    case beginRefinementPass
    case assemble
    case retake(String)
    case pause
    case discard
    case newCapture
    case saveToPhotos
    case retry
    case openSettings
}

extension Locale {
    var captureLanguageIsFrench: Bool {
        language.languageCode?.identifier == "fr"
    }
}
