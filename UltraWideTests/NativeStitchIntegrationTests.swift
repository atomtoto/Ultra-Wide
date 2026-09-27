import ImageIO
import UIKit
import XCTest
@testable import UltraWide

final class NativeStitchIntegrationTests: XCTestCase {
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
        do {
            result = try await StitchingEngine().stitch(
                inputs: inputs,
                outputURL: output,
                maximumMegapixels: 4,
                targetAspectRatio: 3.0 / 4.0,
                minimumHorizontalFOVDegrees: plan.targetHorizontalFOV,
                minimumVerticalFOVDegrees: plan.targetVerticalFOV
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
#endif
    }
}
