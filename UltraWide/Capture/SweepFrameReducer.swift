import Foundation

/// Dense sampling makes the gauge responsive. Retire redundant interior
/// views so that this responsiveness does not consume the capture budget or
/// multiply the work of the assembler. The center and connected coverage stay.
enum SweepFrameReducer {
    static let preferredFrameCount = 24

    static func reduced(_ frames: [CapturedFrame], plan: CapturePlan) -> [CapturedFrame] {
        guard frames.count > preferredFrameCount,
              let center = frames.min(by: {
                  hypot($0.yawDegrees, $0.pitchDegrees) < hypot($1.yawDegrees, $1.pitchDegrees)
              })?.id else { return frames }
        var kept = frames
        while kept.count > preferredFrameCount {
            let before = CoverageTracker(plan: plan, frames: kept).fraction
            let candidates = kept.indices.filter {
                kept[$0].id != center && kept[$0].id != frames.last?.id
            }.sorted {
                let first = kept[$0], second = kept[$1]
                let firstRank = first.quality == .good ? 1 : 0
                let secondRank = second.quality == .good ? 1 : 0
                return firstRank == secondRank ? $0 < $1 : firstRank < secondRank
            }
            var retired = false
            for index in candidates {
                let remaining = kept.enumerated().filter { $0.offset != index }.map(\.element)
                let tracker = CoverageTracker(plan: plan, frames: remaining)
                guard tracker.fraction + 1e-10 >= before, connected(tracker.imageRects) else { continue }
                kept = remaining
                retired = true
                break
            }
            if !retired { break }
        }
        return kept
    }

    private static func connected(_ rects: [CGRect]) -> Bool {
        guard !rects.isEmpty else { return true }
        var visited: Set<Int> = [0]
        var frontier = [0]
        while let index = frontier.popLast() {
            for other in rects.indices where !visited.contains(other) {
                let intersection = rects[index].intersection(rects[other])
                guard !intersection.isNull else { continue }
                let smaller = min(rects[index].width * rects[index].height,
                                  rects[other].width * rects[other].height)
                guard smaller > 0, intersection.width * intersection.height / smaller >= 0.30 else { continue }
                visited.insert(other)
                frontier.append(other)
            }
        }
        return visited.count == rects.count
    }
}
