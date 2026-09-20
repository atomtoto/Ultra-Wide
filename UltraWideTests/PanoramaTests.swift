import XCTest
import CoreGraphics
import simd
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import UltraWide

final class PanoramaTests: XCTestCase {
    func testSweepSupportsBothDirectionsWithoutDuplicateFrames() {
        for direction in [-1.0, 1.0] {
            var sweep = SweepTracker(target: 40, step: 10)
            sweep.update(angle: 11 * direction)
            XCTAssertTrue(sweep.shouldCapture(angle: 11 * direction))
            sweep.didCapture(angle: 11 * direction)
            XCTAssertFalse(sweep.shouldCapture(angle: 11 * direction))
            sweep.update(angle: 7 * direction)
            XCTAssertTrue(sweep.isReversing(angle: 7 * direction))
            XCTAssertFalse(sweep.shouldCapture(angle: 7 * direction))
            sweep.update(angle: 50 * direction)
            XCTAssertEqual(sweep.progress, 1)
        }
    }

    func testProjectiveCoordinatesAndInvalidHorizon() throws {
        let matrix = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(20, -5, 1)))
        let point = try PanoramaGeometry.project(CGPoint(x: 100, y: 50), by: matrix)
        XCTAssertEqual(point.x, 120, accuracy: 0.001)
        XCTAssertEqual(point.y, 45, accuracy: 0.001)
        XCTAssertThrowsError(try PanoramaGeometry.project(.zero, by: simd_float3x3(diagonal: SIMD3(1, 1, -1))))
    }

    func testCropNeverIncludesUncoveredCorners() throws {
        let polygons = [[CGPoint(x: 0, y: 20), CGPoint(x: 110, y: 0), CGPoint(x: 110, y: 120), CGPoint(x: 0, y: 100)],
                        [CGPoint(x: 70, y: 0), CGPoint(x: 200, y: 20), CGPoint(x: 200, y: 100), CGPoint(x: 70, y: 120)]]
        let crop = try PanoramaGeometry.coveredCrop(polygons: polygons, bounds: CGRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertGreaterThan(crop.width, 170)
        XCTAssertGreaterThan(crop.height, 65)
        for x in stride(from: crop.minX, through: crop.maxX, by: 1) {
            for y in stride(from: crop.minY, through: crop.maxY, by: 1) {
                XCTAssertTrue(polygons.contains { PanoramaGeometry.contains(CGPoint(x: x, y: y), polygon: $0) })
            }
        }
    }

    @MainActor func testRealVisionAssemblyOnOverlappingImagesAndReverseSweep() throws {
        let frames = try DemoScene.frames()
        for sequence in [frames, Array(frames.reversed())] {
            let result = try PanoramaStitcher.stitch(sequence) { _ in }
            XCTAssertEqual(result.frameCount, 5)
            XCTAssertGreaterThan(result.width, 1600)
            XCTAssertGreaterThan(result.height, 1100)
            XCTAssertLessThanOrEqual(result.width * result.height, 18_000_000)
            let image = try PanoramaStitcher.decode(result.jpeg, maxPixel: 2400)
            XCTAssertEqual(image.width, result.width)
            // Independent pixel check against the original scene: verifies that
            // compositing preserved its content, not only the output dimensions.
            let source = try XCTUnwrap(DemoScene.image.cgImage)
            let rendered = rgba(image), original = rgba(source)
            let originX = (2120 - image.width) / 2
            let originY = 100 + (1333 - image.height) / 2
            var error = 0.0, samples = 0
            for y in stride(from: 30, to: image.height - 30, by: 17) {
                for x in stride(from: 30, to: image.width - 30, by: 17) {
                    for channel in 0..<3 {
                        error += abs(Double(rendered[(y * image.width + x) * 4 + channel]) - Double(original[((y + originY) * source.width + x + originX) * 4 + channel]))
                        samples += 1
                    }
                }
            }
            XCTAssertLessThan(error / Double(samples), 6, "Panorama pixels should match the source scene across all seams")
        }
    }

    @MainActor func testPerspectiveRefinementOnProjectivelyWarpedViews() throws {
        let source = try XCTUnwrap(DemoScene.image.cgImage)
        let context = CIContext()
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let frames = try (0..<5).map { index -> CapturedFrame in
            // A pinhole camera rotating about its optical center: five real
            // projective views at -20°, -10°, 0°, 10°, 20° (no mere translations).
            let angle = Float(index - 2) * 10 * .pi / 180
            let sceneIntrinsics = simd_float3x3(columns: (SIMD3(1200, 0, 0), SIMD3(0, 1200, 0), SIMD3(1200, 800, 1)))
            let cameraIntrinsics = simd_float3x3(columns: (SIMD3(1200, 0, 0), SIMD3(0, 1200, 0), SIMD3(500, 666.5, 1)))
            let rotation = simd_float3x3(columns: (SIMD3(cos(angle), 0, -sin(angle)), SIMD3(0, 1, 0), SIMD3(sin(angle), 0, cos(angle))))
            let corners = try PanoramaGeometry.corners(of: rect, by: cameraIntrinsics * rotation * simd_inverse(sceneIntrinsics))
            let filter = CIFilter.perspectiveTransform()
            filter.inputImage = CIImage(cgImage: source)
            filter.bottomLeft = corners[0]; filter.bottomRight = corners[1]
            filter.topRight = corners[2]; filter.topLeft = corners[3]
            let output = try XCTUnwrap(filter.outputImage)
            let cg = try XCTUnwrap(context.createCGImage(output, from: CGRect(x: 0, y: 0, width: 1000, height: 1333)))
            return CapturedFrame(data: try XCTUnwrap(UIImage(cgImage: cg).jpegData(compressionQuality: 0.98)), angle: Double(index) * 10)
        }
        let result = try PanoramaStitcher.stitch(frames) { _ in }
        XCTAssertGreaterThan(result.width, 1500)
        XCTAssertGreaterThan(result.height, 1100)
        let attachment = XCTAttachment(data: result.jpeg, uniformTypeIdentifier: "public.jpeg")
        attachment.name = "Perspective-assembly"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    @MainActor func testDuplicateFramesAreRejected() throws {
        let frame = try XCTUnwrap(DemoScene.frames().first)
        XCTAssertThrowsError(try PanoramaStitcher.stitch([frame, frame, frame]) { _ in })
        XCTAssertThrowsError(try PanoramaStitcher.stitch([frame]) { _ in })
    }

    @MainActor func testLibraryRoundTripAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = PanoramaLibrary(directory: directory)
        let data = try XCTUnwrap(DemoScene.image.jpegData(compressionQuality: 0.8))
        let result = CaptureResult(image: StitchResult(jpeg: data, width: 2400, height: 1600, frameCount: 5), lensName: "Principal", isDemo: true)
        let saved = try await library.store(result)
        let duplicate = try await library.store(result)
        XCTAssertEqual(saved.id, duplicate.id)
        await library.reload()
        XCTAssertEqual(library.items.count, 1)
        XCTAssertEqual(try Data(contentsOf: library.url(for: saved)), data)
        try library.delete(saved)
        XCTAssertTrue(library.items.isEmpty)
        await library.reload()
        XCTAssertTrue(library.items.isEmpty)
    }
}
