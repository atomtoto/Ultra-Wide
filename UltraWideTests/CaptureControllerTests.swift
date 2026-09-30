import AVFoundation
import Combine
import CoreVideo
import QuartzCore
import XCTest
@testable import UltraWide

@MainActor
final class CaptureControllerTests: XCTestCase {
    func testSoftExposureAtNaturalTiltIsCapturedAfterSingleSmallTurn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let camera = BufferedTestCamera()
        camera.unblockEncoder()
        camera.quality = PhotoQualityResult(sharpness: 12, brightness: 0.5, quality: .soft)
        let motion = TestMotionProvider()
        let capture = CaptureController(camera: camera, motion: motion, store: store)
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
        let capture = CaptureController(camera: camera, motion: motion, store: store)
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
        let capture = CaptureController(camera: camera, motion: motion, store: store)
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
        let capture = CaptureController(camera: camera, motion: TestMotionProvider(), store: store)
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
        let capture = CaptureController(camera: camera, motion: motion, store: store)
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
        XCTAssertTrue(capture.isFinishingSweep)
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
    var quality = PhotoQualityResult(sharpness: 100, brightness: 0.5, quality: .good)
    private var encoder: CheckedContinuation<Void, Never>?
    private var encoderBlocked = true
    func fieldOfView(for lens: CaptureLens) -> Double? { 75 }
    func ensurePermission() async throws { }
    func configure(lens: CaptureLens, orientation: CaptureOrientation, zoomFactor: Double) async throws { }
    func videoLandscapeAspectRatio() async throws -> Double { 16.0 / 9.0 }
    func prepareForSweep() async throws { }
    func pause() { }
    func selectVideoFrame(near motionTimestamp: TimeInterval) async throws -> SelectedVideoFrame {
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
    func captureSinglePhoto(to baseURL: URL, cropFactor: Double) async throws -> SinglePhotoResult {
        throw CaptureError.notReady
    }
}

@MainActor
private final class TestMotionProvider: CaptureMotionProviding {
    var onReading: ((MotionReading) -> Void)?
    var isActive = false
    var hasReference = false
    private var latest: MotionReading?
    func start(orientation: CaptureOrientation, resetReference: Bool) throws {
        isActive = true
        hasReference = true
        emit(yaw: 0)
    }
    func recenter() throws -> MotionReading { emit(yaw: 0); return try XCTUnwrap(latest) }
    func reading(near timestamp: TimeInterval) -> MotionReading? { latest }
    func stop() { isActive = false; hasReference = false }
    func suspendSampling() { }
    func emit(yaw: Double, pitch: Double = 0, roll: Double = 0, speed: Double = 0.8) {
        let pose = MotionReading(yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll,
                                 angularSpeed: speed, orientationMatchesConfiguration: true,
                                 sampleTimestamp: CACurrentMediaTime())
        latest = pose
        onReading?(pose)
    }
}
