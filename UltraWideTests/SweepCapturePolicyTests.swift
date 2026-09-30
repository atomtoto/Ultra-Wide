import XCTest
@testable import UltraWide

final class SweepCapturePolicyTests: XCTestCase {
    private let soft = PhotoQualityResult(sharpness: 20, brightness: 0.4, quality: .soft)

    func testSoftSceneIsAcceptedOnFirstUsefulExposure() {
        XCTAssertTrue(SweepCapturePolicy.shouldEncode(soft))
    }

    func testNaturalTiltAndBriskSweepAreAllowedButOrientationChangeIsNot() {
        func pose(speed: Double, roll: Double, valid: Bool = true) -> MotionReading {
            MotionReading(yawDegrees: 0, pitchDegrees: 0, rollDegrees: roll, angularSpeed: speed,
                          orientationMatchesConfiguration: valid, sampleTimestamp: 0)
        }
        XCTAssertTrue(SweepCapturePolicy.allows(pose(speed: 1.8, roll: 15)))
        XCTAssertFalse(SweepCapturePolicy.allows(pose(speed: 3, roll: 0)))
        XCTAssertFalse(SweepCapturePolicy.allows(pose(speed: 0.5, roll: 35)))
        XCTAssertFalse(SweepCapturePolicy.allows(pose(speed: 0.5, roll: 0, valid: false)))
    }

    func testDarkSceneCanBeCapturedButBlackFrameIsRejected() {
        let darkScene = PhotoQualityResult(sharpness: 60, brightness: 0.07, quality: .dark)
        let blackFrame = PhotoQualityResult(sharpness: 0, brightness: 0.005, quality: .dark)
        XCTAssertTrue(SweepCapturePolicy.shouldEncode(darkScene))
        XCTAssertFalse(SweepCapturePolicy.shouldEncode(blackFrame))
    }
}
