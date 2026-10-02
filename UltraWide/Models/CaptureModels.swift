import CoreGraphics
import Foundation

/// The physical rear camera used for every photograph in a capture session.
enum CaptureLens: String, CaseIterable, Codable, Identifiable, Sendable {
    case wide
    case tele

    var id: String { rawValue }
}

enum CaptureOrientation: String, Codable, Sendable {
    case portrait
    case landscapeLeft
    case landscapeRight

    var isPortrait: Bool { self == .portrait }
}

/// Desired field of view, expressed relative to the main wide camera.
enum CaptureTarget: String, CaseIterable, Codable, Identifiable, Sendable {
    case half
    case threeQuarters
    case one
    case onePointFive
    case two

    var id: String { rawValue }

    var magnification: Double {
        switch self {
        case .half: 0.5
        case .threeQuarters: 0.75
        case .one: 1.0
        case .onePointFive: 1.5
        case .two: 2.0
        }
    }

    var label: String {
        switch self {
        case .half: "0,5×"
        case .threeQuarters: "0,75×"
        case .one: "1×"
        case .onePointFive: "1,5×"
        case .two: "2×"
        }
    }

    /// Zoom required on the selected physical lens to match this field.
    /// Values below one mean that a sweep is needed instead.
    func zoomFactor(wideHorizontalFOV: Double, lensHorizontalFOV: Double) -> Double {
        magnification * tan(lensHorizontalFOV * .pi / 360)
            / tan(wideHorizontalFOV * .pi / 360)
    }
}

struct CapturePlan: Codable, Equatable, Sendable {
    let lens: CaptureLens
    let target: CaptureTarget
    let orientation: CaptureOrientation
    let sourceHorizontalFOV: Double
    let sourceVerticalFOV: Double
    let targetHorizontalFOV: Double
    let targetVerticalFOV: Double
    let columns: Int
    let rows: Int
    let horizontalStep: Double
    let verticalStep: Double

    var expectedFrameCount: Int { rows * columns }

    /// Plans use portrait camera orientation. A nominal 45% overlap gives the
    /// stitcher shared texture without making telephoto sweeps too long.
    static func make(
        lens: CaptureLens,
        target: CaptureTarget,
        orientation: CaptureOrientation = .portrait,
        wideHorizontalFOV: Double,
        lensHorizontalFOV: Double,
        sourceLandscapeAspectRatio: Double = 4.0 / 3.0,
        maximumViews: Int = 30
    ) -> CapturePlan? {
        guard (15...120).contains(wideHorizontalFOV),
              (5...120).contains(lensHorizontalFOV),
              (1.0...2.4).contains(sourceLandscapeAspectRatio),
              maximumViews > 0 else { return nil }

        let landscapeSourceH = lensHorizontalFOV
        let landscapeTargetH = min(125, 2 * atan(tan(wideHorizontalFOV * .pi / 360) / target.magnification) * 180 / .pi)
        let sourceH = orientation.isPortrait
            ? verticalFieldOfView(fromHorizontal: landscapeSourceH, aspect: sourceLandscapeAspectRatio) : landscapeSourceH
        let sourceV = orientation.isPortrait
            ? landscapeSourceH : verticalFieldOfView(fromHorizontal: landscapeSourceH, aspect: sourceLandscapeAspectRatio)
        let targetH = orientation.isPortrait
            ? verticalFieldOfView(fromHorizontal: landscapeTargetH, aspect: 4.0 / 3.0) : landscapeTargetH
        let targetV = orientation.isPortrait
            ? landscapeTargetH : verticalFieldOfView(fromHorizontal: landscapeTargetH, aspect: 4.0 / 3.0)

        func oddCount(target: Double, source: Double) -> Int {
            let needed = max(0, target - source)
            var count = max(3, Int(ceil(needed / (source * 0.55))) + 1)
            if count.isMultiple(of: 2) { count += 1 }
            return count
        }

        let columns = oddCount(target: targetH, source: sourceH)
        let rows = oddCount(target: targetV, source: sourceV)
        guard columns * rows <= maximumViews else { return nil }

        // Keep a little deliberate sweep even when the requested field fits in
        // one photo, so the user still obtains a fused result.
        let horizontalSpan = max(targetH - sourceH, min(12, sourceH * 0.25))
        let verticalSpan = max(targetV - sourceV, min(9, sourceV * 0.25))
        return CapturePlan(
            lens: lens,
            target: target,
            orientation: orientation,
            sourceHorizontalFOV: sourceH,
            sourceVerticalFOV: sourceV,
            targetHorizontalFOV: targetH,
            targetVerticalFOV: targetV,
            columns: columns,
            rows: rows,
            horizontalStep: horizontalSpan / Double(columns - 1),
            verticalStep: verticalSpan / Double(rows - 1)
        )
    }

    private static func verticalFieldOfView(fromHorizontal horizontal: Double, aspect: Double) -> Double {
        2 * atan(tan(horizontal * .pi / 360) / aspect) * 180 / .pi
    }

    func makeSlots() -> [CaptureSlot] {
        let centerColumn = columns / 2
        let centerRow = rows / 2
        let cells = (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CaptureSlot(
                    id: "r\(row)c\(column)",
                    row: row,
                    column: column,
                    yawDegrees: Double(column - centerColumn) * horizontalStep,
                    pitchDegrees: Double(centerRow - row) * verticalStep,
                    frame: nil
                )
            }
        }
        // Start at the reference view, then move to nearby views. This keeps
        // adjacent images connected even if the session is interrupted.
        return cells.sorted {
            let lhsRadius = abs($0.row - centerRow) + abs($0.column - centerColumn)
            let rhsRadius = abs($1.row - centerRow) + abs($1.column - centerColumn)
            if lhsRadius != rhsRadius { return lhsRadius < rhsRadius }
            if $0.row != $1.row { return $0.row < $1.row }
            return $0.column < $1.column
        }
    }
}

enum CaptureQuality: String, Codable, Sendable {
    case good
    case soft
    case dark
    case unknown
}

struct CapturedFrame: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let slotID: String
    let fileURL: URL
    let pass: Int
    let capturedAt: Date
    let yawDegrees: Double
    let pitchDegrees: Double
    let rollDegrees: Double
    let sharpnessScore: Double
    let meanBrightness: Double
    let quality: CaptureQuality
}

struct CaptureSlot: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let row: Int
    let column: Int
    let yawDegrees: Double
    let pitchDegrees: Double
    var frame: CapturedFrame?
}

struct CaptureSessionSnapshot: Codable, Equatable, Sendable {
    let sessionID: UUID
    let plan: CapturePlan
    var slots: [CaptureSlot]
    var currentPass: Int
    var isPassOpen: Bool
    var retakeCount: Int
    /// Optional so sessions created by earlier app versions remain readable.
    var coverageFraction: Double?
    let createdAt: Date
    var updatedAt: Date

    var frames: [CapturedFrame] { slots.compactMap(\.frame) }
    var missingSlotIDs: [String] { slots.filter { $0.frame == nil }.map(\.id) }
    var isComplete: Bool {
        if let coverageFraction { return coverageFraction >= CaptureCoverage.completionThreshold && frames.count >= 2 }
        return missingSlotIDs.isEmpty && frames.count >= 2
    }
    var suggestedRefinementSlotIDs: [String] {
        slots.filter { $0.frame?.quality == .soft || $0.frame?.quality == .dark }.map(\.id)
    }
}

/// Geometry is relative to the requested result, with (0, 0) at its top left.
/// Rectangles can slightly extend outside 0...1: that overscan protects edges.
struct CaptureCoverage: Equatable, Sendable {
    /// Numerical tolerance only: a small missing corner must remain incomplete.
    static let completionThreshold = 1 - 1e-10
    let viewRect: CGRect
    let coveredRects: [CGRect]
    let fraction: Double
}

struct CaptureGuidance: Equatable, Sendable {
    let slotID: String
    /// Positive horizontal error asks the user to turn the phone to the right.
    let horizontalErrorDegrees: Double
    /// Positive vertical error asks the user to tilt the phone upward.
    let verticalErrorDegrees: Double
    let rollDegrees: Double
    /// False when the phone has been turned away from the orientation fixed
    /// at the beginning of the session.
    let isOrientationValid: Bool
    let isAligned: Bool
    let isStable: Bool
    let actualYawDegrees: Double
    let actualPitchDegrees: Double

    var canCapture: Bool { isOrientationValid && isAligned && isStable }
}

enum CaptureStatus: Equatable, Sendable {
    case idle
    case preparing
    case recalibrating
    case ready
    case capturing
    case reviewing
    case paused
    case failed(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum CaptureError: LocalizedError, Equatable, Sendable {
    case cameraPermissionDenied
    case cameraUnavailable
    case lensUnavailable
    case targetUnavailable
    case cameraConfigurationFailed
    case motionUnavailable
    case notReady
    case notAligned
    case orientationChanged
    case excessiveRoll
    case noCurrentSlot
    case incompletePass
    case retakeLimitReached
    case invalidSlot
    case noSavedSession
    case corruptSavedSession
    case photoDataUnavailable
    case diskWriteFailed

    var errorDescription: String? {
        switch self {
        case .cameraPermissionDenied: "Autorisez l’accès à l’appareil photo dans Réglages."
        case .cameraUnavailable: "L’appareil photo est momentanément indisponible."
        case .lensUnavailable: "Cet objectif n’est pas disponible sur cet iPhone."
        case .targetUnavailable: "Ce cadrage demanderait trop de prises avec cet objectif."
        case .cameraConfigurationFailed: "Impossible de préparer l’appareil photo."
        case .motionUnavailable: "Les capteurs de mouvement sont indisponibles."
        case .notReady: "La prise de vue n’est pas prête."
        case .notAligned: "Alignez le repère et immobilisez l’iPhone."
        case .orientationChanged: "Tenez l’iPhone dans l’orientation du cadre affiché."
        case .excessiveRoll: "Redressez l’iPhone pour garder le cadre droit."
        case .noCurrentSlot: "Aucune vue n’est disponible."
        case .incompletePass: "Balayez un peu plus avant d’arrêter."
        case .retakeLimitReached: "La limite de 60 images est atteinte. Recommencez une prise."
        case .invalidSlot: "Cette vue n’appartient pas à la session."
        case .noSavedSession: "Aucune session à reprendre."
        case .corruptSavedSession: "La session enregistrée est incomplète."
        case .photoDataUnavailable: "Une image du flux vidéo n’a pas pu être lue."
        case .diskWriteFailed: "L’image n’a pas pu être enregistrée sur l’iPhone."
        }
    }
}
