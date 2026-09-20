import Foundation

/// Pure capture policy, independent of Core Motion and the camera hardware.
struct SweepTracker {
    let target: Double
    let step: Double
    private(set) var direction: Double = 0
    private(set) var lastCapture: Double = 0
    private(set) var furthest: Double = 0

    var progress: Double { min(1, max(0, furthest / target)) }

    mutating func update(angle: Double) {
        if direction == 0, abs(angle) > 2 { direction = angle > 0 ? 1 : -1 }
        if direction != 0 { furthest = max(furthest, angle * direction) }
    }

    func shouldCapture(angle: Double) -> Bool {
        let distance = angle * direction - lastCapture
        return direction != 0 && (distance >= step || (angle * direction >= target && distance >= step * 0.25))
    }

    func gap(angle: Double) -> Double { max(0, angle * direction - lastCapture) }
    func isReversing(angle: Double) -> Bool { direction != 0 && angle * direction < furthest - 3 }
    mutating func didCapture(angle: Double) { lastCapture = angle * direction }
}
