import CoreGraphics
import simd

enum PanoramaGeometry {
    static func project(_ point: CGPoint, by matrix: simd_float3x3) throws -> CGPoint {
        let p = matrix * SIMD3<Float>(Float(point.x), Float(point.y), 1)
        guard p.z > 0.05, p.x.isFinite, p.y.isFinite, p.z.isFinite else { throw CaptureFailure.alignment }
        return CGPoint(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
    }

    static func corners(of rect: CGRect, by matrix: simd_float3x3) throws -> [CGPoint] {
        try [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            .map { try project($0, by: matrix) }
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    static func contains(_ p: CGPoint, polygon: [CGPoint]) -> Bool {
        var sign: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if abs(cross) < 0.0001 { continue }
            if sign == 0 { sign = cross }
            else if sign * cross < 0 { return false }
        }
        return true
    }

    /// Largest rectangle in a conservative coverage raster. Every cell must fit
    /// inside one convex photo footprint, so the crop never exposes empty corners.
    static func coveredCrop(polygons: [[CGPoint]], bounds: CGRect, columns: Int = 240) throws -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { throw CaptureFailure.alignment }
        let rows = max(16, min(240, Int(Double(columns) * bounds.height / bounds.width)))
        let dx = bounds.width / CGFloat(columns), dy = bounds.height / CGFloat(rows)
        var heights = [Int](repeating: 0, count: columns)
        var bestArea = 0
        var best = CGRect.zero
        for row in 0..<rows {
            for col in 0..<columns {
                let cell = CGRect(x: bounds.minX + CGFloat(col) * dx, y: bounds.minY + CGFloat(row) * dy, width: dx, height: dy)
                let corners = [CGPoint(x: cell.minX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.minY),
                               CGPoint(x: cell.maxX, y: cell.maxY), CGPoint(x: cell.minX, y: cell.maxY)]
                let covered = polygons.contains { poly in corners.allSatisfy { contains($0, polygon: poly) } }
                heights[col] = covered ? heights[col] + 1 : 0
            }
            var stack: [(start: Int, height: Int)] = []
            for col in 0...columns {
                let height = col == columns ? 0 : heights[col]
                var start = col
                while let last = stack.last, last.height > height {
                    stack.removeLast()
                    let area = last.height * (col - last.start)
                    if area > bestArea {
                        bestArea = area
                        best = CGRect(x: bounds.minX + CGFloat(last.start) * dx,
                                      y: bounds.minY + CGFloat(row + 1 - last.height) * dy,
                                      width: CGFloat(col - last.start) * dx, height: CGFloat(last.height) * dy)
                    }
                    start = last.start
                }
                if height > 0, stack.last?.height != height { stack.append((start, height)) }
            }
        }
        guard bestArea > 0 else { throw CaptureFailure.alignment }
        // Round inward, never expand into an uncovered pixel.
        return CGRect(x: ceil(best.minX) + 1, y: ceil(best.minY) + 1,
                      width: floor(best.maxX) - ceil(best.minX) - 2,
                      height: floor(best.maxY) - ceil(best.minY) - 2)
    }
}
