import Foundation

enum AppPreferences {
    static let gridKey = "showCompositionGrid"
    static let hapticsKey = "captureHapticsEnabled"
    static let outputResolutionKey = "outputResolutionMegapixels"

    static func outputResolution(defaults: UserDefaults = .standard) -> OutputResolution {
        OutputResolution(rawValue: defaults.integer(forKey: outputResolutionKey)) ?? .mp16
    }

    static func hapticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hapticsKey) as? Bool ?? true
    }
}

/// A pixel budget, bounded by source detail and the assembler's memory limit.
enum OutputResolution: Int, CaseIterable, Identifiable, Sendable {
    case mp4 = 4
    case mp8 = 8
    case mp12 = 12
    case mp16 = 16
    case mp24 = 24
    case mp48 = 48

    var id: Int { rawValue }
}
