import Foundation
import CoreGraphics

enum SweepSize: String, CaseIterable, Identifiable {
    case compact, wide, expansive
    var id: String { rawValue }
    var title: String {
        switch self { case .compact: "Large"; case .wide: "Très large"; case .expansive: "Panorama" }
    }
    func degrees(telephoto: Bool) -> Double {
        switch self {
        case .compact: telephoto ? 16 : 25
        case .wide: telephoto ? 28 : 40
        case .expansive: telephoto ? 40 : 55
        }
    }
}

struct CameraLens: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isTelephoto: Bool
    let horizontalFieldOfView: Double
}

struct CapturedFrame: Sendable {
    let data: Data
    let angle: Double
}

struct StitchResult: Sendable {
    let jpeg: Data
    let width: Int
    let height: Int
    let frameCount: Int
}

enum CaptureFailure: LocalizedError {
    case cameraUnavailable, motionUnavailable, capture, insufficientFrames, alignment, excessiveMotion, interrupted, storage

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: "Aucun appareil photo compatible n’est disponible."
        case .motionUnavailable: "Le suivi du mouvement n’est pas disponible sur cet appareil."
        case .capture: "La photo n’a pas pu être prise. Réessayez avec davantage de lumière."
        case .insufficientFrames: "Il faut au moins trois photos. Pivotez un peu plus avant de terminer."
        case .alignment: "Ces photos ne s’alignent pas assez bien. Réessayez sur une scène détaillée et immobile, en pivotant sur place."
        case .excessiveMotion: "Le mouvement était trop important entre deux photos. Recommencez en pivotant plus lentement."
        case .interrupted: "La capture a été interrompue. Vous pouvez recommencer."
        case .storage: "L’image n’a pas pu être enregistrée. Vérifiez l’espace disponible."
        }
    }
}
