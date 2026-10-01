import Foundation

/// Used under the video cache's lock. An old settings callback cannot validate
/// frames delivered by a later camera configuration.
struct ExposureFrameGate: Sendable {
    private var revision = 0
    private var pending = false
    private var firstAppliedTimestamp: TimeInterval?

    mutating func begin() -> Int {
        revision += 1
        pending = true
        firstAppliedTimestamp = nil
        return revision
    }

    mutating func applied(at timestamp: TimeInterval, revision: Int) {
        guard revision == self.revision, timestamp.isFinite else { return }
        firstAppliedTimestamp = timestamp
        pending = false
    }

    mutating func reset() {
        revision += 1
        pending = false
        firstAppliedTimestamp = nil
    }

    func accepts(_ timestamp: TimeInterval) -> Bool {
        !pending && timestamp.isFinite && timestamp >= (firstAppliedTimestamp ?? -.infinity)
    }

    func isCurrent(_ revision: Int) -> Bool { self.revision == revision }
}
