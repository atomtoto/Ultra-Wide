import ImageIO
import UIKit
import XCTest
@testable import UltraWide

final class NativeStitchIntegrationTests: XCTestCase {
    func testTiltedVideoSweepStillExportsRequestedFieldOnIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("The bundled OpenCV framework is built for a physical iPhone.")
#else
        let plan = try XCTUnwrap(CapturePlan.make(
            lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 70, lensHorizontalFOV: 70,
            sourceLandscapeAspectRatio: 16.0 / 9.0
        ))
        let positions: [(Double, Double)] = [
            (0, 0), (-32, -32), (0, -32), (32, -32), (-32, 0),
            (32, 0), (-32, 32), (0, 32), (32, 32)
        ]
        let bundle = Bundle(for: Self.self)
        let inputs = try positions.enumerated().map { index, position -> StitchInput in
            let name = String(format: "tilt%02d", index)
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg",
                subdirectory: "Fixtures/TiltedSweep") ?? bundle.url(forResource: name, withExtension: "jpg"))
            return StitchInput(url: url, yawRadians: position.0 * .pi / 180,
                pitchRadians: position.1 * .pi / 180, rollRadians: index == 0 ? 0 : 15 * .pi / 180)
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try await StitchingEngine().stitch(
            inputs: inputs, outputURL: output, maximumMegapixels: 4, targetAspectRatio: 3.0 / 4.0,
            minimumHorizontalFOVDegrees: plan.targetHorizontalFOV,
            minimumVerticalFOVDegrees: plan.targetVerticalFOV
        )
        XCTAssertGreaterThanOrEqual(result.usedFrameIndices.count, 8)
        XCTAssertGreaterThan(result.pixelWidth * result.pixelHeight, 100_000)
        XCTAssertEqual(Double(result.pixelWidth) / Double(result.pixelHeight), 3.0 / 4.0, accuracy: 0.01)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.imageURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
#endif
    }

    func testCompletePortraitSweepExportsHEIFOnIPhone() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("The bundled OpenCV framework is built for a physical iPhone.")
#else
        let plan = try XCTUnwrap(CapturePlan.make(
            lens: .wide,
            target: .half,
            orientation: .portrait,
            wideHorizontalFOV: 70,
            lensHorizontalFOV: 70,
            sourceLandscapeAspectRatio: 4.0 / 3.0
        ))
        let positions: [(Double, Double)] = [
            (0, 0), (-1, -1), (0, -1), (1, -1), (-1, 0),
            (1, 0), (-1, 1), (0, 1), (1, 1)
        ]
        let bundle = Bundle(for: Self.self)
        let inputs = try positions.enumerated().map { index, position -> StitchInput in
            let name = String(format: "frame%02d", index)
            let url = try XCTUnwrap(
                bundle.url(forResource: name, withExtension: "jpg", subdirectory: "Fixtures/PortraitSweep")
                    ?? bundle.url(forResource: name, withExtension: "jpg")
            )
            return StitchInput(
                url: url,
                yawRadians: position.0 * (plan.targetHorizontalFOV - plan.sourceHorizontalFOV) * .pi / 360,
                pitchRadians: position.1 * (plan.targetVerticalFOV - plan.sourceVerticalFOV) * .pi / 360,
                rollRadians: 0
            )
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("heic")
        defer {
            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
        }

        let result: StitchResult
        let timeline = StitchTimeline()
        do {
            result = try await StitchingEngine().stitch(
                inputs: inputs,
                outputURL: output,
                maximumMegapixels: 4,
                targetAspectRatio: 3.0 / 4.0,
                minimumHorizontalFOVDegrees: plan.targetHorizontalFOV,
                minimumVerticalFOVDegrees: plan.targetVerticalFOV,
                progress: { fraction in timeline.record(fraction) }
            )
        } catch {
            XCTFail("Native stitch failed: \(String(reflecting: error)); \(error.localizedDescription)")
            return
        }

        XCTAssertEqual(result.imageURL, output)
        XCTAssertGreaterThan(result.pixelWidth, 256)
        XCTAssertGreaterThan(result.pixelHeight, 256)
        XCTAssertEqual(result.usedFrameIndices.count, inputs.count)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, result.pixelWidth)
        XCTAssertEqual(image.height, result.pixelHeight)
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "Assembled portrait sweep"
        attachment.lifetime = .keepAlways
        add(attachment)
        let timing = XCTAttachment(string: timeline.report())
        timing.name = "Assembly stage timings"
        timing.lifetime = .keepAlways
        add(timing)
#endif
    }
}

private final class StitchTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private let started = ProcessInfo.processInfo.systemUptime
    private var milestones: [(Double, Double)] = []

    func record(_ fraction: Double) {
        lock.lock()
        milestones.append((fraction, ProcessInfo.processInfo.systemUptime - started))
        lock.unlock()
    }

    func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        return [0.15, 0.35, 0.43, 0.46, 0.49, 0.50, 0.90, 0.94, 1.0].map { threshold in
            let elapsed = milestones.first(where: { $0.0 >= threshold })?.1 ?? -1
            return String(format: "%.2f: %.3f s", threshold, elapsed)
        }.joined(separator: "\n")
    }
}
