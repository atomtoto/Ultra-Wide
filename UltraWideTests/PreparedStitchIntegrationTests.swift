import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import UltraWide

/// The bundled OpenCV library has no simulator slice. These tests compile for
/// both platforms; running the export checks requires a supported device.
@MainActor
final class PreparedStitchIntegrationTests: XCTestCase {
    func testPreparedLuminanceGainIsAppliedInLinearDisplayP3() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Native OpenCV export is unavailable in the simulator.")
#else
        let sourceColor = [0.08, 0.20, 0.12]
        let fixture = try makeColorFixture(linearColor: sourceColor)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alignment = StitchAlignment(
            normalizedHomography: [1.1, 0, -0.05, 0, 1.1, -0.05, 0, 0, 1],
            sourcePixelWidth: 960, sourcePixelHeight: 1280, luminanceGain: 2
        )
        // Both sources carry the same known correction. This prevents seam
        // selection or inter-frame compensation from hiding an ignored gain.
        let result = try await StitchingEngine().stitch(
            inputs: [StitchInput(url: fixture.image, alignment: alignment),
                     StitchInput(url: fixture.image, alignment: alignment)],
            outputURL: fixture.directory.appendingPathComponent("linear-gain.heic"),
            maximumMegapixels: 2, targetAspectRatio: 0.75,
            minimumHorizontalFOVDegrees: 40, minimumVerticalFOVDegrees: 50,
            preparedFocalRatio: 1
        )
        XCTAssertTrue(result.reusedPreparedAlignment)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.imageURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let actual = try displayP3Center(image)
        for channel in 0..<3 {
            let expected = encodeDisplayP3(sourceColor[channel] * 2)
            XCTAssertEqual(actual[channel], expected, accuracy: 0.035,
                           "Prepared export must multiply linear light; multiplying gamma-encoded bytes changes brightness and color.")
        }
#endif
    }

    func testPreparedFlatPhotosExportWithoutFeatureRegistration() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Native OpenCV export is unavailable in the simulator.")
#else
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alignment = StitchAlignment(
            normalizedHomography: [1.1, 0, -0.05, 0, 1.1, -0.05, 0, 0, 1],
            sourcePixelWidth: 960, sourcePixelHeight: 1280
        )
        // These flat photos contain no features. The legacy SIFT path cannot
        // align them, so a successful output also proves registration was skipped.
        let result = try await StitchingEngine().stitch(
            inputs: [StitchInput(url: fixture.image, alignment: alignment),
                     StitchInput(url: fixture.image, alignment: alignment)],
            outputURL: fixture.directory.appendingPathComponent("result.heic"),
            maximumMegapixels: 2, targetAspectRatio: 0.75,
            minimumHorizontalFOVDegrees: 40, minimumVerticalFOVDegrees: 50,
            preparedFocalRatio: 1
        )
        XCTAssertTrue(result.reusedPreparedAlignment)
        XCTAssertEqual(result.usedFrameIndices, [0, 1])
        XCTAssertEqual(result.rejectedFrameIndices, [])
        XCTAssertEqual(Double(result.pixelWidth) / Double(result.pixelHeight), 0.75, accuracy: 0.001)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.imageURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, result.pixelWidth)
        XCTAssertEqual(image.height, result.pixelHeight)
#endif
    }

    func testPreparedMatricesRejectHorizonSingularityAndNonfiniteValues() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Native OpenCV export is unavailable in the simulator.")
#else
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let invalidMatrices: [[Double]] = [
            [1, 0, 0, 0, 0, 0, 0, 0, 1], // Singular.
            [1, 0, 0, 0, 1, 0, -2, 0, 1], // Horizon crosses the source rectangle.
            [Double.infinity, 0, 0, 0, 1, 0, 0, 0, 1],
            [1, 0, 0],
            [1, 0, 30, 0, 1, 0, 0, 0, 1] // Outside the bounded rectilinear canvas.
        ]
        for matrix in invalidMatrices {
            let alignment = StitchAlignment(normalizedHomography: matrix,
                                            sourcePixelWidth: 960, sourcePixelHeight: 1280)
            do {
                _ = try await StitchingEngine().stitch(
                    inputs: [StitchInput(url: fixture.image, alignment: alignment),
                             StitchInput(url: fixture.image, alignment: alignment)],
                    outputURL: fixture.directory.appendingPathComponent("invalid.heic"),
                    targetAspectRatio: 0.75, preparedFocalRatio: 1
                )
                XCTFail("Invalid prepared alignment was accepted: \(matrix)")
            } catch StitchingFailure.invalidGeometry {
                // Expected: do not fall back to feature matching for malformed matrices.
            }
        }
#endif
    }

    func testPreparedSourceDimensionsMustMatchDecodedImage() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Native OpenCV export is unavailable in the simulator.")
#else
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alignment = StitchAlignment(normalizedHomography: [1.1, 0, -0.05, 0, 1.1, -0.05, 0, 0, 1],
                                        sourcePixelWidth: 1280, sourcePixelHeight: 960)
        do {
            _ = try await StitchingEngine().stitch(
                inputs: [StitchInput(url: fixture.image, alignment: alignment),
                         StitchInput(url: fixture.image, alignment: alignment)],
                outputURL: fixture.directory.appendingPathComponent("wrong-size.heic"),
                targetAspectRatio: 0.75, preparedFocalRatio: 1
            )
            XCTFail("Prepared dimensions from a different source were accepted.")
        } catch StitchingFailure.invalidGeometry {
            // Expected.
        }
#endif
    }

    func testPreparedCoverageCannotExportAnIncompleteTarget() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Native OpenCV export is unavailable in the simulator.")
#else
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let alignment = StitchAlignment(normalizedHomography: [0.6, 0, 0.2, 0, 0.6, 0.2, 0, 0, 1],
                                        sourcePixelWidth: 960, sourcePixelHeight: 1280)
        do {
            _ = try await StitchingEngine().stitch(
                inputs: [StitchInput(url: fixture.image, alignment: alignment),
                         StitchInput(url: fixture.image, alignment: alignment)],
                outputURL: fixture.directory.appendingPathComponent("incomplete.heic"),
                targetAspectRatio: 0.75, preparedFocalRatio: 1
            )
            XCTFail("An incomplete target was exported.")
        } catch StitchingFailure.incompleteCoverage {
            // Expected: calibrated transforms cannot bypass final coverage checks.
        }
#endif
    }

#if !targetEnvironment(simulator)
    private func encodeDisplayP3(_ linear: Double) -> Double {
        linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    private func makeColorFixture(linearColor: [Double]) throws -> (directory: URL, image: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let width = 960, height = 1280
        let encoded = linearColor.map { UInt8((encodeDisplayP3($0) * 255).rounded()) }
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0..<3 { bytes[offset + channel] = encoded[channel] }
        }
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = directory.appendingPathComponent("known-linear-color.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return (directory, url)
    }

    private func displayP3Center(_ image: CGImage) throws -> [Double] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let center = CGRect(x: CGFloat(image.width / 2), y: CGFloat(image.height / 2), width: 1, height: 1)
        let sample = try XCTUnwrap(image.cropping(to: center))
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel.prefix(3).map { Double($0) / 255 }
    }

    private func makeFixture() throws -> (directory: URL, image: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 960, height: 1280), format: format)
        let data = renderer.jpegData(withCompressionQuality: 0.95) { context in
            UIColor(white: 0.5, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 960, height: 1280))
        }
        let image = directory.appendingPathComponent("flat.jpg")
        try data.write(to: image)
        return (directory, image)
    }
#endif
}
