import CoreGraphics
import CoreImage
import Foundation
import Vision

/// A forward projective transform. Image coordinates are normalized, with (0, 0)
/// at the top left. Values use row-major order and multiply column vectors.
struct Homography3x3: Sendable, Equatable {
    let elements: [Double]

    init(_ rowMajor: [Double]) {
        precondition(rowMajor.count == 9)
        let divisor = rowMajor[8]
        elements = divisor.isFinite && abs(divisor) > 1e-12
            ? rowMajor.map { $0 / divisor } : rowMajor
    }

    static let identity = Homography3x3([1, 0, 0, 0, 1, 0, 0, 0, 1])

    func transform(_ point: CGPoint) -> CGPoint? {
        let x = Double(point.x), y = Double(point.y)
        let denominator = elements[6] * x + elements[7] * y + elements[8]
        guard denominator.isFinite, abs(denominator) > 1e-10 else { return nil }
        let tx = (elements[0] * x + elements[1] * y + elements[2]) / denominator
        let ty = (elements[3] * x + elements[4] * y + elements[5]) / denominator
        guard tx.isFinite, ty.isFinite else { return nil }
        return CGPoint(x: tx, y: ty)
    }

    /// Applies this transform first, then `next` (matrix product next * self).
    func concatenating(_ next: Homography3x3) -> Homography3x3 {
        var product = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                for k in 0..<3 {
                    product[row * 3 + column] += next.elements[row * 3 + k] * elements[k * 3 + column]
                }
            }
        }
        return Homography3x3(product)
    }

    func inverted() -> Homography3x3? {
        let a = elements[0], b = elements[1], c = elements[2]
        let d = elements[3], e = elements[4], f = elements[5]
        let g = elements[6], h = elements[7], i = elements[8]
        let cofactors = [e * i - f * h, c * h - b * i, b * f - c * e,
                         f * g - d * i, a * i - c * g, c * d - a * f,
                         d * h - e * g, b * g - a * h, a * e - b * d]
        let determinant = a * cofactors[0] + b * cofactors[3] + c * cofactors[6]
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        return Homography3x3(cofactors.map { $0 / determinant })
    }
}

/// CGImage is immutable; its retained provider owns its pixel storage.
struct RegistrationImage: @unchecked Sendable {
    let cgImage: CGImage
    // A view participates in several registrations and neighbor checks. Keep
    // its immutable analysis plane instead of redrawing it for every pair.
    fileprivate let luminance: RegistrationLuminance?

    init(_ cgImage: CGImage) {
        self.cgImage = cgImage
        luminance = try? RegistrationLuminance(image: cgImage, maximumSide: 640)
    }
}

struct VisualRegistration: Sendable {
    let homography: Homography3x3
    /// Fraction of sampled source pixels which land within the reference image.
    let overlapFraction: Double
    /// Fraction of textured local patches whose content agrees after alignment.
    let visualAgreement: Double
    /// Global photometric agreement, used only to choose between transforms
    /// which have independently passed all geometry and contour checks.
    var contentCorrelation: Double = 0
}

enum VisualRegistrationFailure: Error, Sendable {
    case unreadableImage
    case insufficientDetail
    case noAlignment
    case invalidGeometry
    case insufficientOverlap
    case inconsistentContent
}

protocol FrameRegistration: Sendable {
    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration
    func register(source: RegistrationImage, reference: RegistrationImage,
                  initialEstimate: Homography3x3?) async throws -> VisualRegistration
    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws
}

extension FrameRegistration {
    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws {
        try Task.checkCancellation()
        _ = try VisionFrameRegistration.verify(homography: homography, source: source, reference: reference)
    }

    func register(source: RegistrationImage, reference: RegistrationImage,
                  initialEstimate: Homography3x3?) async throws -> VisualRegistration {
        try await register(source: source, reference: reference)
    }
}

/// Serial Vision requests keep image registration away from the main actor.
/// Vision's confidence is not a content match score: independently verify the
/// returned transform against luminance patches before adding any coverage.
actor VisionFrameRegistration: FrameRegistration {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws {
        try Task.checkCancellation()
        _ = try Self.verify(homography: homography, source: source, reference: reference)
    }

    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration {
        try registerImages(source: source, reference: reference, initialEstimate: nil)
    }

    func register(source: RegistrationImage, reference: RegistrationImage,
                  initialEstimate: Homography3x3?) async throws -> VisualRegistration {
        try registerImages(source: source, reference: reference, initialEstimate: initialEstimate)
    }

    private func registerImages(source: RegistrationImage, reference: RegistrationImage,
                                initialEstimate: Homography3x3?) throws -> VisualRegistration {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let sourceImage = source.luminance, let referenceImage = reference.luminance else {
                throw VisualRegistrationFailure.unreadableImage
            }
            guard sourceImage.standardDeviation > 0.012, referenceImage.standardDeviation > 0.012 else {
                throw VisualRegistrationFailure.insufficientDetail
            }
            // A near-perfect seed has already passed the same contour,
            // overlap and content checks as Vision. Avoid a full homography
            // search in this common case; retain the verified result on fallback.
            let seedResult = initialEstimate.map { estimate in
                Result { try Self.verify(homography: estimate, source: sourceImage, reference: referenceImage) }
            }
            let seeded = try? seedResult?.get()
            try Task.checkCancellation()
            if let seeded, seeded.contentCorrelation >= 0.985, seeded.visualAgreement >= 0.98 {
                return seeded
            }
            // Requests require identical dimensions. Each image is resized to
            // the same canvas; the public transform stays normalized, so even
            // a different input size does not change its coordinate convention.
            let renderedSource = try sourceImage.renderedImage(width: sourceImage.width, height: sourceImage.height)
            let visionSource: CGImage
            if let initialEstimate {
                guard Self.geometryIsUsable(initialEstimate) else { throw VisualRegistrationFailure.invalidGeometry }
                visionSource = try prewarped(renderedSource, using: initialEstimate)
            } else { visionSource = renderedSource }
            let visionReference = try referenceImage.renderedImage(width: sourceImage.width, height: sourceImage.height)
            let request = VNHomographicImageRegistrationRequest(targetedCGImage: visionSource)
            let handler = VNImageRequestHandler(cgImage: visionReference)
            do { try handler.perform([request]) }
            catch {
                try Task.checkCancellation()
                guard let seedResult else { throw VisualRegistrationFailure.noAlignment }
                return try seedResult.get()
            }
            guard let observation = request.results?.first else {
                guard let seedResult else { throw VisualRegistrationFailure.noAlignment }
                return try seedResult.get()
            }
            try Task.checkCancellation()
            let matrix = observation.warpTransform
            let pixelTransform = Homography3x3([
                Double(matrix.columns.0.x), Double(matrix.columns.1.x), Double(matrix.columns.2.x),
                Double(matrix.columns.0.y), Double(matrix.columns.1.y), Double(matrix.columns.2.y),
                Double(matrix.columns.0.z), Double(matrix.columns.1.z), Double(matrix.columns.2.z)
            ])
            let width = Double(visionSource.width), height = Double(visionSource.height)
            // Vision returns source → reference in bottom-left pixel space.
            let toPixels = Homography3x3([width, 0, 0, 0, -height, height, 0, 0, 1])
            let toNormalized = Homography3x3([1 / width, 0, 0, 0, -1 / height, 1, 0, 0, 1])
            let residual = toPixels.concatenating(pixelTransform).concatenating(toNormalized)
            let homography = initialEstimate?.concatenating(residual) ?? residual
            do {
                let refined = try Self.verify(homography: homography, source: sourceImage, reference: referenceImage)
                // Vision may add a small but unnecessary residual to a good
                // motion seed. Repeated residuals accumulate across a sweep.
                // Compare both against the original images; motion alone is
                // never enough to select the prior.
                if let seeded,
                   seeded.contentCorrelation * seeded.visualAgreement >
                       refined.contentCorrelation * refined.visualAgreement {
                    return seeded
                }
                try Task.checkCancellation()
                return refined
            }
            catch {
                try Task.checkCancellation()
                guard let seedResult else { throw error }
                return try seedResult.get()
            }
        }
    }

    /// Motion is only a starting estimate. The returned transform must still
    /// pass image agreement against the original, unwarped source and reference.
    private func prewarped(_ image: CGImage, using homography: Homography3x3) throws -> CGImage {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        let corners: [(String, CGPoint)] = [
            ("inputTopLeft", CGPoint(x: 0, y: 0)), ("inputTopRight", CGPoint(x: 1, y: 0)),
            ("inputBottomRight", CGPoint(x: 1, y: 1)), ("inputBottomLeft", CGPoint(x: 0, y: 1))
        ]
        for (key, corner) in corners {
            guard let point = homography.transform(corner) else { throw VisualRegistrationFailure.invalidGeometry }
            filter.setValue(CIVector(x: point.x * width, y: (1 - point.y) * height), forKey: key)
        }
        guard let output = filter.outputImage,
              let warped = context.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            throw VisualRegistrationFailure.unreadableImage
        }
        return warped
    }

    /// Also used by tests to distinguish valid geometry from a visually wrong,
    /// but mathematically plausible, homography.
    nonisolated static func verify(
        homography: Homography3x3, source: RegistrationImage, reference: RegistrationImage
    ) throws -> VisualRegistration {
        guard let source = source.luminance, let reference = reference.luminance else {
            throw VisualRegistrationFailure.unreadableImage
        }
        return try verify(homography: homography, source: source, reference: reference)
    }

    private nonisolated static func verify(
        homography: Homography3x3, source: RegistrationLuminance, reference: RegistrationLuminance
    ) throws -> VisualRegistration {
        guard geometryIsUsable(homography) else { throw VisualRegistrationFailure.invalidGeometry }
        guard source.standardDeviation > 0.012, reference.standardDeviation > 0.012 else {
            throw VisualRegistrationFailure.insufficientDetail
        }
        // Patches sample a two-dimensional spread of the overlap. A single
        // matching foreground object cannot validate an unrelated background.
        var overlapping = 0, tested = 0, textured = 0, agreed = 0, displaced = 0
        var regionalTexture = [Int](repeating: 0, count: 4)
        var regionalDisplacement = [Int](repeating: 0, count: 4)
        var sourceValues: [Double] = [], referenceValues: [Double] = []
        let halfPatch = 3
        for gridY in 0..<12 {
            try Task.checkCancellation()
            for gridX in 0..<12 {
                tested += 1
                let centerX = (Double(gridX) + 0.5) / 12
                let centerY = (Double(gridY) + 0.5) / 12
                var localSource: [Double] = [], localReference: [Double] = []
                var referencePoints: [CGPoint] = []
                localSource.reserveCapacity(49)
                localReference.reserveCapacity(49)
                referencePoints.reserveCapacity(49)
                for y in -halfPatch...halfPatch {
                    for x in -halfPatch...halfPatch {
                        let point = CGPoint(x: centerX + Double(x) / Double(source.width),
                                            y: centerY + Double(y) / Double(source.height))
                        guard let warped = homography.transform(point),
                              let a = source.sample(point), let b = reference.sample(warped) else { continue }
                        localSource.append(a); localReference.append(b)
                        referencePoints.append(warped)
                    }
                }
                guard localSource.count >= 40 else { continue }
                overlapping += 1
                sourceValues += localSource; referenceValues += localReference
                guard let correlation = correlation(localSource, localReference, minimumDeviation: 0.008) else { continue }
                textured += 1
                let regions = [gridX < 6 ? 0 : 1, gridY < 6 ? 2 : 3]
                for region in regions { regionalTexture[region] += 1 }
                if correlation >= 0.5 { agreed += 1 }
                // Brightness correlation can stay high on a shifted wall or
                // straight edge. Compare gradients, and treat a preferred
                // one-pixel shift as a mismatch: it grows at export resolution.
                guard let sourceGradient = Self.gradients(localSource),
                      let referenceGradient = Self.gradients(localReference),
                      let contourScore = Self.correlation(sourceGradient, referenceGradient, minimumDeviation: 0.004),
                      contourScore < 0.95 else { continue }
                func score(dx: Int, dy: Int) -> Double? {
                    let offset = CGPoint(x: Double(dx) / Double(reference.width),
                                         y: Double(dy) / Double(reference.height))
                    let shifted = referencePoints.compactMap {
                        reference.sample(CGPoint(x: $0.x + offset.x, y: $0.y + offset.y))
                    }
                    guard shifted.count == localSource.count else { return nil }
                    guard let gradient = Self.gradients(shifted) else { return nil }
                    return Self.correlation(sourceGradient, gradient, minimumDeviation: 0.004)
                }
                // The margin tolerates resampling and 8-bit quantization on
                // subpixel matches. Stop once no farther score can beat it.
                var nearby = contourScore
                var patchIsDisplaced = false
                nearbySearch: for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if nearby >= 0.95 { break nearbySearch }
                        if let score = score(dx: dx, dy: dy) { nearby = max(nearby, score) }
                    }
                }
                if nearby >= 0.85 && nearby > contourScore + 0.05 {
                    patchIsDisplaced = true
                } else if nearby < 0.95 {
                    outerSearch: for dy in -3...3 {
                        for dx in -3...3 where abs(dx) > 1 || abs(dy) > 1 {
                            if let score = score(dx: dx, dy: dy), score >= 0.85, score > nearby + 0.05 {
                                patchIsDisplaced = true
                                break outerSearch
                            }
                        }
                    }
                }
                if patchIsDisplaced {
                    displaced += 1
                    for region in regions { regionalDisplacement[region] += 1 }
                }
            }
        }
        let overlap = Double(overlapping) / Double(tested)
        guard overlap >= 0.2 else { throw VisualRegistrationFailure.insufficientOverlap }
        guard textured >= 8,
              let totalCorrelation = correlation(sourceValues, referenceValues, minimumDeviation: 0.012) else {
            throw VisualRegistrationFailure.insufficientDetail
        }
        let agreement = Double(agreed) / Double(textured)
        // A matching wall must not hide displaced foreground contours in one
        // half of the overlap. Require sufficient texture in each tested half.
        let hasLocalParallax = (0..<4).contains { region in
            regionalTexture[region] >= 16 && regionalDisplacement[region]
                >= max(3, Int(ceil(Double(regionalTexture[region]) * 0.12)))
        }
        guard totalCorrelation >= 0.55, agreement >= 0.65,
              !hasLocalParallax,
              displaced < max(2, Int(ceil(Double(textured) * 0.08))) else {
            throw VisualRegistrationFailure.inconsistentContent
        }
        return VisualRegistration(homography: homography, overlapFraction: overlap,
                                  visualAgreement: agreement, contentCorrelation: totalCorrelation)
    }

    private nonisolated static func geometryIsUsable(_ h: Homography3x3) -> Bool {
        guard h.elements.allSatisfy(\.isFinite), h.inverted() != nil else { return false }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let denominators = corners.map { h.elements[6] * Double($0.x) + h.elements[7] * Double($0.y) + h.elements[8] }
        // The projective horizon must stay outside the entire source rectangle.
        guard denominators.allSatisfy({ $0 > 0 }) || denominators.allSatisfy({ $0 < 0 }),
              let smallest = denominators.map({ abs($0) }).min(),
              let largest = denominators.map({ abs($0) }).max(), smallest > largest * 0.04 else { return false }
        let projected = corners.compactMap(h.transform)
        guard projected.count == 4, projected.allSatisfy({ abs($0.x) < 8 && abs($0.y) < 8 }) else { return false }
        var twiceArea = 0.0
        for i in 0..<4 {
            let a = projected[i], b = projected[(i + 1) % 4], c = projected[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross > 0.005 else { return false }
            twiceArea += Double(a.x * b.y - a.y * b.x)
        }
        return twiceArea >= 0.24 && twiceArea <= 16
    }

    private nonisolated static func gradients(_ values: [Double]) -> [Double]? {
        guard values.count == 49 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(50)
        for y in 1..<6 {
            for x in 1..<6 {
                let index = y * 7 + x
                result.append(values[index + 1] - values[index - 1])
                result.append(values[index + 7] - values[index - 7])
            }
        }
        return result
    }

    private nonisolated static func correlation(_ a: [Double], _ b: [Double], minimumDeviation: Double) -> Double? {
        guard a.count == b.count, a.count > 1 else { return nil }
        let count = Double(a.count), meanA = a.reduce(0, +) / count, meanB = b.reduce(0, +) / count
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for i in a.indices {
            let x = a[i] - meanA, y = b[i] - meanB
            covariance += x * y; varianceA += x * x; varianceB += y * y
        }
        guard varianceA / count >= minimumDeviation * minimumDeviation,
              varianceB / count >= minimumDeviation * minimumDeviation else { return nil }
        return covariance / sqrt(varianceA * varianceB)
    }
}

fileprivate struct RegistrationLuminance {
    let width: Int
    let height: Int
    let values: [UInt8]
    let standardDeviation: Double

    init(image: CGImage, maximumSide: Int) throws {
        let scale = min(1, Double(maximumSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        self.width = width
        self.height = height
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            // A bitmap CGContext's image rows preserve the CGImage pixel order.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw VisualRegistrationFailure.unreadableImage }
        values = pixels
        let count = Double(pixels.count)
        let mean = pixels.reduce(0.0) { $0 + Double($1) / 255 } / count
        standardDeviation = sqrt(pixels.reduce(0.0) { total, value in
            let difference = Double(value) / 255 - mean
            return total + difference * difference
        } / count)
    }

    func renderedImage(width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(width: self.width, height: self.height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: self.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent) else {
            throw VisualRegistrationFailure.unreadableImage
        }
        guard width != self.width || height != self.height else { return image }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            throw VisualRegistrationFailure.unreadableImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw VisualRegistrationFailure.unreadableImage }
        return resized
    }

    func sample(_ point: CGPoint) -> Double? {
        let x = Double(point.x) * Double(width) - 0.5
        let y = Double(point.y) * Double(height) - 0.5
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
        let ix = Int(x), iy = Int(y), fx = x - Double(ix), fy = y - Double(iy)
        let a = Double(values[iy * width + ix]), b = Double(values[iy * width + ix + 1])
        let c = Double(values[(iy + 1) * width + ix]), d = Double(values[(iy + 1) * width + ix + 1])
        return ((a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy) / 255
    }
}
