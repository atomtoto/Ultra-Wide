import CoreGraphics
import XCTest
@testable import UltraWide

final class VisualSweepCoverageTests: XCTestCase {
    private let targetArea = 1.05 * 1.05

    func testOverlappingRectanglesCountSharedAreaOnlyOnce() {
        let coverage = VisualSweepCoverage(polygons: [
            rectangle(x: 0, y: 0, width: 0.6, height: 0.5),
            rectangle(x: 0.4, y: 0.2, width: 0.6, height: 0.5)
        ])

        // Two areas of 0.3 overlap in a 0.2-by-0.3 region.
        XCTAssertEqual(coverage.fraction, 0.54 / targetArea, accuracy: 1e-10)
        XCTAssertFalse(coverage.isComplete)
    }

    func testTriangleAndInclinedQuadrilateralUsePolygonArea() {
        let triangle = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.9, y: 0.1),
                        CGPoint(x: 0.1, y: 0.9)]
        let diamond = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5),
                       CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]

        XCTAssertEqual(VisualSweepCoverage(polygons: [triangle]).fraction,
                       0.32 / targetArea, accuracy: 1e-10)
        XCTAssertEqual(VisualSweepCoverage(polygons: [diamond]).fraction,
                       0.5 / targetArea, accuracy: 1e-10)
    }

    func testUnionIntegratesIntersectionsOfInclinedEdges() {
        let left = diamond(center: CGPoint(x: 0.4, y: 0.5), radius: 0.3)
        let right = diamond(center: CGPoint(x: 0.6, y: 0.5), radius: 0.3)
        let coverage = VisualSweepCoverage(polygons: [left, right])

        // Each diamond has area 0.18; their intersection has area 0.08.
        XCTAssertEqual(coverage.fraction, 0.28 / targetArea, accuracy: 1e-10)
    }

    func testNarrowUncoveredSeamDoesNotFinishCapture() {
        let seamWidth = 0.0001
        let coverage = VisualSweepCoverage(polygons: [
            rectangle(x: -0.025, y: -0.025, width: 0.525, height: 1.05),
            rectangle(x: 0.5 + seamWidth, y: -0.025,
                      width: 0.525 - seamWidth, height: 1.05)
        ])

        XCTAssertEqual(coverage.fraction, 1 - seamWidth / 1.05, accuracy: 1e-10)
        XCTAssertGreaterThan(coverage.fraction, 0.9998)
        XCTAssertFalse(coverage.isComplete)
    }

    func testNarrowInteriorHoleIsNotHiddenBySampling() {
        let holeWidth = 0.0001
        let coverage = VisualSweepCoverage(polygons: [
            rectangle(x: -0.025, y: -0.025, width: 1.05, height: 0.275),
            rectangle(x: -0.025, y: 0.75, width: 1.05, height: 0.275),
            rectangle(x: -0.025, y: 0.25, width: 0.515, height: 0.5),
            rectangle(x: 0.49 + holeWidth, y: 0.25,
                      width: 0.535 - holeWidth, height: 0.5)
        ])

        XCTAssertEqual(coverage.fraction, 1 - holeWidth * 0.5 / targetArea,
                       accuracy: 1e-10)
        XCTAssertFalse(coverage.isComplete)
    }

    func testNearlyFullAreaStillRejectsAMissingCorner() {
        let corner = 0.001
        let coverage = VisualSweepCoverage(polygons: [
            [CGPoint(x: -0.025 + corner, y: -0.025), CGPoint(x: 1.025, y: -0.025),
             CGPoint(x: 1.025, y: 1.025), CGPoint(x: -0.025, y: 1.025),
             CGPoint(x: -0.025, y: -0.025 + corner)],
            rectangle(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        ])

        XCTAssertGreaterThan(coverage.fraction, 0.999999,
            "The former area tolerance incorrectly marked this clipped corner as complete.")
        XCTAssertFalse(coverage.isComplete)
        let completed = VisualSweepCoverage(polygons: coverage.polygons + [
            rectangle(x: -0.03, y: -0.03, width: 0.01, height: 0.01)
        ])
        XCTAssertTrue(completed.isComplete)
    }

    func testCompleteCoverageRequiresOverscanAndAtLeastTwoViews() {
        let singleView = VisualSweepCoverage(polygons: [
            rectangle(x: -0.1, y: -0.1, width: 1.2, height: 1.2)
        ])
        XCTAssertEqual(singleView.fraction, 1, accuracy: 1e-10)
        XCTAssertFalse(singleView.isComplete)

        let noOverscan = VisualSweepCoverage(polygons: [
            rectangle(x: 0, y: 0, width: 0.55, height: 1),
            rectangle(x: 0.45, y: 0, width: 0.55, height: 1)
        ])
        XCTAssertEqual(noOverscan.fraction, 1 / targetArea, accuracy: 1e-10)
        XCTAssertFalse(noOverscan.isComplete)

        let complete = VisualSweepCoverage(polygons: [
            rectangle(x: -0.025, y: -0.025, width: 0.575, height: 1.05),
            rectangle(x: 0.45, y: -0.025, width: 0.575, height: 1.05)
        ])
        XCTAssertEqual(complete.fraction, 1, accuracy: 1e-10)
        XCTAssertTrue(complete.isComplete)
    }

    func testInvalidPolygonsCannotAddConfirmedCoverage() {
        let concave = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0, y: 1)]
        let bowTie = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
                      CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)]
        let degenerate = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5),
                          CGPoint(x: 1, y: 1)]
        let nonfinite = [CGPoint(x: 0, y: 0), CGPoint(x: CGFloat.nan, y: 0),
                         CGPoint(x: 0, y: 1)]
        let unbounded = rectangle(x: 0, y: 0, width: 17, height: 1)
        let coverage = VisualSweepCoverage(polygons: [concave, bowTie, degenerate,
                                                       nonfinite, unbounded])

        XCTAssertTrue(coverage.polygons.isEmpty)
        XCTAssertEqual(coverage.fraction, 0)
        XCTAssertFalse(coverage.isComplete)
    }

    func testProjectedFootprintIncludesSafetyBorderAndTransform() throws {
        let transform = Homography3x3([0.5, 0, 0.2, 0, 0.25, 0.3, 0, 0, 1])
        let footprint = try XCTUnwrap(VisualSweepCoverage.footprint(transform))

        XCTAssertEqual(footprint.count, 4)
        XCTAssertEqual(footprint[0].x, 0.2075, accuracy: 1e-10)
        XCTAssertEqual(footprint[0].y, 0.30375, accuracy: 1e-10)
        XCTAssertEqual(footprint[2].x, 0.6925, accuracy: 1e-10)
        XCTAssertEqual(footprint[2].y, 0.54625, accuracy: 1e-10)
        XCTAssertEqual(VisualSweepCoverage.area(footprint),
                       0.5 * 0.25 * 0.97 * 0.97, accuracy: 1e-10)
    }

    func testFootprintRejectsProjectiveHorizonAndNonfiniteTransform() {
        let throughCorner = Homography3x3([1, 0, 0, 0, 1, 0, 1, 0, -0.015])
        let throughImage = Homography3x3([1, 0, 0, 0, 1, 0, 1, 0, -0.5])
        let nonfinite = Homography3x3([Double.nan, 0, 0, 0, 1, 0, 0, 0, 1])

        XCTAssertNil(VisualSweepCoverage.footprint(throughCorner))
        XCTAssertNil(VisualSweepCoverage.footprint(throughImage))
        XCTAssertNil(VisualSweepCoverage.footprint(nonfinite))
    }

    func testConvexOverlapUsesSmallerFootprintAndEitherWinding() {
        let first = diamond(center: CGPoint(x: 0.4, y: 0.5), radius: 0.3)
        let second = diamond(center: CGPoint(x: 0.6, y: 0.5), radius: 0.3)

        XCTAssertEqual(VisualSweepCoverage.overlap(first, second),
                       0.08 / 0.18, accuracy: 1e-10)
        XCTAssertEqual(VisualSweepCoverage.overlap(first, Array(second.reversed())),
                       0.08 / 0.18, accuracy: 1e-10)
        let small = rectangle(x: 0.35, y: 0.45, width: 0.1, height: 0.1)
        XCTAssertEqual(VisualSweepCoverage.overlap(first, small), 1, accuracy: 1e-10)
        let disjoint = rectangle(x: 2, y: 2, width: 0.2, height: 0.2)
        XCTAssertEqual(VisualSweepCoverage.overlap(first, disjoint), 0)
    }

    private func rectangle(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
         CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
    }

    private func diamond(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        [CGPoint(x: center.x, y: center.y - radius),
         CGPoint(x: center.x + radius, y: center.y),
         CGPoint(x: center.x, y: center.y + radius),
         CGPoint(x: center.x - radius, y: center.y)]
    }
}
