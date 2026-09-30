import AVFoundation
import ImageIO
import QuartzCore
import XCTest
@testable import UltraWide

@MainActor
final class CameraPipelineIntegrationTests: XCTestCase {
    func testPortraitVideoSamplesMatchMeasuredFieldShapeOnIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A physical rear camera is required.")
#else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Grant Camera access in Ultra Wide to run the live camera test.")
        }
        let camera = CameraService()
        try await camera.configure(lens: .wide, orientation: .portrait)
        defer { camera.pause() }

        let landscapeAspect = try await camera.videoLandscapeAspectRatio()
        XCTAssertGreaterThan(landscapeAspect, 1.0)
        XCTAssertLessThan(landscapeAspect, 2.4)

        var sample: Data?
        for _ in 0..<20 {
            if let data = try? await camera.captureVideoFrame(near: CACurrentMediaTime()) {
                sample = data
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let data = try XCTUnwrap(sample)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertGreaterThan(image.height, image.width)
        XCTAssertEqual(Double(image.height) / Double(image.width), landscapeAspect,
                       accuracy: 0.02)
        await camera.pauseAndWait()
#endif
    }

    func testNativeNarrowPhotoHasCorrectOrientationAndFileTypeOnIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A physical rear camera is required.")
#else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Grant Camera access in Ultra Wide to run the live camera test.")
        }
        let camera = CameraService()
        try await camera.configure(lens: .wide, orientation: .portrait, zoomFactor: 1.5)
        defer { camera.pause() }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try await camera.captureSinglePhoto(to: base, cropFactor: 1.5)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertTrue(["heic", "jpg"].contains(result.url.pathExtension))
        XCTAssertGreaterThan(result.pixelWidth * result.pixelHeight, 2_000_000)
        XCTAssertGreaterThan(result.pixelHeight, result.pixelWidth)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        await camera.pauseAndWait()
#endif
    }

    func testSweepExposureAndVideoSampleProcessingOnIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("A physical rear camera is required.")
#else
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw XCTSkip("Grant Camera access in Ultra Wide to run the live camera test.")
        }
        let camera = CameraService()
        try await camera.configure(lens: .wide, orientation: .portrait)
        defer { camera.pause() }
        _ = try await camera.videoLandscapeAspectRatio()
        try await camera.prepareForSweep()
        let device = try XCTUnwrap(CameraService.device(for: .wide))
        let limit = max(1.0 / 120.0, device.activeFormat.minExposureDuration.seconds)
        XCTAssertLessThanOrEqual(device.activeMaxExposureDuration.seconds, limit + 0.000001)

        var timings: [Double] = []
        for _ in 0..<5 {
            let started = CACurrentMediaTime()
            let sample = try await camera.captureVideoSample(near: started, allowLowQuality: true)
            timings.append(CACurrentMediaTime() - started)
            let data = try XCTUnwrap(sample.data)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 1)
            XCTAssertTrue(sample.quality.sharpness.isFinite)
        }
        let attachment = XCTAttachment(string: timings.map {
            String(format: "%.3f s", $0)
        }.joined(separator: "\n"))
        attachment.name = "Video sample analysis and encoding latency"
        attachment.lifetime = .keepAlways
        add(attachment)
        await camera.pauseAndWait()
#endif
    }
}
