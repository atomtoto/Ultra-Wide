import CoreGraphics
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import UltraWide

final class ReviewImageTests: XCTestCase {
    func testReviewDecodesActualSourceDimensionsAndPixelDetail() throws {
        let source = try sourceImage(width: 2400, height: 1600)
        let url = try write(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoded = try ReviewImageDecoder.read(url).image
        XCTAssertEqual(decoded.width, 2400)
        XCTAssertEqual(decoded.height, 1600)
        // Adjacent one-pixel stripes disappear in the 1800px preview. They
        // must remain distinct when inspecting the actual final file.
        let sample = try XCTUnwrap(decoded.cropping(to: CGRect(x: 500, y: 500, width: 2, height: 1)))
        var pixels = [UInt8](repeating: 0, count: 8)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 1, bitsPerComponent: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertGreaterThan(abs(Int(pixels[0]) - Int(pixels[4])), 200)
    }

    func testReviewAppliesEXIFOrientationAtFullResolution() throws {
        let url = try write(sourceImage(width: 1200, height: 800), orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try ReviewImageDecoder.read(url).image
        XCTAssertEqual(image.width, 800)
        XCTAssertEqual(image.height, 1200)
    }

    @MainActor
    func testSourceLoadingPreservesZoomAndAllowsNativePixelInspection() async throws {
        let original = try sourceImage(width: 2400, height: 1600)
        let url = try write(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let host = ReviewImageHost(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
        host.configure(preview: UIImage(cgImage: original), url: url, pixelSize: CGSize(width: 2400, height: 1600))
        host.layoutIfNeeded()
        host.scrollView.setZoomScale(0.5, animated: false)
        let zoom = host.scrollView.zoomScale
        for _ in 0..<400 {
            if host.hasFullResolutionImage { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(host.hasFullResolutionImage)
        XCTAssertEqual(host.imageView.image?.cgImage?.width, 2400)
        XCTAssertEqual(host.scrollView.zoomScale, zoom, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(host.scrollView.maximumZoomScale, 1)
        host.cancelLoading()
    }

    private func sourceImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 2) {
                let index = (y * width + x) * 4
                pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func write(_ image: CGImage, orientation: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
