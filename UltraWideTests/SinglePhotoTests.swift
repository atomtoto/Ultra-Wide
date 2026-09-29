import ImageIO
import UIKit
import XCTest
@testable import UltraWide

final class SinglePhotoTests: XCTestCase {
    private func sourceJPEG() throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900),
                                               format: format)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 900))
            UIColor.green.setFill()
            context.fill(CGRect(x: 400, y: 0, width: 400, height: 900))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 800, y: 0, width: 400, height: 900))
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
