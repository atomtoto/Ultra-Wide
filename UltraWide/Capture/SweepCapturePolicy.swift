import Foundation

/// Texture is a quality score, not a reason to wait for a stationary phone.
/// Only an unusable black buffer or an extreme pose stops selection.
enum SweepCapturePolicy {
    static let minimumFrameInterval = 1.0 / 30.0
    static let maximumAngularSpeed = 2.4
    static let maximumRollDegrees = 20.0

    static func allows(_ reading: MotionReading) -> Bool {
        reading.orientationMatchesConfiguration
            && abs(reading.rollDegrees) < maximumRollDegrees
            && reading.angularSpeed < maximumAngularSpeed
    }

    static func shouldEncode(_ quality: PhotoQualityResult) -> Bool {
        // Dark scenes can still provide useful texture. Discard almost black
        // samples rather than making every dark view wait indefinitely.
        quality.brightness >= 4.0 / 255.0 || quality.quality == .unknown
    }
}
