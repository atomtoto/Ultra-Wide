import CoreGraphics
import Foundation

/// The union of visually registered image footprints in the requested field.
/// Motion alone can never create one of these footprints.
struct VisualSweepCoverage: Sendable, Equatable {
    let polygons: [[CGPoint]]
    let fraction: Double
    let isComplete: Bool
    static let overscan = 0.025

    init(polygons: [[CGPoint]]) {
        self.polygons = polygons.filter { Self.valid($0) }
        let target = CGRect(x: -Self.overscan, y: -Self.overscan,
                            width: 1 + 2 * Self.overscan, height: 1 + 2 * Self.overscan)
        let clipped = self.polygons.map { Self.clip($0, to: target) }.filter { $0.count >= 3 }
        fraction = min(1, max(0, Self.unionArea(clipped) / Double(target.width * target.height)))
        // Exact polygon union includes roll and perspective. A tiny numerical
        // tolerance avoids floating point noise without accepting missing edges.
        isComplete = self.polygons.count >= 2 && fraction >= CaptureCoverage.completionThreshold
    }

    static func footprint(_ homography: Homography3x3) -> [CGPoint]? {
        // Leave a small image border for registration uncertainty and seams.
        let inset = 0.015
        let corners = [CGPoint(x: inset, y: inset), CGPoint(x: 1 - inset, y: inset),
                       CGPoint(x: 1 - inset, y: 1 - inset), CGPoint(x: inset, y: 1 - inset)]
        let h = homography.elements
        let denominators = corners.map { h[6] * $0.x + h[7] * $0.y + h[8] }
        guard denominators.allSatisfy({ $0 > 1e-8 }) || denominators.allSatisfy({ $0 < -1e-8 }) else { return nil }
        let projected = corners.compactMap { homography.transform($0) }
        return projected.count == 4 && valid(projected) ? projected : nil
    }

    func contains(_ rect: CGRect) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let clipped = polygons.map { Self.clip($0, to: rect) }.filter { $0.count >= 3 }
        return Self.unionArea(clipped) / Double(rect.width * rect.height) >= CaptureCoverage.completionThreshold
    }

    /// Exact fallback for small holes or missing overscan that fall between
    /// guidance grid samples. Each subtraction leaves convex uncovered pieces.
    func uncoveredPoints() -> [CGPoint] {
        let o = Self.overscan
        var remaining = [[CGPoint(x: -o, y: -o), CGPoint(x: 1 + o, y: -o),
                          CGPoint(x: 1 + o, y: 1 + o), CGPoint(x: -o, y: 1 + o)]]
        for polygon in polygons {
            let signedArea = polygon.indices.reduce(CGFloat.zero) { sum, index in
                let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                return sum + a.x * b.y - b.x * a.y
            }
            let direction: CGFloat = signedArea >= 0 ? 1 : -1
            var next: [[CGPoint]] = []
            for region in remaining {
                if Self.overlap(region, polygon) < 1e-12 { next.append(region); continue }
                var inside = region
                for index in polygon.indices {
                    let a = polygon[index], b = polygon[(index + 1) % polygon.count]
                    func distance(_ p: CGPoint) -> CGFloat {
                        direction * ((b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x))
                    }
                    let outside = Self.clip(inside) { -distance($0) }
                    if Self.area(outside) > 1e-11 { next.append(outside) }
                    inside = Self.clip(inside, distance: distance)
                    if inside.isEmpty { break }
                }
            }
            remaining = next
        }
        return remaining.map { polygon in
            CGPoint(x: polygon.reduce(0) { $0 + $1.x } / CGFloat(polygon.count),
                    y: polygon.reduce(0) { $0 + $1.y } / CGFloat(polygon.count))
        }
    }

    static func valid(_ polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 16 && abs($0.y) < 16 }),
              area(polygon) > 1e-8 else { return false }
        var sign: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let c = polygon[(index + 2) % polygon.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) <= 1e-10 { continue }
            if sign == 0 { sign = cross }
            else if cross * sign < 0 { return false }
        }
        return sign != 0
    }

    static func area(_ points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        let sum = points.indices.reduce(0.0) { value, index in
            let a = points[index], b = points[(index + 1) % points.count]
            return value + Double(a.x * b.y - b.x * a.y)
        }
        return abs(sum) / 2
    }

    static func overlap(_ first: [CGPoint], _ second: [CGPoint]) -> Double {
        let smaller = min(area(first), area(second))
        guard smaller > 0, second.count >= 3 else { return 0 }
        let signedArea = second.indices.reduce(CGFloat.zero) { value, index in
            let a = second[index], b = second[(index + 1) % second.count]
            return value + a.x * b.y - b.x * a.y
        }
        let direction: CGFloat = signedArea >= 0 ? 1 : -1
        var output = first
        for index in second.indices {
            let a = second[index], b = second[(index + 1) % second.count]
            output = clip(output) { point in
                direction * ((b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x))
            }
        }
        return min(1, area(output) / smaller)
    }

    private static func clip(_ points: [CGPoint], to rect: CGRect) -> [CGPoint] {
        var output = clip(points) { $0.x - rect.minX }
        output = clip(output) { rect.maxX - $0.x }
        output = clip(output) { $0.y - rect.minY }
        return clip(output) { rect.maxY - $0.y }
    }

    private static func clip(_ points: [CGPoint], distance: (CGPoint) -> CGFloat) -> [CGPoint] {
        guard let last = points.last else { return [] }
        var output: [CGPoint] = []
        var previous = last
        var previousDistance = distance(previous)
        for current in points {
            let currentDistance = distance(current)
            if (currentDistance >= 0) != (previousDistance >= 0) {
                let weight = previousDistance / (previousDistance - currentDistance)
                output.append(CGPoint(x: previous.x + (current.x - previous.x) * weight,
                                      y: previous.y + (current.y - previous.y) * weight))
            }
            if currentDistance >= 0 { output.append(current) }
            previous = current
            previousDistance = currentDistance
        }
        return output
    }

    /// Horizontal intervals change order only at vertices or intersecting
    /// polygon edges. Their union is linear in each resulting band, so its
    /// midpoint integrates the exact area, including narrow uncovered seams.
    private static func unionArea(_ polygons: [[CGPoint]]) -> Double {
        let edges = polygons.flatMap { polygon in
            polygon.indices.map { (polygon[$0], polygon[($0 + 1) % polygon.count]) }
        }
        var levels = polygons.flatMap { $0.map(\.y) }
        for i in edges.indices {
            let (a, b) = edges[i]
            let dx = b.x - a.x, dy = b.y - a.y
            for j in edges.indices where j > i {
                let (c, d) = edges[j]
                let ex = d.x - c.x, ey = d.y - c.y
                let determinant = dx * ey - dy * ex
                guard abs(determinant) > 1e-12 else { continue }
                let t = ((c.x - a.x) * ey - (c.y - a.y) * ex) / determinant
                let u = ((c.x - a.x) * dy - (c.y - a.y) * dx) / determinant
                if t > 0 && t < 1 && u > 0 && u < 1 { levels.append(a.y + t * dy) }
            }
        }
        levels = Array(Set(levels)).sorted()
        guard levels.count >= 2 else { return 0 }
        var result = 0.0
        for index in 0..<(levels.count - 1) {
            let lower = levels[index], upper = levels[index + 1]
            guard upper - lower > 1e-12 else { continue }
            let mid = (lower + upper) / 2
            let intervals: [(CGFloat, CGFloat)] = polygons.compactMap { polygon in
                var xs: [CGFloat] = []
                for edge in polygon.indices {
                    let a = polygon[edge], b = polygon[(edge + 1) % polygon.count]
                    if min(a.y, b.y) <= mid && max(a.y, b.y) > mid {
                        xs.append(a.x + (b.x - a.x) * (mid - a.y) / (b.y - a.y))
                    }
                }
                guard let start = xs.min(), let end = xs.max() else { return nil }
                return (start, end)
            }.sorted { $0.0 < $1.0 }
            var left: CGFloat?, right: CGFloat = 0, width: CGFloat = 0
            for (start, end) in intervals {
                if let previous = left, start > right {
                    width += right - previous
                    left = start; right = end
                } else if left != nil { right = max(right, end) }
                else { left = start; right = end }
            }
            if let left { width += right - left }
            result += Double(width * (upper - lower))
        }
        return result
    }
}
