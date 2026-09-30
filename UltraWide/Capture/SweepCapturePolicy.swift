import Foundation

/// Prefer a sharp sample, but do not keep waiting on scenes whose detail
/// remains below the sharpness threshold even when the phone is steady.
struct SweepCapturePolicy {
    static let minimumFrameInterval = 1.0 / 15.0
    static let maximumAngularSpeed = 1.1
    private static let maximumSoftFrameWait = 0.18
    private var softFrameWaitStartedAt: TimeInterval?

    func allowsSoftFrame(at timestamp: TimeInterval, angularSpeed: Double) -> Bool {
        guard let started = softFrameWaitStartedAt else { return false }
        return timestamp - started >= Self.maximumSoftFrameWait && angularSpeed < 0.35
    }

    mutating func rejected(_ quality: PhotoQualityResult, at timestamp: TimeInterval) {
        if quality.quality == .soft && softFrameWaitStartedAt == nil {
            softFrameWaitStartedAt = timestamp
        }
    }

    mutating func reset() {
        softFrameWaitStartedAt = nil
    }

    static func shouldEncode(_ quality: PhotoQualityResult, allowSoftFrame: Bool) -> Bool {
        // Dark scenes can still provide useful texture. Discard almost black
        // samples rather than making every dark view wait indefinitely.
        guard quality.brightness >= 4.0 / 255.0 || quality.quality == .unknown else {
            return false
        }
        return quality.quality != .soft || allowSoftFrame
    }
}
