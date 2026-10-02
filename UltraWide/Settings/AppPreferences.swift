import Foundation

enum AppPreferences {
    static let gridKey = "showCompositionGrid"
    static let hapticsKey = "captureHapticsEnabled"

    static func hapticsEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: hapticsKey) as? Bool ?? true
    }
}
