import CoreGraphics
import Foundation

/// Small, immutable guidance map built by the registration worker, never by
/// the motion callback. Cropping uses whole covered cells, not point samples.
struct SweepCoverageAnalysis: Sendable {
    static let dimension = 48
    let missingPoints: [CGPoint]
    let capturedField: CapturedFieldCrop?

    init(coverage: VisualSweepCoverage) {
        guard !coverage.isComplete, !coverage.polygons.isEmpty else {
            missingPoints = []
            capturedField = nil
            return
        }
        let n = Self.dimension
        let step = 1.0 / Double(n)
        var missing: [CGPoint] = []
        var previousRow = [Int](repeating: 0, count: n + 1)
        var best = CGRect.zero
        for y in 0..<n {
            var row = [Int](repeating: 0, count: n + 1)
            for x in 0..<n {
                let center = CGPoint(x: (Double(x) + 0.5) * step, y: (Double(y) + 0.5) * step)
                if !coverage.polygons.contains(where: { Self.contains(center, in: $0) }) {
                    missing.append(center)
                }
                let corners = [CGPoint(x: Double(x) * step, y: Double(y) * step),
                    CGPoint(x: Double(x + 1) * step, y: Double(y) * step),
                    CGPoint(x: Double(x + 1) * step, y: Double(y + 1) * step),
                    CGPoint(x: Double(x) * step, y: Double(y + 1) * step)]
                // A convex polygon containing all four corners covers the
                // entire cell. A thin internal gap can never pass this test.
                guard coverage.polygons.contains(where: { polygon in
                    corners.allSatisfy { Self.contains($0, in: polygon) }
                }) else { continue }
                row[x + 1] = 1 + min(row[x], previousRow[x], previousRow[x + 1])
                let side = Double(row[x + 1]) * step
                let rect = CGRect(x: Double(x + 1) * step - side,
                                  y: Double(y + 1) * step - side, width: side, height: side)
                if side > best.width || (side == best.width && Self.distanceToCenter(rect) < Self.distanceToCenter(best)) {
                    best = rect
                }
            }
            previousRow = row
        }
        missingPoints = missing.isEmpty ? coverage.uncoveredPoints() : missing
        // Keep the same 2.5% overscan as a full-field export. A square in
        // normalized coordinates preserves the original portrait/landscape ratio.
        let safeSide = best.width / (1 + 2 * VisualSweepCoverage.overscan)
        let safe = CGRect(x: best.midX - safeSide / 2, y: best.midY - safeSide / 2,
                          width: safeSide, height: safeSide)
        capturedField = coverage.fraction >= 0.85 ? CapturedFieldCrop(rect: safe, coverage: coverage) : nil
    }

    func target(from center: CGPoint, retaining previous: CGPoint? = nil) -> CGPoint? {
        func distance(_ point: CGPoint) -> Double { hypot(point.x - center.x, point.y - center.y) }
        guard let nearest = missingPoints.min(by: { distance($0) < distance($1) }) else { return nil }
        // Hysteresis keeps the arrow from switching between equally near edges.
        if let previous, missingPoints.contains(previous), distance(previous) <= distance(nearest) * 1.3 + 0.02 {
            return previous
        }
        return nearest
    }

    private static func distanceToCenter(_ rect: CGRect) -> Double { hypot(rect.midX - 0.5, rect.midY - 0.5) }

    private static func contains(_ point: CGPoint, in polygon: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if abs(cross) < 1e-12 { continue }
            if sign == 0 { sign = cross }
            else if cross * sign < 0 { return false }
        }
        return true
    }
}

struct CapturedFieldCrop: Sendable, Equatable {
    let rect: CGRect

    init?(rect: CGRect, coverage: VisualSweepCoverage) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1, rect.maxY <= 1,
              rect.width >= 0.75, rect.width < 0.995, abs(rect.width - rect.height) < 1e-8,
              coverage.polygons.count >= 2,
              coverage.contains(rect.insetBy(dx: -rect.width * VisualSweepCoverage.overscan,
                                            dy: -rect.height * VisualSweepCoverage.overscan)) else { return nil }
        self.rect = rect
    }

    /// Rebase the cached matrices into the smaller field. The native renderer
    /// still validates its entire requested canvas and keeps its hole checks.
    func inputs(from originals: [StitchInput]) throws -> [StitchInput] {
        let crop = Homography3x3([1 / rect.width, 0, -rect.minX / rect.width,
                                 0, 1 / rect.height, -rect.minY / rect.height, 0, 0, 1])
        let inputs = try originals.map { input -> StitchInput in
            guard let alignment = input.alignment, alignment.normalizedHomography.count == 9 else {
                throw StitchingFailure.invalidGeometry
            }
            let matrix = Homography3x3(alignment.normalizedHomography).concatenating(crop)
            guard matrix.inverted() != nil, VisualSweepCoverage.footprint(matrix) != nil else {
                throw StitchingFailure.invalidGeometry
            }
            return StitchInput(url: input.url, yawRadians: input.yawRadians,
                pitchRadians: input.pitchRadians, rollRadians: input.rollRadians,
                alignment: StitchAlignment(normalizedHomography: matrix.elements,
                    sourcePixelWidth: alignment.sourcePixelWidth, sourcePixelHeight: alignment.sourcePixelHeight,
                    luminanceGain: alignment.luminanceGain))
        }
        let footprints = inputs.compactMap { input in
            input.alignment.flatMap { VisualSweepCoverage.footprint(Homography3x3($0.normalizedHomography)) }
        }
        guard VisualSweepCoverage(polygons: footprints).isComplete else {
            throw StitchingFailure.incompleteCoverage(rejectedIndices: [])
        }
        return inputs
    }
}
