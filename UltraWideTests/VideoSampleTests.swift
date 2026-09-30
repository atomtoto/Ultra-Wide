import CoreVideo
import ImageIO
import XCTest
@testable import UltraWide

final class VideoSampleTests: XCTestCase {
    private func pixels(gradient: Bool, checkerboard: Bool = false) throws -> CVPixelBuffer {
        let width = 640, height = 480
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                        kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let result = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result))
            .assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0..<height {
            for x in 0..<width {
                let gray: UInt8
                if checkerboard {
                    gray = ((x / 12 + y / 12) % 2 == 0) ? 48 : 224
                } else {
                    gray = gradient ? UInt8(48 + 176 * x / (width - 1)) : 0
                }
                let index = y * stride + x * 4
                base[index] = gray
                base[index + 1] = gray
                base[index + 2] = gray
                base[index + 3] = 255
            }
        }
        return result
    }

    func testSmoothSceneCanBeEncodedAfterBoundedQualityWait() async throws {
        let camera = CameraService()
        let buffer = try pixels(gradient: true)
        let initial = try await camera.encodeVideoSample(buffer)
        XCTAssertEqual(initial.quality.quality, .soft)
        XCTAssertNil(initial.data)

        let accepted = try await camera.encodeVideoSample(buffer, allowSoftFrame: true)
        let data = try XCTUnwrap(accepted.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 480)
    }

    func testBlackVideoSampleIsRejectedBeforeEncoding() async throws {
        let sample = try await CameraService().encodeVideoSample(pixels(gradient: false),
                                                                allowSoftFrame: true)
        XCTAssertEqual(sample.quality.quality, .dark)
        XCTAssertNil(sample.data)
    }

    func testSharpVideoSampleIsEncodedImmediately() async throws {
        let sample = try await CameraService().encodeVideoSample(
            pixels(gradient: false, checkerboard: true)
        )
        XCTAssertEqual(sample.quality.quality, .good)
        XCTAssertNotNil(sample.data)
    }
}
