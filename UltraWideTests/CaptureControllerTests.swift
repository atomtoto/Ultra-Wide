import AVFoundation
import Combine
import CoreVideo
import QuartzCore
import XCTest
@testable import UltraWide

@MainActor
final class CaptureControllerTests: XCTestCase {
    func testSinglePhotoForwardsOutputResolutionToCamera() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        let expected = SinglePhotoResult(url: folder.appendingPathComponent("photo.jpg"),
                                         pixelWidth: 2308, pixelHeight: 1731)
        camera.singlePhotoResult = expected
        let capture = makeCaptureController(camera: camera, motion: TestMotionProvider(),
            store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .one)
        let result = try await capture.captureSinglePhoto(to: folder.appendingPathComponent("photo"),
                                                         maximumMegapixels: 4)
        XCTAssertEqual(camera.singlePhotoMaximumMegapixels, 4)
        XCTAssertEqual(result.url, expected.url)
        XCTAssertEqual(result.pixelWidth, expected.pixelWidth)
        XCTAssertEqual(result.pixelHeight, expected.pixelHeight)
        XCTAssertEqual(capture.status, .idle)
    }

    func testGuidanceSurvivesFrameEvictionWhileRegistrationIsBlocked() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        _ = try await storedSweep(in: store, count: 60)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        let assembler = GatedSweepAssembler(reducesFrames: false)
        await assembler.release()
        let capture = CaptureController(camera: camera, motion: motion, store: store, visualAssembler: assembler)
        try await capture.resume()
        for _ in 0..<200 {
            if !capture.isVerifyingAlignment { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(capture.sweepAnalysis?.target(from: CGPoint(x: 0.5, y: 0.5)))
        await assembler.holdUpdates()
        motion.emit(yaw: 0, speed: 0)
        try capture.confirmReferenceAlignment()
        try await capture.beginSweep()
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 20)
        for _ in 0..<200 {
            if capture.currentSnapshot?.frames.contains(where: { $0.yawDegrees == 20 }) == true,
               capture.sweepAnalysis != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(capture.currentSnapshot?.frames.contains { $0.yawDegrees == 20 } ?? false)
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 60)
        XCTAssertTrue(capture.isVerifyingAlignment)
        XCTAssertFalse(capture.visualCoverage?.isComplete ?? true)
        XCTAssertNotNil(capture.sweepAnalysis?.target(from: CGPoint(x: 0.5, y: 0.5)),
                        "Retiring a source must not remove guidance until the image worker catches up.")
        capture.discard()
        await assembler.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(capture.sweepAnalysis, "A pending analysis cannot restore a discarded session.")
    }

    func testCameraAdjustmentsApplyInPreviewAndAreLockedDuringSweep() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let capture = makeCaptureController(camera: camera, motion: TestMotionProvider(),
            store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half)
        XCTAssertTrue(capture.canAdjustCamera)
        let point = CGPoint(x: 0.2, y: 0.7)
        try await capture.setMeteringPoint(point)
        try await capture.setExposureBias(-1.2)
        XCTAssertEqual(camera.meteringPoint, point)
        XCTAssertEqual(capture.exposureBias, -1.2)
        try await capture.beginSweep()
        XCTAssertFalse(capture.canAdjustCamera)
        do { try await capture.setMeteringPoint(CGPoint(x: 0.8, y: 0.8)); XCTFail("Focus changed during sweep") }
        catch CaptureError.notReady { }
        do { try await capture.setExposureBias(1); XCTFail("Exposure changed during sweep") }
        catch CaptureError.notReady { }
        XCTAssertEqual(camera.meteringPoint, point)
        XCTAssertEqual(camera.exposureBias, -1.2)
        capture.pause()
    }

    func testFrameBudgetKeepsAcquiringUntilTheMissingEdgesAreVerified() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let saved = try await storedSweep(in: store, count: 59)
        let anchor = try XCTUnwrap(saved.frames.first)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        let capture = CaptureController(camera: camera, motion: motion, store: store,
            visualAssembler: TestSweepAssembler(reducesFrames: false))
        try await capture.resume()
        motion.emit(yaw: 0, speed: 0)
        try capture.confirmReferenceAlignment()
        try await capture.beginSweep()
        let path: [(Double, Double)] = [
            (12, 0), (20, 0), (29, 0), (29, 15), (29, 29), (15, 29),
            (0, 29), (-15, 29), (-29, 29), (-29, 15), (-29, 0),
            (-29, -15), (-29, -29), (-15, -29), (0, -29), (15, -29), (29, -29)
        ]
        for (index, pose) in path.enumerated() {
            if capture.status == .reviewing { break }
            try await Task.sleep(for: .milliseconds(40))
            motion.emit(yaw: pose.0, pitch: pose.1)
            for _ in 0..<400 {
                if capture.status == .reviewing { break }
                if capture.currentSnapshot?.frames.contains(where: {
                    $0.yawDegrees == pose.0 && $0.pitchDegrees == pose.1
                }) == true, !capture.isVerifyingAlignment { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            if index == 0 {
                XCTAssertEqual(capture.currentSnapshot?.frames.count, 60)
                XCTAssertEqual(capture.status, .capturing, "60 images cannot mean a complete field.")
                XCTAssertFalse(capture.isFinishingSweep)
                XCTAssertFalse(capture.visualCoverage?.isComplete ?? true)
            }
            XCTAssertLessThanOrEqual(capture.currentSnapshot?.frames.count ?? 0, capture.maximumFrames)
            XCTAssertLessThanOrEqual(capture.completedCount, capture.maximumFrames + SweepFrameQueue.capacity)
        }
        for _ in 0..<400 {
            if capture.status == .reviewing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(capture.status, .reviewing)
        XCTAssertTrue(capture.visualCoverage?.isComplete ?? false)
        let final = try store.load()
        XCTAssertTrue(final.isComplete)
        XCTAssertTrue(final.frames.contains { $0.id == anchor.id })
        XCTAssertEqual(final.frames, capture.currentSnapshot?.frames)
        XCTAssertEqual(final.frames.count, 60)
        XCTAssertGreaterThan(camera.selectedCount, 1, "New exposures must replace older sources at capacity.")
        let originalIDs = Set(final.frames.map(\.id))
        let retired = saved.frames.filter { !originalIDs.contains($0.id) }
        XCTAssertFalse(retired.isEmpty)
        XCTAssertTrue(retired.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        XCTAssertTrue(final.frames.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        capture.pause()
    }

    func testOpenSessionAtCapacityResumesCaptureInsteadOfClosingIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        _ = try await storedSweep(in: store, count: 60)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        let capture = CaptureController(camera: camera, motion: motion, store: store,
            visualAssembler: TestSweepAssembler(reducesFrames: false))
        try await capture.resume()
        XCTAssertEqual(capture.status, .recalibrating)
        XCTAssertTrue(try store.load().isPassOpen)
        motion.emit(yaw: 0, speed: 0)
        try capture.confirmReferenceAlignment()
        try await capture.beginSweep()
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 15)
        for _ in 0..<400 {
            if capture.currentSnapshot?.frames.contains(where: { $0.yawDegrees == 15 }) == true { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(capture.status, .capturing)
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 60)
        XCTAssertTrue(capture.currentSnapshot?.frames.contains { $0.yawDegrees == 15 } ?? false)
        XCTAssertTrue(try store.load().isPassOpen)
        capture.pause()
    }

    func testAutomaticStopWaitsForPendingSourceAndItsLatestCoverage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        _ = try await storedSweep(in: store, count: 2)
        let camera = BufferedTestCamera()
        let motion = TestMotionProvider()
        let assembler = CoverageChangingSweepAssembler()
        let capture = CaptureController(camera: camera, motion: motion, store: store, visualAssembler: assembler)
        try await capture.resume()
        for _ in 0..<200 {
            if !capture.isVerifyingAlignment { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        await assembler.holdUpdates()
        motion.emit(yaw: 0, speed: 0)
        try capture.confirmReferenceAlignment()
        try await capture.beginSweep()
        for _ in 0..<200 {
            if await assembler.isPending() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let writing = expectation(description: "A new source is awaiting encoding")
        camera.onEncodeStarted = { writing.fulfill() }
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 20)
        await fulfillment(of: [writing], timeout: 1)
        camera.onEncodeStarted = nil
        await assembler.release()
        for _ in 0..<200 {
            if !capture.isVerifyingAlignment { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(capture.visualCoverage?.isComplete ?? false)
        XCTAssertFalse(capture.isFinishingSweep, "A full older update must not freeze the pending source.")
        XCTAssertEqual(capture.status, .capturing)
        let selectedBeforeCompletion = camera.selectedCount
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: -20)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(camera.selectedCount, selectedBeforeCompletion,
                       "Once coverage is full, new exposures must not keep extending the verification queue.")
        camera.unblockEncoder()
        for _ in 0..<200 {
            if capture.currentSnapshot?.frames.count == 3, !capture.isVerifyingAlignment { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 3)
        XCTAssertFalse(capture.visualCoverage?.isComplete ?? true)
        XCTAssertFalse(capture.isFinishingSweep)
        XCTAssertEqual(capture.status, .capturing)
        XCTAssertTrue(try store.load().isPassOpen)
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: -20)
        for _ in 0..<200 {
            if camera.selectedCount > selectedBeforeCompletion { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThan(camera.selectedCount, selectedBeforeCompletion,
                             "If the final verification finds a gap, acquisition must resume.")
        capture.pause()
    }

    func testCenterSelectionWaitsForAppliedExposureWithoutWaitingForEncoding() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.exposureBlocked = true
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion,
            store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half)
        let configuring = expectation(description: "Exposure configuration began")
        camera.onExposureStarted = { configuring.fulfill() }
        let writing = expectation(description: "Center selected and encoding began")
        camera.onEncodeStarted = { writing.fulfill() }
        let starting = Task { try await capture.beginSweep() }
        await fulfillment(of: [configuring], timeout: 1)
        XCTAssertEqual(camera.selectedCount, 0)
        XCTAssertNil(capture.currentSnapshot)
        XCTAssertTrue(capture.isCenterAnchoring)
        camera.unblockExposure()
        await fulfillment(of: [writing], timeout: 1)
        XCTAssertEqual(camera.selectedCount, 1)
        XCTAssertEqual(capture.status, .capturing)
        // The main actor and motion-driven selection remain available while
        // the first JPEG is still encoding with the now stable exposure.
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 12)
        for _ in 0..<100 {
            if camera.selectedCount == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(camera.selectedCount, 2)
        capture.pause()
        camera.unblockEncoder()
        try await starting.value
    }

    func testPauseDuringExposurePreparationCannotSelectAnOldCenter() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.exposureBlocked = true
        let capture = makeCaptureController(camera: camera, motion: TestMotionProvider(),
            store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half)
        let configuring = expectation(description: "Exposure configuration began")
        camera.onExposureStarted = { configuring.fulfill() }
        let starting = Task { try await capture.beginSweep() }
        await fulfillment(of: [configuring], timeout: 1)
        capture.pause()
        camera.unblockExposure()
        try await starting.value
        XCTAssertEqual(camera.selectedCount, 0)
        XCTAssertNil(capture.currentSnapshot)
        XCTAssertEqual(capture.status, .idle)
        XCTAssertFalse(capture.isCenterAnchoring)
    }

    func testColdReviewRebuildsVisualCoverageAndReservesRepairCapacity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let plan = try XCTUnwrap(CapturePlan.make(lens: .wide, target: .half,
            orientation: .portrait, wideHorizontalFOV: 75, lensHorizontalFOV: 75,
            sourceLandscapeAspectRatio: 16.0 / 9.0))
        var saved = CaptureSessionSnapshot(sessionID: UUID(), plan: plan, slots: [],
            currentPass: 1, isPassOpen: false, retakeCount: 0, coverageFraction: 0,
            createdAt: Date(), updatedAt: Date())
        try store.create(saved)
        for index in 0..<60 {
            let id = UUID()
            let url = try await store.writePhoto(Data([0xff, 0xd8, 0xff, 0xd9]),
                id: id, sessionID: saved.sessionID)
            let yaw = Double(index) * 0.01
            let frame = CapturedFrame(id: id, slotID: id.uuidString, fileURL: url,
                pass: 1, capturedAt: Date(), yawDegrees: yaw, pitchDegrees: 0,
                rollDegrees: 0, sharpnessScore: 100, meanBrightness: 0.5, quality: .good)
            saved.slots.append(CaptureSlot(id: frame.slotID, row: 1, column: 1,
                yawDegrees: yaw, pitchDegrees: 0, frame: frame))
        }
        try store.save(saved)
        let anchor = try XCTUnwrap(saved.frames.first)
        let capture = makeCaptureController(camera: BufferedTestCamera(),
            motion: TestMotionProvider(), store: store)
        XCTAssertNil(capture.visualCoverage)
        let rebuilt = expectation(description: "Saved views are registered before another exposure")
        let subscription = capture.$visualCoverage.first { $0 != nil }.sink { _ in rebuilt.fulfill() }
        try await capture.resume()
        await fulfillment(of: [rebuilt], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(capture.status, .reviewing)
        XCTAssertGreaterThan(try XCTUnwrap(capture.visualCoverage).fraction, 0)
        XCTAssertNotNil(capture.preparedStitchInputs)

        try await capture.resumeSweep()
        let repaired = try XCTUnwrap(capture.currentSnapshot)
        XCTAssertEqual(repaired.frames.count, 56)
        XCTAssertEqual(repaired.currentPass, 2)
        XCTAssertTrue(repaired.isPassOpen)
        XCTAssertTrue(repaired.frames.contains { $0.id == anchor.id })
        XCTAssertEqual(try store.load().frames.map(\.id), repaired.frames.map(\.id))
        XCTAssertTrue(repaired.frames.allSatisfy { FileManager.default.fileExists(atPath: $0.fileURL.path) })
        let retired = saved.frames.filter { old in !repaired.frames.contains { $0.id == old.id } }
        XCTAssertEqual(retired.count, 4)
        XCTAssertTrue(retired.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        capture.pause()
    }

    func testSweepWaitsForFirstMotionSampleAfterPreviewRotation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        motion.emitsOnStart = false
        let capture = makeCaptureController(camera: camera, motion: motion,
                                        store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half, orientation: .landscapeRight)
        let sample = Task {
            try await Task.sleep(for: .milliseconds(40))
            motion.emit(yaw: 0)
        }
        defer { sample.cancel() }
        try await capture.beginSweep()
        XCTAssertEqual(capture.status, .capturing)
        XCTAssertEqual(capture.currentSnapshot?.plan.orientation, .landscapeRight)
        XCTAssertEqual(capture.completedCount, 1)
        capture.pause()
    }

    func testFirstSweepDefinesRollAtShutterInsteadOfPreviewLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion,
                                        store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half)
        motion.emit(yaw: 0, roll: 35)
        XCTAssertNil(capture.currentSnapshot)
        XCTAssertFalse(capture.orientationNeedsCorrection)
        XCTAssertNil(capture.orientationCorrection)

        try await capture.beginSweep()
        XCTAssertEqual(capture.status, .capturing)
        XCTAssertEqual(capture.completedCount, 1)
        // After the first tap, rotating the frame does require correction.
        motion.emit(yaw: 0, roll: 35)
        XCTAssertTrue(capture.orientationNeedsCorrection)
        guard case .excessiveRoll? = capture.orientationCorrection else {
            return XCTFail("A tilted frame should request leveling, not a starting orientation")
        }
        motion.emit(yaw: 0)
        XCTAssertFalse(capture.orientationNeedsCorrection)
        capture.pause()
    }

    func testWrongPortraitLandscapeOrientationStillBlocksFirstSweep() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: BufferedTestCamera(), motion: motion,
                                        store: CaptureSessionStore(rootURL: folder))
        try await capture.preparePreview(lens: .wide, target: .half)
        motion.emit(yaw: 0, orientationValid: false)
        XCTAssertTrue(capture.orientationNeedsCorrection)
        do {
            try await capture.beginSweep()
            XCTFail("The capture must match the configured camera orientation")
        } catch CaptureError.orientationChanged { }
        XCTAssertNil(capture.currentSnapshot)
        // Reconfiguring a preview clears the old sensor warning, even when
        // switching to a direct photo that does not use motion guidance.
        try await capture.preparePreview(lens: .wide, target: .one)
        XCTAssertFalse(capture.orientationNeedsCorrection)
        XCTAssertNil(capture.orientationCorrection)
        capture.pause()
    }

    func testManualStopWaitsForVisualRegistrationWithoutBlockingCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let motion = TestMotionProvider()
        let assembler = GatedSweepAssembler()
        let capture = CaptureController(camera: camera, motion: motion,
            store: CaptureSessionStore(rootURL: folder), visualAssembler: assembler)
        try await capture.preparePreview(lens: .wide, target: .half)
        try await capture.beginSweep()
        let selected = expectation(description: "Acquisition continues during registration")
        camera.onSelected = { selected.fulfill() }
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 12)
        await fulfillment(of: [selected], timeout: 1)
        for _ in 0..<100 {
            if capture.currentSnapshot?.frames.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 2)
        XCTAssertNil(capture.visualCoverage)
        XCTAssertTrue(capture.isVerifyingAlignment)
        let stopping = Task { try await capture.stopSweep() }
        await Task.yield()
        XCTAssertEqual(capture.status, .capturing)
        XCTAssertTrue(capture.isFinishingSweep)
        await assembler.release()
        let saved = try await stopping.value
        XCTAssertEqual(capture.status, .reviewing)
        XCTAssertEqual(capture.preparedStitchInputs?.count, 2)
        XCTAssertEqual(saved.coverageFraction, capture.visualCoverage?.fraction)
        XCTAssertFalse(capture.isVerifyingAlignment)
        capture.pause()
    }

    func testDiscardRejectsAnOldVisualUpdate() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        let assembler = GatedSweepAssembler()
        let capture = CaptureController(camera: camera, motion: TestMotionProvider(),
            store: CaptureSessionStore(rootURL: folder), visualAssembler: assembler)
        try await capture.preparePreview(lens: .wide, target: .half)
        try await capture.beginSweep()
        for _ in 0..<100 {
            if await assembler.isPending() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        capture.discard()
        await assembler.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(capture.status, .idle)
        XCTAssertNil(capture.visualCoverage)
        XCTAssertNil(capture.assemblyPreview)
        XCTAssertNil(capture.preparedStitchInputs)
        XCTAssertFalse(capture.isVerifyingAlignment)
        XCTAssertNil(capture.currentSnapshot)
    }

    func testSoftExposureAtNaturalTiltIsCapturedAfterSingleSmallTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        camera.quality = PhotoQualityResult(sharpness: 12, brightness: 0.5, quality: .soft)
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion, store: store)
        try await capture.preparePreview(lens: .wide, target: .half)
        try await capture.beginSweep()
        let captured = expectation(description: "Useful soft exposure captured on first movement")
        let subscription = capture.$slots.first { $0.count >= 2 }.sink { _ in captured.fulfill() }
        try await Task.sleep(for: .milliseconds(40))
        motion.emit(yaw: 8, roll: 15, speed: 1.8)
        await fulfillment(of: [captured], timeout: 0.5)
        subscription.cancel()
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 2)
        XCTAssertEqual(capture.currentSnapshot?.frames.last?.rollDegrees, 15)
        XCTAssertFalse(capture.orientationNeedsCorrection)
        capture.pause()
    }

    func testBriskContinuousSweepWithTiltCompletesWithinRetainedFrameBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        camera.quality = PhotoQualityResult(sharpness: 12, brightness: 0.5, quality: .soft)
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion, store: store)
        try await capture.preparePreview(lens: .wide, target: .half)
        try await capture.beginSweep()
        let finished = expectation(description: "Continuous hand sweep completed")
        let subscription = capture.$status.first { $0 == .reviewing }.sink { _ in finished.fulfill() }
        let path: [(Double, Double)] = [
            (0, 0), (0, -32), (-32, -32), (32, -32), (32, 0),
            (-32, 0), (-32, 32), (32, 32)
        ]
        var peakFrames = capture.completedCount
        for (start, end) in zip(path, path.dropFirst()) {
            let steps = Int(ceil(hypot(end.0 - start.0, end.1 - start.1) / 3))
            for step in 1...steps {
                if capture.status != .capturing || capture.isFinishingSweep { break }
                try await Task.sleep(for: .milliseconds(36))
                let fraction = Double(step) / Double(steps)
                motion.emit(yaw: start.0 + (end.0 - start.0) * fraction,
                            pitch: start.1 + (end.1 - start.1) * fraction,
                            roll: 12, speed: 1.6)
                peakFrames = max(peakFrames, capture.completedCount)
            }
        }
        await fulfillment(of: [finished], timeout: 2)
        subscription.cancel()
        XCTAssertEqual(capture.status, .reviewing)
        XCTAssertTrue(try XCTUnwrap(capture.currentSnapshot).isComplete)
        XCTAssertLessThan(peakFrames, capture.maximumFrames)
        let snapshot = try store.load()
        XCTAssertEqual(snapshot.frames, capture.currentSnapshot?.frames)
        for frame in snapshot.frames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: frame.fileURL.path))
        }
    }

    func testLiveCoverageAdvancesWhileJPEGIsBlockedAndStopFlushesSelectedFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let camera = BufferedTestCamera()
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion, store: store)
        // The simulated camera requires no permission prompt on the simulator.
        try await capture.preparePreview(lens: .wide, target: .half)
        let writing = expectation(description: "Center JPEG encoding started")
        camera.onEncodeStarted = { writing.fulfill() }
        let starting = Task { try await capture.beginSweep() }
        await fulfillment(of: [writing], timeout: 1)
        let centerCoverage = try XCTUnwrap(capture.coverage).fraction
        XCTAssertEqual(capture.completedCount, 1)
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 0)
        camera.onEncodeStarted = nil

        let selected = expectation(description: "Next exposure selected while JPEG writer is blocked")
        camera.onSelected = { selected.fulfill() }
        try await Task.sleep(for: .milliseconds(80))
        motion.emit(yaw: 20)
        await fulfillment(of: [selected], timeout: 1)
        // Let the main actor reserve the buffer following its async analysis.
        await Task.yield()
        XCTAssertEqual(capture.completedCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(capture.coverage).fraction, centerCoverage)
        XCTAssertEqual(capture.currentSnapshot?.frames.count, 0)
        let stopping = Task { try await capture.stopSweep() }
        await Task.yield()
        XCTAssertTrue(capture.isFinishingSweep)
        XCTAssertEqual(capture.status, .capturing)

        camera.unblockEncoder()
        let finished = try await stopping.value
        try await starting.value
        XCTAssertEqual(capture.status, .reviewing)
        XCTAssertFalse(capture.isFinishingSweep)
        XCTAssertFalse(capture.isCenterAnchoring)
        XCTAssertEqual(finished.frames.count, 2)
        XCTAssertFalse(finished.isPassOpen)
        XCTAssertEqual(try store.load().frames, finished.frames)
        for frame in finished.frames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: frame.fileURL.path))
        }
    }

    func testPauseDropsPendingBufferAndNeverPersistsItIntoPausedSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let camera = BufferedTestCamera()
        let capture = makeCaptureController(camera: camera, motion: TestMotionProvider(), store: store)
        try await capture.preparePreview(lens: .wide, target: .half)
        let writing = expectation(description: "Center JPEG pending")
        camera.onEncodeStarted = { writing.fulfill() }
        let starting = Task { try await capture.beginSweep() }
        await fulfillment(of: [writing], timeout: 1)
        XCTAssertGreaterThan(try XCTUnwrap(capture.coverage).fraction, 0)
        capture.pause()
        XCTAssertEqual(capture.completedCount, 0)
        XCTAssertEqual(capture.coverage?.fraction, 0)
        camera.unblockEncoder()
        try await starting.value
        XCTAssertEqual(capture.status, .paused)
        XCTAssertTrue(capture.hasRecoverableSession)
        XCTAssertEqual(try store.load().frames.count, 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("current").path)
        XCTAssertEqual(files, ["session.json"])
    }

    func testFinalCornerAutomaticallyFinishesAfterPendingFileIsWritten() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let plan = try XCTUnwrap(CapturePlan.make(
            lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 75, lensHorizontalFOV: 75,
            sourceLandscapeAspectRatio: 16.0 / 9.0
        ))
        var saved = CaptureSessionSnapshot(
            sessionID: UUID(), plan: plan, slots: [], currentPass: 1, isPassOpen: true,
            retakeCount: 0, coverageFraction: 0, createdAt: Date(), updatedAt: Date()
        )
        try store.create(saved)
        for yaw in [-29.0, 0, 29] {
            for pitch in [-29.0, 0, 29] {
                let id = UUID()
                let url = try await store.writePhoto(Data([0xff, 0xd8, 0xff, 0xd9]),
                                                    id: id, sessionID: saved.sessionID)
                let frame = CapturedFrame(
                    id: id, slotID: id.uuidString, fileURL: url, pass: 1, capturedAt: Date(),
                    yawDegrees: yaw == -29 && pitch == -29 ? -28 : yaw,
                    pitchDegrees: pitch, rollDegrees: 0, sharpnessScore: 100,
                    meanBrightness: 0.5, quality: .good
                )
                saved.slots.append(CaptureSlot(id: frame.slotID, row: 1, column: 1,
                                               yawDegrees: frame.yawDegrees,
                                               pitchDegrees: pitch, frame: frame))
            }
        }
        saved.coverageFraction = CoverageTracker(plan: plan, frames: saved.frames).fraction
        try store.save(saved)
        let camera = BufferedTestCamera()
        let motion = TestMotionProvider()
        let capture = makeCaptureController(camera: camera, motion: motion, store: store)
        try await capture.resume()
        motion.emit(yaw: 0, speed: 0)
        try capture.confirmReferenceAlignment()
        try await capture.beginSweep()
        let writing = expectation(description: "Final exposure encoding started")
        camera.onEncodeStarted = { writing.fulfill() }
        try await Task.sleep(for: .milliseconds(80))
        motion.emit(yaw: -29, pitch: -29)
        await fulfillment(of: [writing], timeout: 1)
        XCTAssertEqual(capture.coverage?.fraction, 1)
        XCTAssertFalse(capture.isFinishingSweep)
        XCTAssertFalse(capture.visualCoverage?.isComplete ?? false)
        XCTAssertFalse(try XCTUnwrap(capture.currentSnapshot).isComplete)
        let finished = expectation(description: "Automatic review after saving final image")
        let subscription = capture.$status.first { $0 == .reviewing }.sink { _ in finished.fulfill() }
        camera.unblockEncoder()
        await fulfillment(of: [finished], timeout: 2)
        subscription.cancel()
        let recovered = try store.load()
        XCTAssertTrue(recovered.isComplete)
        XCTAssertFalse(recovered.isPassOpen)
        XCTAssertEqual(recovered.frames.count, 10)
        XCTAssertEqual(capture.completedCount, 10)
    }
}

@MainActor
private final class BufferedTestCamera: CameraCapturing {
    let session = AVCaptureSession()
    let supportedLenses: [CaptureLens] = [.wide]
    var onSelected: (() -> Void)?
    var onEncodeStarted: (() -> Void)?
    var onExposureStarted: (() -> Void)?
    var exposureBlocked = false
    private(set) var selectedCount = 0
    var quality = PhotoQualityResult(sharpness: 100, brightness: 0.5, quality: .good)
    var meteringPoint: CGPoint?
    var exposureBias: Float = 0
    var singlePhotoResult: SinglePhotoResult?
    private(set) var singlePhotoMaximumMegapixels: Int?
    private var encoder: CheckedContinuation<Void, Never>?
    private var encoderBlocked = true
    private var exposure: CheckedContinuation<Void, Never>?
    func fieldOfView(for lens: CaptureLens) -> Double? { 75 }
    func ensurePermission() async throws { }
    func configure(lens: CaptureLens, orientation: CaptureOrientation, zoomFactor: Double) async throws { }
    func videoLandscapeAspectRatio() async throws -> Double { 16.0 / 9.0 }
    func setMeteringPoint(_ point: CGPoint) async throws { meteringPoint = point }
    func setExposureBias(_ value: Float) async throws -> Float { exposureBias = value; return value }
    func prepareForSweep() async throws {
        onExposureStarted?()
        if exposureBlocked { await withCheckedContinuation { exposure = $0 } }
    }
    func unblockExposure() { exposureBlocked = false; exposure?.resume(); exposure = nil }
    func pause() { }
    func selectVideoFrame(near motionTimestamp: TimeInterval) async throws -> SelectedVideoFrame {
        selectedCount += 1
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 8, 8, kCVPixelFormatType_32BGRA, nil, &buffer)
        onSelected?()
        return SelectedVideoFrame(
            pixelBuffer: try XCTUnwrap(buffer),
            quality: quality,
            timestamp: motionTimestamp
        )
    }
    func encodeSelectedFrame(_ selected: SelectedVideoFrame) async throws -> Data {
        onEncodeStarted?()
        if encoderBlocked { await withCheckedContinuation { encoder = $0 } }
        return Data([0xff, 0xd8, 0xff, 0xd9])
    }
    func unblockEncoder() { encoderBlocked = false; encoder?.resume(); encoder = nil }
    func captureSinglePhoto(to baseURL: URL, cropFactor: Double, maximumMegapixels: Int) async throws -> SinglePhotoResult {
        singlePhotoMaximumMegapixels = maximumMegapixels
        guard let singlePhotoResult else { throw CaptureError.notReady }
        return singlePhotoResult
    }
}

@MainActor
private final class TestMotionProvider: CaptureMotionProviding {
    var onReading: ((MotionReading) -> Void)?
    var isActive = false
    var hasReference = false
    var emitsOnStart = true
    private var latest: MotionReading?
    func start(orientation: CaptureOrientation, resetReference: Bool) throws {
        isActive = true
        hasReference = true
        if emitsOnStart { emit(yaw: 0) }
    }
    func recenter() throws -> MotionReading { emit(yaw: 0); return try XCTUnwrap(latest) }
    func reading(near timestamp: TimeInterval) -> MotionReading? { latest }
    func stop() { isActive = false; hasReference = false }
    func suspendSampling() { }
    func emit(yaw: Double, pitch: Double = 0, roll: Double = 0, speed: Double = 0.8,
              orientationValid: Bool = true) {
        let pose = MotionReading(yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll,
                                 angularSpeed: speed, orientationMatchesConfiguration: orientationValid,
                                 sampleTimestamp: CACurrentMediaTime())
        latest = pose
        onReading?(pose)
    }
}

@MainActor
private func makeCaptureController(camera: (any CameraCapturing)? = nil,
    motion: (any CaptureMotionProviding)? = nil, store: CaptureSessionStore? = nil) -> CaptureController {
    CaptureController(camera: camera, motion: motion, store: store, visualAssembler: TestSweepAssembler())
}

/// Controller tests supply already-verified image footprints independently of
/// the actual Vision registration tests, which use textured source images.
private struct TestSweepAssembler: SweepAssembling {
    var reducesFrames = true
    func update(sessionID: UUID, plan: CapturePlan, frames: [CapturedFrame]) async throws -> ProgressiveSweepUpdate {
        let retained = reducesFrames ? SweepFrameReducer.reduced(frames, plan: plan) : frames
        let tracker = CoverageTracker(plan: plan)
        var polygons: [UUID: [CGPoint]] = [:]
        var alignments: [UUID: StitchAlignment] = [:]
        for frame in retained {
            let rect = tracker.footprint(yaw: frame.yawDegrees, pitch: frame.pitchDegrees)
            let reliable = rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07)
            polygons[frame.id] = [CGPoint(x: reliable.minX, y: reliable.minY),
                CGPoint(x: reliable.maxX, y: reliable.minY), CGPoint(x: reliable.maxX, y: reliable.maxY),
                CGPoint(x: reliable.minX, y: reliable.maxY)]
            alignments[frame.id] = StitchAlignment(normalizedHomography:
                [rect.width, 0, rect.minX, 0, rect.height, rect.minY, 0, 0, 1],
                sourcePixelWidth: 8, sourcePixelHeight: 8)
        }
        return ProgressiveSweepUpdate(sessionID: sessionID, frameIDs: Set(frames.map(\.id)),
            alignments: alignments, polygonsByFrame: polygons, rejectedFrameIDs: [],
            retainedFrameIDs: Set(retained.map(\.id)), preview: nil)
    }
}

private actor CoverageChangingSweepAssembler: SweepAssembling {
    private var blocked = false
    private var gate: CheckedContinuation<Void, Never>?
    func holdUpdates() { blocked = true }
    func isPending() -> Bool { gate != nil }
    func release() { blocked = false; gate?.resume(); gate = nil }
    func update(sessionID: UUID, plan: CapturePlan, frames: [CapturedFrame]) async throws -> ProgressiveSweepUpdate {
        if blocked { await withCheckedContinuation { gate = $0 } }
        let right = frames.count <= 2 ? 1.1 : 0.9
        let polygon = [CGPoint(x: -0.1, y: -0.1), CGPoint(x: right, y: -0.1),
                       CGPoint(x: right, y: 1.1), CGPoint(x: -0.1, y: 1.1)]
        return ProgressiveSweepUpdate(sessionID: sessionID, frameIDs: Set(frames.map(\.id)),
            alignments: [:], polygonsByFrame: Dictionary(uniqueKeysWithValues: frames.map { ($0.id, polygon) }),
            rejectedFrameIDs: [], retainedFrameIDs: Set(frames.map(\.id)), preview: nil)
    }
}

@MainActor
private func storedSweep(in store: CaptureSessionStore, count: Int) async throws -> CaptureSessionSnapshot {
    let plan = try XCTUnwrap(CapturePlan.make(lens: .wide, target: .half,
        orientation: .portrait, wideHorizontalFOV: 75, lensHorizontalFOV: 75,
        sourceLandscapeAspectRatio: 16.0 / 9.0))
    var saved = CaptureSessionSnapshot(sessionID: UUID(), plan: plan, slots: [],
        currentPass: 1, isPassOpen: true, retakeCount: 0, coverageFraction: 0,
        createdAt: Date(), updatedAt: Date())
    try store.create(saved)
    for index in 0..<count {
        let id = UUID()
        let url = try await store.writePhoto(Data([0xff, 0xd8, 0xff, 0xd9]), id: id, sessionID: saved.sessionID)
        let frame = CapturedFrame(id: id, slotID: id.uuidString, fileURL: url,
            pass: 1, capturedAt: Date(), yawDegrees: Double(index) * 0.01, pitchDegrees: 0,
            rollDegrees: 0, sharpnessScore: 100, meanBrightness: 0.5, quality: .good)
        saved.slots.append(CaptureSlot(id: frame.slotID, row: 1, column: 1,
            yawDegrees: frame.yawDegrees, pitchDegrees: 0, frame: frame))
    }
    try store.save(saved)
    return saved
}

private actor GatedSweepAssembler: SweepAssembling {
    private var gate: CheckedContinuation<Void, Never>?
    private var blocked = true
    private let reducesFrames: Bool
    init(reducesFrames: Bool = true) { self.reducesFrames = reducesFrames }
    func holdUpdates() { blocked = true }
    func update(sessionID: UUID, plan: CapturePlan, frames: [CapturedFrame]) async throws -> ProgressiveSweepUpdate {
        if blocked { await withCheckedContinuation { gate = $0 } }
        return try await TestSweepAssembler(reducesFrames: reducesFrames).update(sessionID: sessionID, plan: plan, frames: frames)
    }
    func isPending() -> Bool { gate != nil }
    func release() { blocked = false; gate?.resume(); gate = nil }
}
