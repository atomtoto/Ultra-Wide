import XCTest
@testable import UltraWide

final class SweepCapturePolicyTests: XCTestCase {
    private let soft = PhotoQualityResult(sharpness: 20, brightness: 0.4, quality: .soft)

    func testSteadySoftSceneStopsWaitingWithinTwoTenthsOfASecond() {
        var policy = SweepCapturePolicy()
        policy.rejected(soft, at: 10)
        policy.rejected(soft, at: 10.1)
        XCTAssertFalse(policy.allowsSoftFrame(at: 10.1, angularSpeed: 0))
        XCTAssertTrue(policy.allowsSoftFrame(at: 10.2, angularSpeed: 0))
        XCTAssertTrue(SweepCapturePolicy.shouldEncode(
            soft, allowSoftFrame: policy.allowsSoftFrame(at: 10.2, angularSpeed: 0)
        ))
    }

    func testFastBlurredMotionDoesNotBypassQualityAfterTimeout() {
        var policy = SweepCapturePolicy()
        policy.rejected(soft, at: 10)
        XCTAssertFalse(policy.allowsSoftFrame(at: 11, angularSpeed: 0.8))
        policy.reset()
        XCTAssertFalse(policy.allowsSoftFrame(at: 11, angularSpeed: 0))
    }

    func testDarkSceneCanBeCapturedButBlackFrameIsRejected() {
        let darkScene = PhotoQualityResult(sharpness: 60, brightness: 0.07, quality: .dark)
        let blackFrame = PhotoQualityResult(sharpness: 0, brightness: 0.005, quality: .dark)
        XCTAssertTrue(SweepCapturePolicy.shouldEncode(darkScene, allowSoftFrame: false))
        XCTAssertFalse(SweepCapturePolicy.shouldEncode(blackFrame, allowSoftFrame: true))
    }
}
