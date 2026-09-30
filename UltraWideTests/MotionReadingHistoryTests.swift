import XCTest
@testable import UltraWide

final class MotionReadingHistoryTests: XCTestCase {
    private func pose(_ yaw: Double, at time: Double, valid: Bool = true) -> MotionReading {
        MotionReading(yawDegrees: yaw, pitchDegrees: yaw / 2, rollDegrees: 0,
                      angularSpeed: 0.7, orientationMatchesConfiguration: valid,
                      sampleTimestamp: time)
    }

    func testExposureUsesInterpolatedPoseInsteadOfLaterCallbackPose() throws {
        var history = MotionReadingHistory()
        history.append(pose(0, at: 10))
        history.append(pose(3, at: 10.1))
        let actual = try XCTUnwrap(history.reading(near: 10.04))
        XCTAssertEqual(actual.yawDegrees, 1.2, accuracy: 0.0001)
        XCTAssertEqual(actual.pitchDegrees, 0.6, accuracy: 0.0001)
        XCTAssertEqual(actual.sampleTimestamp, 10.04)
    }

    func testStalePoseAndPreviousReferenceCannotBeUsed() {
        var history = MotionReadingHistory()
        history.append(pose(0, at: 10))
        XCTAssertNil(history.reading(near: 10.2))
        history.removeAll()
        history.append(pose(0, at: 11))
        XCTAssertNil(history.reading(near: 10))
        XCTAssertEqual(history.reading(near: 11)?.yawDegrees, 0)
    }

    func testOrientationChangeDoesNotGetInterpolatedIntoValidPose() {
        var history = MotionReadingHistory()
        history.append(pose(0, at: 10))
        history.append(pose(1, at: 10.03, valid: false))
        XCTAssertEqual(history.reading(near: 10.02)?.orientationMatchesConfiguration, false)
    }
}
