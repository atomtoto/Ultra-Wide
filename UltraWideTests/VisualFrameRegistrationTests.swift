import CoreGraphics
import ImageIO
import XCTest
@testable import UltraWide

final class VisualFrameRegistrationTests: XCTestCase {
    func testHomographyCompositionAndInverseUseForwardTopLeftCoordinates() throws {
        let translate = Homography3x3([1, 0, 0.2, 0, 1, -0.1, 0, 0, 1])
        let scale = Homography3x3([2, 0, 0, 0, 0.5, 0, 0, 0, 1])
        let composite = translate.concatenating(scale)
        let point = try XCTUnwrap(composite.transform(CGPoint(x: 0.3, y: 0.4)))
        XCTAssertEqual(point.x, 1, accuracy: 1e-12)
        XCTAssertEqual(point.y, 0.15, accuracy: 1e-12)
        let inverse = try XCTUnwrap(composite.inverted())
        let restored = try XCTUnwrap(inverse.transform(point))
        XCTAssertEqual(restored.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(restored.y, 0.4, accuracy: 1e-12)
        XCTAssertNil(Homography3x3([1, 0, 0, 0, 0, 0, 0, 0, 1]).inverted())
    }

    func testVisionMapsKnownTranslationFromSourceToReference() async throws {
        let image = try fixture()
        let rectangle = CGRect(x: 0, y: 0, width: image.width - 60, height: image.height - 60)
        let reference = try XCTUnwrap(image.cropping(to: rectangle))
        let source = try XCTUnwrap(image.cropping(to: rectangle.offsetBy(dx: 20, dy: 15)))
        let result = try await VisionFrameRegistration().register(
            source: RegistrationImage(source), reference: RegistrationImage(reference))
        for point in [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.8)] {
            let transformed = try XCTUnwrap(result.homography.transform(point))
            XCTAssertEqual(transformed.x, point.x + 20 / rectangle.width, accuracy: 0.006)
            XCTAssertEqual(transformed.y, point.y + 15 / rectangle.height, accuracy: 0.006)
        }
        XCTAssertGreaterThan(result.overlapFraction, 0.8)
        XCTAssertGreaterThan(result.visualAgreement, 0.8)
    }

    func testVisionRecoversKnownPerspectiveAndTilt() async throws {
        let image = try thumbnail(try fixture(), maximumSide: 600)
        let expected = Homography3x3([1.01, -0.035, 0.045, 0.025, 0.985, -0.005, 0.035, -0.025, 1])
        let source = try warped(image, using: expected)
        let estimate = expected.concatenating(Homography3x3([1, 0, 2.0 / Double(image.width),
                                                            0, 1, -2.0 / Double(image.height), 0, 0, 1]))
        let result = try await VisionFrameRegistration().register(
            source: RegistrationImage(source), reference: RegistrationImage(image), initialEstimate: estimate)
        for point in [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.8)] {
            let transformed = try XCTUnwrap(result.homography.transform(point))
            let wanted = try XCTUnwrap(expected.transform(point))
            XCTAssertEqual(transformed.x, wanted.x, accuracy: 0.012)
            XCTAssertEqual(transformed.y, wanted.y, accuracy: 0.012)
        }
        XCTAssertGreaterThan(result.visualAgreement, 0.75)
    }

    func testVisionRefinesRealCameraRotationsAndTwelveDegreeTiltWithImperfectPrior() async throws {
        let scene = try thumbnail(try fixture(), maximumSide: 600)
        for degrees in [3.0, 8.0] {
            for roll in [0.0, 12.0] {
                let expected = cameraTransform(yaw: degrees, pitch: degrees, roll: roll,
                                               aspectRatio: Double(scene.width) / Double(scene.height))
                let source = try warped(scene, using: expected)
                let imperfect = expected.concatenating(Homography3x3([
                    1, 0, 2.0 / Double(scene.width), 0, 1, -2.0 / Double(scene.height), 0, 0, 1
                ]))
                let result = try await VisionFrameRegistration().register(
                    source: RegistrationImage(source), reference: RegistrationImage(scene), initialEstimate: imperfect)
                for point in [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.8, y: 0.8)] {
                    let actual = try XCTUnwrap(result.homography.transform(point))
                    let wanted = try XCTUnwrap(expected.transform(point))
                    XCTAssertEqual(actual.x, wanted.x, accuracy: 0.006, "yaw/pitch \(degrees), roll \(roll)")
                    XCTAssertEqual(actual.y, wanted.y, accuracy: 0.006, "yaw/pitch \(degrees), roll \(roll)")
                }
                XCTAssertGreaterThan(result.overlapFraction, 0.65)
                XCTAssertGreaterThan(result.visualAgreement, 0.8)
            }
        }
    }

    func testVisionRejectsBlankAndNonoverlappingImages() async throws {
        let blank = try image(width: 480, height: 640, pixels: [UInt8](repeating: 128, count: 480 * 640))
        do {
            _ = try await VisionFrameRegistration().register(source: RegistrationImage(blank), reference: RegistrationImage(blank))
            XCTFail("A blank image must not certify new coverage.")
        } catch VisualRegistrationFailure.insufficientDetail { }

        let scene = try fixture()
        let reference = try XCTUnwrap(scene.cropping(to: CGRect(x: 0, y: 0, width: 420, height: 420)))
        let source = try XCTUnwrap(scene.cropping(to: CGRect(x: 500, y: 700, width: 420, height: 420)))
        do {
            _ = try await VisionFrameRegistration().register(source: RegistrationImage(source), reference: RegistrationImage(reference),
                                                              initialEstimate: .identity)
            XCTFail("Images with no shared scene must not certify new coverage.")
        } catch is VisualRegistrationFailure { }
    }

    func testPlausibleWrongTransformIsRejectedByImageContent() throws {
        let scene = try thumbnail(try fixture(), maximumSide: 600)
        let incorrect = Homography3x3([1, 0, 0.12, 0, 1, 0.08, 0, 0, 1])
        XCTAssertThrowsError(try VisionFrameRegistration.verify(homography: incorrect,
            source: RegistrationImage(scene), reference: RegistrationImage(scene))) { error in
            guard case VisualRegistrationFailure.inconsistentContent = error else {
                return XCTFail("Expected image disagreement, received \(error)")
            }
        }
    }

    func testSmallContourOffsetCannotPassOnHighOverallCorrelation() throws {
        let scene = RegistrationImage(try smoothScene())
        for offset in [(3.0, 0.0), (0.0, -3.0), (2.5, 2.5)] {
            let incorrect = Homography3x3([1, 0, offset.0 / 480,
                                          0, 1, offset.1 / 640, 0, 0, 1])
            XCTAssertThrowsError(try VisionFrameRegistration.verify(homography: incorrect,
                source: scene, reference: scene)) { error in
                guard case VisualRegistrationFailure.inconsistentContent = error else {
                    return XCTFail("Expected a contour displacement rejection, received \(error)")
                }
            }
        }
    }

    func testAccurateSmoothSceneAndSubpixelOffsetRemainUsable() throws {
        let scene = RegistrationImage(try smoothScene())
        for offset in [0.0, 0.5, -0.5] {
            let transform = Homography3x3([1, 0, offset / 480, 0, 1, -offset / 640, 0, 0, 1])
            let result = try VisionFrameRegistration.verify(homography: transform, source: scene, reference: scene)
            XCTAssertGreaterThan(result.visualAgreement, 0.9)
        }
    }

    private func smoothScene() throws -> CGImage {
        let width = 480, height = 640
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8((128 + 45 * sin(Double(x) * 0.2)
                    + 45 * cos(Double(y) * 0.2)).rounded())
            }
        }
        return try image(width: width, height: height, pixels: pixels)
    }

    func testStrongParallaxCannotValidateCoverageFromOneMatchingHalf() async throws {
        let scene = try thumbnail(try fixture(), maximumSide: 600)
        let original = try grayPixels(scene)
        var distorted = original
        for y in 0..<scene.height {
            for x in scene.width / 2..<scene.width {
                distorted[y * scene.width + x] = original[y * scene.width + min(scene.width - 1, x + 35)]
            }
        }
        let source = try image(width: scene.width, height: scene.height, pixels: distorted)
        XCTAssertThrowsError(try VisionFrameRegistration.verify(homography: .identity,
            source: RegistrationImage(source), reference: RegistrationImage(scene))) { error in
            guard case VisualRegistrationFailure.inconsistentContent = error else {
                return XCTFail("Expected local parallax rejection, received \(error)")
            }
        }
        do {
            _ = try await VisionFrameRegistration().register(source: RegistrationImage(source), reference: RegistrationImage(scene),
                                                              initialEstimate: .identity)
            XCTFail("A prior and one matching half must not bypass visual disagreement.")
        } catch is VisualRegistrationFailure { }
    }

    func testSingularMirroredAndHorizonGeometryIsRejectedBeforeContent() throws {
        let scene = RegistrationImage(try fixture())
        let invalid = [
            Homography3x3([1, 0, 0, 0, 0, 0, 0, 0, 1]),
            Homography3x3([-1, 0, 1, 0, 1, 0, 0, 0, 1]),
            Homography3x3([1, 0, 0, 0, 1, 0, -2, 0, 1]),
            Homography3x3([12, 0, 0, 0, 12, 0, 0, 0, 1])
        ]
        for homography in invalid {
            XCTAssertThrowsError(try VisionFrameRegistration.verify(homography: homography, source: scene, reference: scene)) { error in
                guard case VisualRegistrationFailure.invalidGeometry = error else {
                    return XCTFail("Expected invalid geometry, received \(error)")
                }
            }
        }
    }

    private func fixture() throws -> CGImage {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "frame00", withExtension: "jpg", subdirectory: "Fixtures/PortraitSweep")
            ?? bundle.url(forResource: "frame00", withExtension: "jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// Perspective from a pinhole camera, using the same axis convention as the
    /// motion projection: image y points down, positive pitch turns upward.
    private func cameraTransform(yaw: Double, pitch: Double, roll: Double, aspectRatio: Double) -> Homography3x3 {
        let fy = 1 / (2 * tan(35 * Double.pi / 180)), fx = fy / aspectRatio
        let intrinsics = Homography3x3([fx, 0, 0.5, 0, fy, 0.5, 0, 0, 1])
        let y = yaw * Double.pi / 180, p = pitch * Double.pi / 180, r = roll * Double.pi / 180
        let rz = Homography3x3([cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1])
        let rx = Homography3x3([1, 0, 0, 0, cos(p), -sin(p), 0, sin(p), cos(p)])
        let ry = Homography3x3([cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)])
        return intrinsics.inverted()!.concatenating(rz).concatenating(rx).concatenating(ry).concatenating(intrinsics)
    }

    private func thumbnail(_ source: CGImage, maximumSide: Int) throws -> CGImage {
        let factor = Double(maximumSide) / Double(max(source.width, source.height))
        let width = Int(Double(source.width) * factor), height = Int(Double(source.height) * factor)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func grayPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func warped(_ reference: CGImage, using transform: Homography3x3) throws -> CGImage {
        let width = reference.width, height = reference.height
        let pixels = try grayPixels(reference)
        var result = [UInt8](repeating: 128, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let point = CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
                guard let mapped = transform.transform(point) else { continue }
                let px = Double(mapped.x) * Double(width) - 0.5
                let py = Double(mapped.y) * Double(height) - 0.5
                guard px >= 0, py >= 0, px < Double(width - 1), py < Double(height - 1) else { continue }
                let ix = Int(px), iy = Int(py), fx = px - Double(Int(px)), fy = py - Double(Int(py))
                let a = Double(pixels[iy * width + ix]), b = Double(pixels[iy * width + ix + 1])
                let c = Double(pixels[(iy + 1) * width + ix]), d = Double(pixels[(iy + 1) * width + ix + 1])
                result[y * width + x] = UInt8(((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy).rounded())
            }
        }
        return try image(width: width, height: height, pixels: result)
    }

    private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
    }
}
