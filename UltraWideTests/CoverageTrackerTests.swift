import XCTest
@testable import UltraWide

final class CoverageTrackerTests: XCTestCase {
    private func plan(aspect: Double = 16.0 / 9.0) throws -> CapturePlan {
        try XCTUnwrap(CapturePlan.make(
            lens: .wide,
            target: .half,
            orientation: .landscapeLeft,
            wideHorizontalFOV: 75,
            lensHorizontalFOV: 75,
            sourceLandscapeAspectRatio: aspect
        ))
    }

    func testActualVideoAspectChangesVerticalFootprint() throws {
        let video = try plan(aspect: 16.0 / 9.0)
        let still = try plan(aspect: 4.0 / 3.0)

        XCTAssertLessThan(video.sourceVerticalFOV, still.sourceVerticalFOV)
        XCTAssertEqual(video.targetVerticalFOV, still.targetVerticalFOV, accuracy: 0.001)
        let videoView = CoverageTracker(plan: video).coverage(viewYaw: 0, viewPitch: 0).viewRect
        let stillView = CoverageTracker(plan: still).coverage(viewYaw: 0, viewPitch: 0).viewRect
        XCTAssertLessThan(videoView.height, stillView.height)
    }

    func testFreeSweepAcceptsAnyConnectedDirection() throws {
        var tracker = CoverageTracker(plan: try plan())
        XCTAssertTrue(tracker.shouldKeep(yaw: 0, pitch: 0))
        tracker.include(yaw: 0, pitch: 0)
        let centerFraction = tracker.fraction
        XCTAssertGreaterThan(centerFraction, 0)
        XCTAssertLessThan(centerFraction, 1)

        XCTAssertFalse(tracker.shouldKeep(yaw: 48, pitch: 38))
        XCTAssertTrue(tracker.shouldKeep(yaw: -20, pitch: 0))
        tracker.include(yaw: -20, pitch: 0)
        XCTAssertTrue(tracker.shouldKeep(yaw: -20, pitch: 15))
        tracker.include(yaw: -20, pitch: 15)
        XCTAssertGreaterThan(tracker.fraction, centerFraction)
    }

    func testCenterAloneCannotCompleteRequestedField() throws {
        var tracker = CoverageTracker(plan: try plan())
        tracker.include(yaw: 0, pitch: 0)
        XCTAssertFalse(tracker.isComplete)
        XCTAssertLessThan(tracker.fraction, 0.5)
    }

    func testCoverageUsesExactProjectedArea() throws {
        var tracker = CoverageTracker(plan: try plan())
        let view = tracker.footprint(yaw: 0, pitch: 0)
        let reliable = view.insetBy(dx: view.width * 0.07,
                                    dy: view.height * 0.07)
        let target = CGRect(x: -0.025, y: -0.025, width: 1.05, height: 1.05)
        let covered = reliable.intersection(target)
        tracker.include(yaw: 0, pitch: 0)
        XCTAssertEqual(tracker.fraction,
                       covered.width * covered.height / target.width / target.height,
                       accuracy: 1e-10)
    }

    func testConnectedFreeSweepCompletesWithinFrameBudget() throws {
        let landscape = try plan()
        var tracker = CoverageTracker(plan: landscape)
        var retained: [CapturedFrame] = []
        var accepted = 0
        func consider(_ yaw: Double, _ pitch: Double) {
            if tracker.shouldKeep(yaw: yaw, pitch: pitch) {
                retained.append(frame(yaw: yaw, pitch: pitch))
                retained = SweepFrameReducer.reduced(retained, plan: landscape)
                tracker = CoverageTracker(plan: landscape, frames: retained)
                accepted = max(accepted, retained.count)
            }
        }
        consider(0, 0)
        for pitch in stride(from: -5.0, through: -40.0, by: -5.0) {
            consider(0, pitch)
        }
        for yaw in stride(from: -5.0, through: -50.0, by: -5.0) {
            consider(yaw, -40)
        }
        for (row, pitch) in Array(stride(from: -40.0, through: 40.0, by: 5.0)).enumerated() {
            let yaws = row.isMultiple(of: 2)
                ? Array(stride(from: -50.0, through: 50.0, by: 5.0))
                : Array(stride(from: 50.0, through: -50.0, by: -5.0))
            for yaw in yaws {
                consider(yaw, pitch)
                if tracker.isComplete { break }
            }
            if tracker.isComplete { break }
        }
        XCTAssertTrue(tracker.isComplete)
        XCTAssertLessThanOrEqual(accepted, 40)
    }

    func testPortraitVideoSweepCompletesWithinFrameBudget() throws {
        let portrait = try XCTUnwrap(CapturePlan.make(
            lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 75, lensHorizontalFOV: 75,
            sourceLandscapeAspectRatio: 16.0 / 9.0
        ))
        var tracker = CoverageTracker(plan: portrait)
        var retained: [CapturedFrame] = []
        var accepted = 0
        func consider(_ yaw: Double, _ pitch: Double) {
            if tracker.shouldKeep(yaw: yaw, pitch: pitch) {
                retained.append(frame(yaw: yaw, pitch: pitch))
                retained = SweepFrameReducer.reduced(retained, plan: portrait)
                tracker = CoverageTracker(plan: portrait, frames: retained)
                accepted = max(accepted, retained.count)
            }
        }
        consider(0, 0)
        for pitch in stride(from: -5.0, through: -50.0, by: -5.0) {
            consider(0, pitch)
        }
        for yaw in stride(from: -5.0, through: -40.0, by: -5.0) {
            consider(yaw, -50)
        }
        for (row, pitch) in Array(stride(from: -50.0, through: 50.0, by: 5.0)).enumerated() {
            let yaws = row.isMultiple(of: 2)
                ? Array(stride(from: -40.0, through: 40.0, by: 5.0))
                : Array(stride(from: 40.0, through: -40.0, by: -5.0))
            for yaw in yaws {
                consider(yaw, pitch)
                if tracker.isComplete { break }
            }
            if tracker.isComplete { break }
        }
        XCTAssertTrue(tracker.isComplete)
        XCTAssertLessThanOrEqual(accepted, 40)
    }

    func testSmallFinalCornerAdjustmentIsCapturedWithoutAnotherLargeTurn() throws {
        let portrait = try XCTUnwrap(CapturePlan.make(
            lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 75, lensHorizontalFOV: 75,
            sourceLandscapeAspectRatio: 16.0 / 9.0
        ))
        var tracker = CoverageTracker(plan: portrait)
        for yaw in [-29.0, 0, 29] {
            for pitch in [-29.0, 0, 29] {
                tracker.include(yaw: yaw == -29 && pitch == -29 ? -28 : yaw, pitch: pitch)
            }
        }
        XCTAssertEqual(tracker.fraction, 0.995102, accuracy: 0.00001)
        XCTAssertFalse(tracker.isComplete)
        XCTAssertFalse(tracker.shouldKeep(yaw: -28, pitch: -29))
        XCTAssertTrue(tracker.shouldKeep(yaw: -29, pitch: -29))
        tracker.include(yaw: -29, pitch: -29)
        XCTAssertTrue(tracker.isComplete)
    }

    func testSmallUsefulTurnCanBeCapturedInsteadOfWaitingForThirdOfField() throws {
        var tracker = CoverageTracker(plan: try plan())
        tracker.include(yaw: 0, pitch: 0)
        XCTAssertTrue(tracker.shouldKeep(yaw: 9, pitch: 0))
        XCTAssertFalse(tracker.shouldKeep(yaw: 0, pitch: 0))
    }

    private func frame(yaw: Double, pitch: Double) -> CapturedFrame {
        let id = UUID()
        return CapturedFrame(id: id, slotID: id.uuidString,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(id).jpg"),
            pass: 1, capturedAt: Date(), yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: 0,
            sharpnessScore: 100, meanBrightness: 0.5, quality: .good)
    }
}
