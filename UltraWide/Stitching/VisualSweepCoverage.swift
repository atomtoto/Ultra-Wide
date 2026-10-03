import CoreGraphics
import Foundation

/// The union of visually registered image footprints in the requested field.
/// Motion alone can never create one of these footprints.
struct VisualSweepCoverage: Sendable, Equatable {
    let polygons: [[CGPoint]]
    let fraction: Double
    let isComplete: Bool
    /// Coverage lost by removing each polygon, computed together with the
    /// union instead of rebuilding it once for every retirement candidate.
    let exclusiveFractions: [Double]
    static let overscan = 0.025

    init(polygons: [[CGPoint]]) {
        self.polygons = polygons.filter { Self.valid($0) }
        let target = CGRect(x: -Self.overscan, y: -Self.overscan,
                            width: 1 + 2 * Self.overscan, height: 1 + 2 * Self.overscan)
        let areas = Self.unionAreas(self.polygons.map { Self.clip($0, to: target) })
        let targetArea = Double(target.width * target.height)
        fraction = min(1, max(0, areas.total / targetArea))
        exclusiveFractions = areas.exclusive.map { max(0, $0 / targetArea) }
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
        return Self.unionAreas(clipped).total / Double(rect.width * rect.height) >= CaptureCoverage.completionThreshold
    }

    /// Check a candidate against only the part of its footprint not already
    /// covered. The motion callback must not rebuild a dense sweep's union.
    func additionalFraction(from polygon: [CGPoint]) -> Double {
        guard Self.valid(polygon) else { return 0 }
        let o = Self.overscan
        let target = CGRect(x: -o, y: -o, width: 1 + 2 * o, height: 1 + 2 * o)
        let clipped = Self.clip(polygon, to: target)
        guard Self.area(clipped) > 0 else { return 0 }
        let remaining = Self.uncoveredRegions(in: clipped, coveredBy: polygons)
        return remaining.reduce(0) { $0 + Self.area($1) } / Double(target.width * target.height)
    }

    /// Exact fallback for small holes or missing overscan that fall between
    /// guidance grid samples. Each subtraction leaves convex uncovered pieces.
    func uncoveredPoints() -> [CGPoint] {
        let o = Self.overscan
        let target = [CGPoint(x: -o, y: -o), CGPoint(x: 1 + o, y: -o),
                      CGPoint(x: 1 + o, y: 1 + o), CGPoint(x: -o, y: 1 + o)]
        return Self.uncoveredRegions(in: target, coveredBy: polygons).map { polygon in
            CGPoint(x: polygon.reduce(0) { $0 + $1.x } / CGFloat(polygon.count),
                    y: polygon.reduce(0) { $0 + $1.y } / CGFloat(polygon.count))
        }
    }

    private static func uncoveredRegions(in target: [CGPoint], coveredBy polygons: [[CGPoint]]) -> [[CGPoint]] {
        var remaining = [target]
        for polygon in polygons {
            if remaining.isEmpty { break }
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
        return remaining
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
    private static func unionAreas(_ polygons: [[CGPoint]]) -> (total: Double, exclusive: [Double]) {
        let edges = polygons.enumerated().flatMap { owner, polygon in
            polygon.indices.map { (a: polygon[$0], b: polygon[($0 + 1) % polygon.count], owner: owner) }
        }
        var levels = polygons.flatMap { $0.map(\.y) }
        for i in edges.indices {
            let (a, b, owner) = edges[i]
            let dx = b.x - a.x, dy = b.y - a.y
            for j in (i + 1)..<edges.count {
                let (c, d, otherOwner) = edges[j]
                guard owner != otherOwner,
                      max(min(a.y, b.y), min(c.y, d.y)) < min(max(a.y, b.y), max(c.y, d.y)),
                      max(min(a.x, b.x), min(c.x, d.x)) <= min(max(a.x, b.x), max(c.x, d.x)) else { continue }
                let ex = d.x - c.x, ey = d.y - c.y
                let determinant = dx * ey - dy * ex
                guard abs(determinant) > 1e-12 else { continue }
                let t = ((c.x - a.x) * ey - (c.y - a.y) * ex) / determinant
                let u = ((c.x - a.x) * dy - (c.y - a.y) * dx) / determinant
                if t > 0 && t < 1 && u > 0 && u < 1 { levels.append(a.y + t * dy) }
            }
        }
        levels = Array(Set(levels)).sorted()
        var exclusive = [Double](repeating: 0, count: polygons.count)
        guard levels.count >= 2 else { return (0, exclusive) }
        var result = 0.0
        var endpoints: [(x: CGFloat, owner: Int, delta: Int)] = []
        endpoints.reserveCapacity(polygons.count * 2)
        for index in 0..<(levels.count - 1) {
            let lower = levels[index], upper = levels[index + 1]
            guard upper - lower > 1e-12 else { continue }
            let mid = (lower + upper) / 2
            endpoints.removeAll(keepingCapacity: true)
            for (owner, polygon) in polygons.enumerated() {
                var start = CGFloat.infinity, end = -CGFloat.infinity
                for edge in polygon.indices {
                    let a = polygon[edge], b = polygon[(edge + 1) % polygon.count]
                    if min(a.y, b.y) <= mid && max(a.y, b.y) > mid {
                        let x = a.x + (b.x - a.x) * (mid - a.y) / (b.y - a.y)
                        start = min(start, x); end = max(end, x)
                    }
                }
                guard end > start else { continue }
                endpoints.append((start, owner, 1))
                endpoints.append((end, owner, -1))
            }
            endpoints.sort { $0.x < $1.x }
            var previousX = endpoints.first?.x ?? 0
            var activeCount = 0, activeOwner = 0
            for endpoint in endpoints {
                let area = Double((endpoint.x - previousX) * (upper - lower))
                if activeCount > 0 { result += area }
                if activeCount == 1 { exclusive[activeOwner] += area }
                // Each convex polygon contributes exactly one interval. XOR
                // identifies its owner when the active count returns to one.
                activeCount += endpoint.delta
                activeOwner ^= endpoint.owner
                previousX = endpoint.x
            }
        }
        return (result, exclusive)
    }
}
