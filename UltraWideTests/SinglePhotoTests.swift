import ImageIO
import UIKit
import XCTest
@testable import UltraWide

final class SinglePhotoTests: XCTestCase {
    private func sourceJPEG(size: CGSize = CGSize(width: 1200, height: 900)) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 3, height: size.height))
            UIColor.green.setFill()
            context.fill(CGRect(x: size.width / 3, y: 0, width: size.width / 3, height: size.height))
            UIColor.blue.setFill()
            context.fill(CGRect(x: size.width * 2 / 3, y: 0, width: size.width / 3, height: size.height))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    }

    func testFullFieldWritesEncodedPhotoWithoutReencoding() throws {
        let data = try sourceJPEG()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(data, fileExtension: "jpg",
                                                        to: base, cropFactor: 1)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.pixelWidth, 1200)
        XCTAssertEqual(result.pixelHeight, 900)
        XCTAssertEqual(try Data(contentsOf: result.url), data)
    }

    func testNarrowFieldUsesCenteredCrop() throws {
        let data = try sourceJPEG()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(data, fileExtension: "jpg",
                                                        to: base, cropFactor: 2)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.pixelWidth, 600)
        XCTAssertEqual(result.pixelHeight, 450)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 600)
        XCTAssertEqual(image.height, 450)
    }

    func testResolutionLimitResizesEncodedPhotoWithoutChangingAspect() throws {
        let data = try sourceJPEG(size: CGSize(width: 2400, height: 1800))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(data, fileExtension: "jpg",
            to: base, cropFactor: 1, maximumMegapixels: 4)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertLessThanOrEqual(result.pixelWidth * result.pixelHeight, 4_000_000)
        XCTAssertGreaterThan(result.pixelWidth * result.pixelHeight, 3_990_000)
        XCTAssertEqual(Double(result.pixelWidth) / Double(result.pixelHeight), 4.0 / 3.0, accuracy: 0.001)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, result.pixelWidth)
        XCTAssertEqual(image.height, result.pixelHeight)
    }

    func testResolutionLimitIsAppliedAfterCroppingAndNeverUpscales() throws {
        let data = try sourceJPEG(size: CGSize(width: 2400, height: 1800))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(data, fileExtension: "jpg",
            to: base, cropFactor: 2, maximumMegapixels: 4)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.pixelWidth, 1200)
        XCTAssertEqual(result.pixelHeight, 900)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 900)
    }

    func testHighResolutionPreservesSmallerOriginalFile() throws {
        let data = try sourceJPEG()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(data, fileExtension: "jpg",
            to: base, cropFactor: 1, maximumMegapixels: 48)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.pixelWidth, 1200)
        XCTAssertEqual(result.pixelHeight, 900)
        XCTAssertEqual(try Data(contentsOf: result.url), data)
    }

    func testResolutionLimitAppliesPortraitOrientationBeforeResizing() throws {
        let original = try sourceJPEG(size: CGSize(width: 2400, height: 1800))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let orientedData = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            orientedData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(orientedData as Data, fileExtension: "jpg",
            to: base, cropFactor: 1, maximumMegapixels: 4)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertLessThanOrEqual(result.pixelWidth * result.pixelHeight, 4_000_000)
        XCTAssertGreaterThan(result.pixelHeight, result.pixelWidth)
        XCTAssertEqual(Double(result.pixelWidth) / Double(result.pixelHeight), 3.0 / 4.0, accuracy: 0.001)
        let exportedSource = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let exported = try XCTUnwrap(CGImageSourceCreateImageAtIndex(exportedSource, 0, nil))
        XCTAssertEqual(exported.width, result.pixelWidth)
        XCTAssertEqual(exported.height, result.pixelHeight)
    }

    func testPortraitOrientationIsAppliedBeforeCropping() throws {
        let original = try sourceJPEG()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let orientedData = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            orientedData, "public.jpeg" as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = try CameraService.writeSinglePhoto(orientedData as Data,
                                                        fileExtension: "jpg", to: base,
                                                        cropFactor: 2)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.pixelWidth, 450)
        XCTAssertEqual(result.pixelHeight, 600)
    }
}
