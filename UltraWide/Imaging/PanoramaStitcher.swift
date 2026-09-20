import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

/// Runs on a worker task. Registration uses small images; final frames are decoded
/// one at a time and each composite is materialized to avoid a growing CI graph.
enum PanoramaStitcher {
    static func stitch(_ frames: [CapturedFrame], progress: @escaping @Sendable (Double) -> Void) throws -> StitchResult {
        guard frames.count >= 3, frames.count <= 18 else { throw CaptureFailure.insufficientFrames }
        let context = CIContext(options: [.cacheIntermediates: false])
        let small = try frames.map { try decode($0.data, maxPixel: 768) }
        let width = CGFloat(small[0].width), height = CGFloat(small[0].height)
        guard small.allSatisfy({ $0.width == small[0].width && $0.height == small[0].height }) else { throw CaptureFailure.alignment }
        var transforms = [matrix_identity_float3x3]
        var previousShift: CGFloat = 0
        for index in 1..<small.count {
            try Task.checkCancellation()
            let matrix = try register(reference: small[index - 1], floating: small[index], context: context)
            let center = try PanoramaGeometry.project(CGPoint(x: width / 2, y: height / 2), by: matrix)
            let shift = center.x - width / 2
            let polygon = try PanoramaGeometry.corners(of: CGRect(x: 0, y: 0, width: width, height: height), by: matrix)
            let bounds = PanoramaGeometry.bounds(polygon)
            guard abs(shift) > width * 0.025, abs(shift) < width * 0.65,
                  abs(center.y - height / 2) < height * 0.20,
                  bounds.width > width * 0.55, bounds.width < width * 1.8,
                  bounds.height > height * 0.65, bounds.height < height * 1.65,
                  index == 1 || shift * previousShift > 0 else { throw CaptureFailure.alignment }
            previousShift = shift
            transforms.append(transforms[index - 1] * matrix)
            progress(Double(index) / Double(frames.count - 1) * 0.42)
        }

        // Project around the middle frame, limiting rectilinear stretching at the ends.
        let middle = transforms[transforms.count / 2]
        guard abs(simd_determinant(middle)) > 0.00001 else { throw CaptureFailure.alignment }
        let inverse = simd_inverse(middle)
        transforms = transforms.map { inverse * $0 }
        let first = try decode(frames[0].data, maxPixel: 2400)
        let ratio = Float(first.width) / Float(small[0].width)
        let upscale = simd_float3x3(diagonal: SIMD3<Float>(ratio, ratio, 1))
        let downscale = simd_float3x3(diagonal: SIMD3<Float>(1 / ratio, 1 / ratio, 1))
        transforms = transforms.map { upscale * $0 * downscale }
        let sourceRect = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let quads = try transforms.map { try PanoramaGeometry.corners(of: sourceRect, by: $0) }
        let fullBounds = PanoramaGeometry.bounds(quads.flatMap { $0 })
        guard fullBounds.width.isFinite, fullBounds.height.isFinite,
              fullBounds.width < sourceRect.width * 9, fullBounds.height < sourceRect.height * 4 else { throw CaptureFailure.alignment }
        let scale = min(1, 8000 / max(fullBounds.width, fullBounds.height),
                        sqrt(18_000_000 / (fullBounds.width * fullBounds.height)))
        let sizing = simd_float3x3(diagonal: SIMD3<Float>(Float(scale), Float(scale), 1))
        transforms = transforms.map { sizing * $0 }
        // Feathered edges are excluded from the coverage test, preventing dark output borders.
        let safeRect = sourceRect.insetBy(dx: sourceRect.width * 0.13, dy: 2)
        let safeQuads = try transforms.map { try PanoramaGeometry.corners(of: safeRect, by: $0) }
        let crop = try PanoramaGeometry.coveredCrop(polygons: safeQuads, bounds: PanoramaGeometry.bounds(safeQuads.flatMap { $0 }))
        guard crop.width > sourceRect.width * scale * 1.08, crop.height > sourceRect.height * scale * 0.40 else {
            throw CaptureFailure.alignment
        }

        let canvas = CGRect(origin: .zero, size: crop.size)
        let offset = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        var composite: CGImage?
        for index in frames.indices {
            try Task.checkCancellation()
            try autoreleasepool {
                let image = try decode(frames[index].data, maxPixel: 2400)
                let input = CIImage(cgImage: image)
                let feathered = index == 0 ? input : feather(input)
                let corners = try PanoramaGeometry.corners(of: sourceRect, by: transforms[index])
                let warped = warp(feathered, corners: corners).transformed(by: offset)
                let background = composite.map(CIImage.init(cgImage:)) ?? CIImage(color: .clear).cropped(to: canvas)
                let merged = warped.composited(over: background).cropped(to: canvas)
                guard let rendered = context.createCGImage(merged, from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                    throw CaptureFailure.capture
                }
                composite = rendered
            }
            progress(0.45 + Double(index + 1) / Double(frames.count) * 0.5)
        }
        guard let composite else { throw CaptureFailure.capture }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureFailure.storage }
        CGImageDestinationAddImage(destination, composite, [kCGImageDestinationLossyCompressionQuality: 0.94,
                                                           kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.storage }
        progress(1)
        return StitchResult(jpeg: data as Data, width: composite.width, height: composite.height, frameCount: frames.count)
    }

    static func decode(_ data: Data, maxPixel: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CaptureFailure.capture }
        return image
    }

    private static func register(reference: CGImage, floating: CGImage, context: CIContext) throws -> simd_float3x3 {
        // Vision's homographic refinement expects already similar views. First
        // estimate the broad displacement, then refine only their shared region.
        let translation = VNTranslationalImageRegistrationRequest(targetedCGImage: floating, options: [:])
        try VNImageRequestHandler(cgImage: reference, options: [:]).perform([translation])
        guard let estimate = translation.results?.first?.alignmentTransform else { throw CaptureFailure.alignment }
        let rect = CGRect(x: 0, y: 0, width: reference.width, height: reference.height)
        let overlap = rect.intersection(rect.offsetBy(dx: estimate.tx, dy: estimate.ty)).integral.insetBy(dx: 2, dy: 2)
        guard overlap.width > rect.width * 0.35, overlap.height > rect.height * 0.6 else { throw CaptureFailure.alignment }
        let referenceImage = CIImage(cgImage: reference)
        let floatingImage = CIImage(cgImage: floating).transformed(by: estimate)
        guard let referenceCrop = context.createCGImage(referenceImage, from: overlap),
              let floatingCrop = context.createCGImage(floatingImage, from: overlap) else { throw CaptureFailure.alignment }
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: floatingCrop, options: [:])
        do { try VNImageRequestHandler(cgImage: referenceCrop, options: [:]).perform([request]) }
        catch { throw CaptureFailure.alignment }
        guard let local = request.results?.first?.warpTransform else { throw CaptureFailure.alignment }
        func translate(_ x: CGFloat, _ y: CGFloat) -> simd_float3x3 {
            simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(Float(x), Float(y), 1)))
        }
        let refined = translate(overlap.minX, overlap.minY) * local * translate(estimate.tx - overlap.minX, estimate.ty - overlap.minY)
        let coarse = translate(estimate.tx, estimate.ty)
        // A low-texture scene can produce an unnecessary projective deformation.
        // Select the model that actually agrees best across the shared pixels.
        let coarseError = try alignmentError(reference: referenceImage, floating: CIImage(cgImage: floating), matrix: coarse, context: context)
        let refinedError = try alignmentError(reference: referenceImage, floating: CIImage(cgImage: floating), matrix: refined, context: context)
        guard min(coarseError, refinedError) < 0.12 else { throw CaptureFailure.alignment }
        return coarseError <= refinedError ? coarse : refined
    }

    private static func alignmentError(reference: CIImage, floating: CIImage, matrix: simd_float3x3, context: CIContext) throws -> Float {
        let corners = try PanoramaGeometry.corners(of: floating.extent, by: matrix)
        var region = reference.extent.intersection(PanoramaGeometry.bounds(corners)).insetBy(dx: 8, dy: 8)
        for _ in 0..<8 {
            let points = try PanoramaGeometry.corners(of: region, by: matrix_identity_float3x3)
            if points.allSatisfy({ PanoramaGeometry.contains($0, polygon: corners) }) { break }
            region = region.insetBy(dx: region.width * 0.08, dy: region.height * 0.08)
        }
        guard region.width > 40, region.height > 40 else { return .infinity }
        let difference = reference.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: warp(floating, corners: corners)])
        let average = difference.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: region)])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return (pixel[0] + pixel[1] + pixel[2]) / 3
    }

    private static func warp(_ input: CIImage, corners: [CGPoint]) -> CIImage {
        let filter = CIFilter.perspectiveTransform()
        filter.inputImage = input
        filter.bottomLeft = corners[0]; filter.bottomRight = corners[1]
        filter.topRight = corners[2]; filter.topLeft = corners[3]
        return filter.outputImage ?? input
    }

    private static func feather(_ input: CIImage) -> CIImage {
        let rect = input.extent
        let fade = rect.width * 0.12
        let left = CIFilter.linearGradient()
        left.point0 = CGPoint(x: 0, y: 0); left.point1 = CGPoint(x: fade, y: 0)
        left.color0 = .black; left.color1 = .white
        let right = CIFilter.linearGradient()
        right.point0 = CGPoint(x: rect.maxX - fade, y: 0); right.point1 = CGPoint(x: rect.maxX, y: 0)
        right.color0 = .white; right.color1 = .black
        guard let l = left.outputImage, let r = right.outputImage else { return input }
        let mask = l.applyingFilter("CIMinimumCompositing", parameters: [kCIInputBackgroundImageKey: r]).cropped(to: rect)
        return input.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: rect),
                                                                  kCIInputMaskImageKey: mask])
    }
}
