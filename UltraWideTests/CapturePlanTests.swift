import XCTest
@testable import UltraWide

final class CapturePlanTests: XCTestCase {
    func testMainLensCoversHalfFieldWithCenterFirst() throws {
        let plan = try XCTUnwrap(CapturePlan.make(
            lens: .wide,
            target: .half,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 75
        ))

        XCTAssertLessThanOrEqual(plan.expectedFrameCount, 30)
        XCTAssertGreaterThan(plan.expectedFrameCount, 1)
        XCTAssertGreaterThan(plan.targetHorizontalFOV, plan.sourceHorizontalFOV)
        XCTAssertGreaterThan(plan.targetVerticalFOV, plan.sourceVerticalFOV)
        XCTAssertEqual(plan.makeSlots().first?.id, "r\(plan.rows / 2)c\(plan.columns / 2)")
    }

    func testTelephotoRejectsImpracticalHalfFieldButOffersDetailField() {
        let impossible = CapturePlan.make(
            lens: .tele,
            target: .half,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 16
        )
        let detail = CapturePlan.make(
            lens: .tele,
            target: .two,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 16
        )

        XCTAssertNil(impossible)
        XCTAssertNotNil(detail)
        XCTAssertLessThanOrEqual(detail?.expectedFrameCount ?? .max, 30)
    }

    func testPortraitAndLandscapeKeepTheSameAngularCoverage() throws {
        let portrait = try XCTUnwrap(CapturePlan.make(
            lens: .wide,
            target: .half,
            orientation: .portrait,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 75
        ))
        let landscape = try XCTUnwrap(CapturePlan.make(
            lens: .wide,
            target: .half,
            orientation: .landscapeLeft,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 75
        ))

        XCTAssertEqual(portrait.targetHorizontalFOV, landscape.targetVerticalFOV, accuracy: 0.001)
        XCTAssertEqual(portrait.targetVerticalFOV, landscape.targetHorizontalFOV, accuracy: 0.001)
        XCTAssertEqual(portrait.expectedFrameCount, landscape.expectedFrameCount)
    }
}
