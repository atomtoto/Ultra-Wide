import CoreGraphics
import Foundation

/// Conservative angular coverage of the requested output. It tracks image
/// footprints rather than a list of prescribed camera positions.
struct CoverageTracker {
    private let plan: CapturePlan
    private let overscan = 0.025
    private(set) var imageRects: [CGRect] = []
    private var cachedFraction: Double = 0

    init(plan: CapturePlan, frames: [CapturedFrame] = []) {
        self.plan = plan
        imageRects = frames.map { footprint(yaw: $0.yawDegrees, pitch: $0.pitchDegrees) }
        cachedFraction = fraction(adding: nil)
    }

    func footprint(yaw: Double, pitch: Double) -> CGRect {
        // Rectilinear projection gives a better edge estimate than assigning
        // each degree the same number of pixels at wide fields of view.
        let targetX = tan(plan.targetHorizontalFOV * .pi / 360)
        let targetY = tan(plan.targetVerticalFOV * .pi / 360)
        let halfH = plan.sourceHorizontalFOV / 2
        let halfV = plan.sourceVerticalFOV / 2
        let boundedYaw = min(max(yaw, -86 + halfH), 86 - halfH)
        let boundedPitch = min(max(pitch, -86 + halfV), 86 - halfV)
        let left = (tan((boundedYaw - halfH) * .pi / 180) / targetX + 1) / 2
        let right = (tan((boundedYaw + halfH) * .pi / 180) / targetX + 1) / 2
        let top = (1 - tan((boundedPitch + halfV) * .pi / 180) / targetY) / 2
        let bottom = (1 - tan((boundedPitch - halfV) * .pi / 180) / targetY) / 2
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// A 7% inset on each side accounts for distortion, slight roll, motion
    /// timestamp mismatch and the seam/crop lost in the stitcher.
    private func reliablePart(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)
    }

    func coverage(viewYaw: Double, viewPitch: Double) -> CaptureCoverage {
        CaptureCoverage(
            viewRect: footprint(yaw: viewYaw, pitch: viewPitch),
            coveredRects: imageRects.map(reliablePart),
            fraction: fraction
        )
    }

    var fraction: Double { cachedFraction }

    private func fraction(adding candidate: CGRect?) -> Double {
        let target = CGRect(x: -overscan, y: -overscan,
                            width: 1 + 2 * overscan, height: 1 + 2 * overscan)
        let rects = (imageRects + [candidate].compactMap { $0 })
            .map(reliablePart)
            .map { $0.intersection(target) }
            .filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !rects.isEmpty else { return 0 }
        // Rectangles change the union only at a horizontal edge. Computing
        // the union of x-intervals in each such band avoids treating a thin
        // uncovered seam as complete just because grid samples miss it.
        let edges = Array(Set([target.minY, target.maxY] +
                              rects.flatMap { [$0.minY, $0.maxY] })).sorted()
        var area: CGFloat = 0
        for index in 0..<(edges.count - 1) {
            let lower = edges[index], upper = edges[index + 1]
            guard upper > lower else { continue }
            let mid = (lower + upper) / 2
            let intervals = rects.filter { $0.minY <= mid && $0.maxY >= mid }
                .map { ($0.minX, $0.maxX) }
                .sorted { $0.0 < $1.0 }
            var span: (left: CGFloat, right: CGFloat)?
            var coveredWidth: CGFloat = 0
            for (start, end) in intervals {
                if let current = span, start > current.right {
                    coveredWidth += current.right - current.left
                    span = (start, end)
                } else if let current = span {
                    span = (current.left, max(current.right, end))
                } else {
                    span = (start, end)
                }
            }
            if let span { coveredWidth += span.right - span.left }
            area += coveredWidth * (upper - lower)
        }
        return Double(min(1, max(0, area / target.width / target.height)))
    }

    var isComplete: Bool { imageRects.count >= 2 && fraction >= 0.999999 }

    func shouldKeep(yaw: Double, pitch: Double, repairMode: Bool = false) -> Bool {
        guard abs(yaw) + plan.sourceHorizontalFOV / 2 < 86,
              abs(pitch) + plan.sourceVerticalFOV / 2 < 86 else { return false }
        let candidate = footprint(yaw: yaw, pitch: pitch)
        guard candidate.width.isFinite, candidate.height.isFinite,
              candidate.width > 0, candidate.height > 0 else { return false }
        if imageRects.isEmpty { return abs(yaw) < 5 && abs(pitch) < 5 }

        // The accepted-frame graph must stay connected for feature matching.
        let overlap = imageRects.map { previous -> Double in
            let intersection = candidate.intersection(previous)
            guard !intersection.isNull else { return 0 }
            let overlapArea = intersection.width * intersection.height
            let smallerArea = min(candidate.width * candidate.height,
                                  previous.width * previous.height)
            return smallerArea > 0 ? overlapArea / smallerArea : 0
        }.max() ?? 0
        guard overlap >= 0.30 else { return false }

        let filled = fraction
        let distinct = imageRects.allSatisfy { previous in
            let dx = abs(candidate.midX - previous.midX) / max(candidate.width, previous.width)
            let dy = abs(candidate.midY - previous.midY) / max(candidate.height, previous.height)
            return hypot(dx, dy) >= (repairMode ? 0.11 : filled > 0.90 ? 0.12 : 0.33)
        }
        guard distinct else { return false }
        if repairMode { return true }
        return fraction(adding: candidate) - filled >= (filled > 0.90 ? 0.0001 : 0.012)
    }

    mutating func include(yaw: Double, pitch: Double) {
        imageRects.append(footprint(yaw: yaw, pitch: pitch))
        cachedFraction = fraction(adding: nil)
    }
}
