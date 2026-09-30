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

    func testSmoothSceneIsEncodedImmediatelyWithoutSharpnessWait() async throws {
        let camera = CameraService()
        let buffer = try pixels(gradient: true)
        let initial = try await camera.encodeVideoSample(buffer)
        XCTAssertEqual(initial.quality.quality, .soft)
        let data = try XCTUnwrap(initial.data)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 640)
        XCTAssertEqual(image.height, 480)
    }

    func testBlackVideoSampleIsRejectedBeforeEncoding() async throws {
        let sample = try await CameraService().encodeVideoSample(pixels(gradient: false))
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

    func testNativeLumaAnalysisNeedsNoRenderAndNormalizesVideoRange() throws {
        for videoRange in [false, true] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1440,
                videoRange ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let image = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(image, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, 0))
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            for y in 0..<1440 {
                for x in 0..<1920 {
                    let value = (x / 120 + y / 120).isMultiple(of: 2) ? 48 : 224
                    base[y * stride + x] = UInt8(videoRange ? 16 + value * 219 / 255 : value)
                }
            }
            CVPixelBufferUnlockBaseAddress(image, [])
            let quality = PhotoQualityAnalyzer.analyze(image)
            XCTAssertEqual(quality.quality, .good)
            XCTAssertEqual(quality.brightness, 136.0 / 255.0, accuracy: 0.01)
        }
    }
}
