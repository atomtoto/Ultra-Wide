import CoreGraphics
import XCTest
@testable import UltraWide

final class SweepCoverageAnalysisTests: XCTestCase {
    func testArrowTargetsTheMissingRightEdgeAndKeepsAStableTarget() throws {
        let coverage = VisualSweepCoverage(polygons: [rect(-0.1, -0.1, 0.9, 1.2), rect(0, 0, 0.7, 1)])
        let analysis = SweepCoverageAnalysis(coverage: coverage)
        let center = CGPoint(x: 0.55, y: 0.5)
        let first = try XCTUnwrap(analysis.target(from: center))
        XCTAssertGreaterThan(first.x, 0.8)
        XCTAssertEqual(analysis.target(from: CGPoint(x: 0.56, y: 0.5), retaining: first), first)
        XCTAssertNil(analysis.capturedField, "A large missing edge cannot be presented as a slight crop.")
    }

    func testSmallEdgeGapOffersAFullyCoveredCropWithTheOriginalAspect() throws {
        let coverage = VisualSweepCoverage(polygons: [rect(-0.1, -0.1, 1.06, 1.2), rect(0, 0, 0.8, 1)])
        let crop = try XCTUnwrap(SweepCoverageAnalysis(coverage: coverage).capturedField)
        XCTAssertGreaterThan(crop.rect.width, 0.8)
        XCTAssertEqual(crop.rect.width, crop.rect.height, accuracy: 1e-10)
        XCTAssertLessThan(crop.rect.maxX, 0.96)
        XCTAssertTrue(coverage.contains(crop.rect.insetBy(dx: -crop.rect.width * 0.025, dy: -crop.rect.height * 0.025)))
        XCTAssertFalse(coverage.isComplete)
    }

    func testThinInteriorHoleIsGuidedAndCannotBeExportedAsACleanCrop() {
        let coverage = VisualSweepCoverage(polygons: [
            rect(-0.025, -0.025, 0.515, 1.05), rect(0.4901, -0.025, 0.5349, 1.05)
        ])
        let analysis = SweepCoverageAnalysis(coverage: coverage)
        XCTAssertFalse(coverage.isComplete)
        XCTAssertFalse(analysis.missingPoints.isEmpty, "The hole lies between every grid sample.")
        XCTAssertTrue(analysis.missingPoints.contains { $0.x > 0.49 && $0.x < 0.4901 })
        XCTAssertNil(analysis.capturedField)
        XCTAssertNil(CapturedFieldCrop(rect: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9), coverage: coverage))
    }

    func testCropRebasesTheCachedAlignmentAndPreservesItsSourceAndExposure() throws {
        let original = Homography3x3([1.06, 0, -0.1, 0, 1.2, -0.1, 0, 0, 1])
        let footprint = try XCTUnwrap(VisualSweepCoverage.footprint(original))
        let coverage = VisualSweepCoverage(polygons: [footprint, footprint])
        let crop = try XCTUnwrap(SweepCoverageAnalysis(coverage: coverage).capturedField)
        let alignment = StitchAlignment(normalizedHomography: original.elements,
            sourcePixelWidth: 960, sourcePixelHeight: 1280, luminanceGain: 1.25)
        let inputs = try crop.inputs(from: [StitchInput(url: URL(fileURLWithPath: "/a.jpg"), alignment: alignment),
                                           StitchInput(url: URL(fileURLWithPath: "/b.jpg"), alignment: alignment)])
        let rebased = try XCTUnwrap(inputs.first?.alignment)
        XCTAssertEqual(rebased.sourcePixelWidth, 960)
        XCTAssertEqual(rebased.sourcePixelHeight, 1280)
        XCTAssertEqual(rebased.luminanceGain, 1.25)
        let point = CGPoint(x: 0.3, y: 0.6)
        let old = try XCTUnwrap(original.transform(point))
        let new = try XCTUnwrap(Homography3x3(rebased.normalizedHomography).transform(point))
        XCTAssertEqual(new.x, (old.x - crop.rect.minX) / crop.rect.width, accuracy: 1e-9)
        XCTAssertEqual(new.y, (old.y - crop.rect.minY) / crop.rect.height, accuracy: 1e-9)
        let rebasedCoverage = VisualSweepCoverage(polygons: inputs.compactMap {
            $0.alignment.flatMap { VisualSweepCoverage.footprint(Homography3x3($0.normalizedHomography)) }
        })
        XCTAssertTrue(rebasedCoverage.isComplete)
        // Normalized focal length increases by the inverse crop scale: no
        // camera estimation or registration is restarted for a smaller field.
        XCTAssertGreaterThan(1 / crop.rect.height, 1)
    }

    func testCropRefusesUnpreparedInputsAndChangedIncompleteCoverage() throws {
        let coverage = VisualSweepCoverage(polygons: [rect(-0.1, -0.1, 1.06, 1.2), rect(0, 0, 0.8, 1)])
        let crop = try XCTUnwrap(SweepCoverageAnalysis(coverage: coverage).capturedField)
        XCTAssertThrowsError(try crop.inputs(from: [StitchInput(url: URL(fileURLWithPath: "/a.jpg"))]))
        let small = StitchAlignment(normalizedHomography: [0.4, 0, 0.2, 0, 0.4, 0.2, 0, 0, 1],
                                   sourcePixelWidth: 960, sourcePixelHeight: 1280)
        XCTAssertThrowsError(try crop.inputs(from: [StitchInput(url: URL(fileURLWithPath: "/a.jpg"), alignment: small),
                                                   StitchInput(url: URL(fileURLWithPath: "/b.jpg"), alignment: small)]))
    }

    func testCompleteOrEmptyCoverageOffersNeitherGuidanceNorSmallerField() {
        let full = VisualSweepCoverage(polygons: [rect(-0.1, -0.1, 1.2, 1.2), rect(0, 0, 1, 1)])
        for coverage in [full, VisualSweepCoverage(polygons: [])] {
            let analysis = SweepCoverageAnalysis(coverage: coverage)
            XCTAssertNil(analysis.target(from: CGPoint(x: 0.5, y: 0.5)))
            XCTAssertNil(analysis.capturedField)
        }
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [CGPoint] {
        [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)]
    }
}
