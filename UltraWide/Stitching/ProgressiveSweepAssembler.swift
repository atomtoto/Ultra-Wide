import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct ProgressiveSweepUpdate: @unchecked Sendable {
    let sessionID: UUID
    let frameIDs: Set<UUID>
    let alignments: [UUID: StitchAlignment]
    let polygonsByFrame: [UUID: [CGPoint]]
    let rejectedFrameIDs: Set<UUID>
    let insufficientDetailFrameIDs: Set<UUID>
    let retainedFrameIDs: Set<UUID>
    let preview: CGImage?
    let coverage: VisualSweepCoverage
    let coverageAnalysis: SweepCoverageAnalysis

    init(sessionID: UUID, frameIDs: Set<UUID>, alignments: [UUID: StitchAlignment],
         polygonsByFrame: [UUID: [CGPoint]], rejectedFrameIDs: Set<UUID>, retainedFrameIDs: Set<UUID>, preview: CGImage?,
         insufficientDetailFrameIDs: Set<UUID> = []) {
        self.sessionID = sessionID
        self.frameIDs = frameIDs
        self.alignments = alignments
        self.polygonsByFrame = polygonsByFrame
        self.rejectedFrameIDs = rejectedFrameIDs
        self.insufficientDetailFrameIDs = insufficientDetailFrameIDs
        self.retainedFrameIDs = retainedFrameIDs
        self.preview = preview
        coverage = VisualSweepCoverage(polygons: Array(polygonsByFrame.values))
        coverageAnalysis = SweepCoverageAnalysis(coverage: coverage)
    }
}

protocol SweepAssembling: Sendable {
    func update(sessionID: UUID, plan: CapturePlan, frames: [CapturedFrame]) async throws -> ProgressiveSweepUpdate
}

/// A serial, bounded registration worker. It reads only durable source files,
/// caches their small thumbnails and transforms, and never owns the camera.
actor ProgressiveSweepAssembler: SweepAssembling {
    private struct View {
        let frame: CapturedFrame
        let image: RegistrationImage
        let transform: Homography3x3
        let pixelSize: CGSize
        let polygon: [CGPoint]
        let photometry: LinearLuminanceImage?
        let luminanceGain: Double
    }
    private let registration: any FrameRegistration
    private var sessionID: UUID?
    private var views: [UUID: View] = [:]
    private var rejected: Set<UUID> = []
    private var insufficientDetail: Set<UUID> = []
    private var failedReferences: [UUID: Set<UUID>] = [:]
    // Display P3 uses the sRGB transfer curve. Apply exposure to linear light,
    // then let Core Image encode the output preview into Display P3.
    private let imageContext = CIContext(options: [
        .cacheIntermediates: false,
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    ])

    init(registration: any FrameRegistration = VisionFrameRegistration()) {
        self.registration = registration
    }

    func update(sessionID: UUID, plan: CapturePlan, frames: [CapturedFrame]) async throws -> ProgressiveSweepUpdate {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            views.removeAll(); rejected.removeAll(); failedReferences.removeAll(); insufficientDetail.removeAll()
        }
        let currentIDs = Set(frames.map(\.id))
        views = views.filter { currentIDs.contains($0.key) }
        rejected.formIntersection(currentIDs)
        insufficientDetail.formIntersection(currentIDs)
        failedReferences = failedReferences.filter { currentIDs.contains($0.key) }
        // A later view may bridge an earlier disconnected exposure. Revisit
        // provisional rejects once within this batch after the graph grows.
        for _ in 0..<2 {
        for frame in frames where views[frame.id] == nil {
            try Task.checkCancellation()
            // Failed views can be retried once a new aligned neighbor arrives.
            if failedReferences[frame.id] == Set(views.keys) { continue }
            guard let (image, size) = Self.read(frame.fileURL) else {
                rejected.insert(frame.id); failedReferences[frame.id] = Set(views.keys)
                continue
            }
            let photometry = LinearLuminanceImage(image.cgImage)
            let transform: Homography3x3
            let luminanceGain: Double
            if views.isEmpty {
                // The center is the only geometrical anchor. Subsequent
                // footprints require a validated image-to-image transform.
                guard abs(frame.yawDegrees) < 5 && abs(frame.pitchDegrees) < 5 else {
                    rejected.insert(frame.id); failedReferences[frame.id] = []
                    continue
                }
                let sx = tan(plan.sourceHorizontalFOV * .pi / 360) / tan(plan.targetHorizontalFOV * .pi / 360)
                let sy = tan(plan.sourceVerticalFOV * .pi / 360) / tan(plan.targetVerticalFOV * .pi / 360)
                transform = Homography3x3([sx, 0, (1 - sx) / 2, 0, sy, (1 - sy) / 2, 0, 0, 1])
                luminanceGain = 1
            } else {
                let references = views.values.sorted {
                    hypot($0.frame.yawDegrees - frame.yawDegrees, $0.frame.pitchDegrees - frame.pitchDegrees)
                        < hypot($1.frame.yawDegrees - frame.yawDegrees, $1.frame.pitchDegrees - frame.pitchDegrees)
                }.prefix(3)
                var matched: (transform: Homography3x3, gain: Double)?
                var detailFailures = 0
                for reference in references {
                    try Task.checkCancellation()
                    do {
                        let prior = Self.motionPrior(source: frame, reference: reference.frame, plan: plan)
                        let result = try await registration.register(source: image, reference: reference.image,
                                                                     initialEstimate: prior)
                        try Task.checkCancellation()
                        guard self.sessionID == sessionID else { throw CancellationError() }
                        let candidate = result.homography.concatenating(reference.transform)
                        guard Self.plausible(candidate, frame: frame, plan: plan),
                              let polygon = VisualSweepCoverage.footprint(candidate),
                              VisualSweepCoverage.overlap(polygon, reference.polygon) >= 0.15 else { continue }
                        // A chain can agree with its last neighbor and still
                        // drift from earlier views. Verify the actual candidate
                        // against the other overlapping neighbors before its
                        // footprint is allowed to complete the sweep.
                        for neighbor in references where neighbor.frame.id != reference.frame.id {
                            guard VisualSweepCoverage.overlap(polygon, neighbor.polygon) >= 0.25,
                                  let inverse = neighbor.transform.inverted() else { continue }
                            do {
                                try await registration.validate(source: image, reference: neighbor.image,
                                    homography: candidate.concatenating(inverse))
                            } catch VisualRegistrationFailure.insufficientDetail { continue }
                            catch VisualRegistrationFailure.insufficientOverlap { continue }
                        }
                        try Task.checkCancellation()
                        guard self.sessionID == sessionID else { throw CancellationError() }
                        let gain = LinearLuminanceImage.gain(source: photometry, reference: reference.photometry,
                            sourceToReference: result.homography, referenceGain: reference.luminanceGain)
                        matched = (candidate, gain)
                        break
                    } catch is CancellationError { throw CancellationError() }
                    catch VisualRegistrationFailure.insufficientDetail { detailFailures += 1; continue }
                    catch { continue }
                }
                guard let matched else {
                    if detailFailures == references.count { insufficientDetail.insert(frame.id) }
                    else { insufficientDetail.remove(frame.id) }
                    rejected.insert(frame.id); failedReferences[frame.id] = Set(views.keys)
                    continue
                }
                transform = matched.transform
                luminanceGain = matched.gain
            }
            guard let polygon = VisualSweepCoverage.footprint(transform) else { rejected.insert(frame.id); continue }
            views[frame.id] = View(frame: frame, image: image, transform: transform, pixelSize: size,
                                  polygon: polygon, photometry: photometry, luminanceGain: luminanceGain)
            rejected.remove(frame.id); failedReferences.removeValue(forKey: frame.id)
            insufficientDetail.remove(frame.id)
        }
        }
        try Task.checkCancellation()
        let retained = retainedIDs(frames)
        let alignedViews = frames.compactMap { views[$0.id] }.filter { retained.contains($0.frame.id) }
        return ProgressiveSweepUpdate(
            sessionID: sessionID, frameIDs: currentIDs,
            alignments: Dictionary(uniqueKeysWithValues: alignedViews.map {
                ($0.frame.id, StitchAlignment(normalizedHomography: $0.transform.elements,
                    sourcePixelWidth: Int($0.pixelSize.width), sourcePixelHeight: Int($0.pixelSize.height),
                    luminanceGain: $0.luminanceGain))
            }),
            polygonsByFrame: Dictionary(uniqueKeysWithValues: alignedViews.map { ($0.frame.id, $0.polygon) }),
            rejectedFrameIDs: rejected, retainedFrameIDs: retained,
            preview: render(alignedViews, plan: plan), insufficientDetailFrameIDs: insufficientDetail
        )
    }

    private static func plausible(_ transform: Homography3x3, frame: CapturedFrame, plan: CapturePlan) -> Bool {
        guard let center = transform.transform(CGPoint(x: 0.5, y: 0.5)) else { return false }
        let predictedX = (tan(frame.yawDegrees * .pi / 180) / tan(plan.targetHorizontalFOV * .pi / 360) + 1) / 2
        let predictedY = (1 - tan(frame.pitchDegrees * .pi / 180) / tan(plan.targetVerticalFOV * .pi / 360)) / 2
        // Motion is a coarse sanity check against false repeated-texture
        // matches. It does not set the confirmed footprint or final matrix.
        return hypot(center.x - predictedX, center.y - predictedY) < 0.30
    }

    private static func motionPrior(source: CapturedFrame, reference: CapturedFrame, plan: CapturePlan) -> Homography3x3 {
        relativePose(yaw: source.yawDegrees, pitch: source.pitchDegrees, roll: source.rollDegrees,
                     reference: reference, plan: plan)
    }

    nonisolated static func predictedTransform(_ reading: MotionReading, relativeTo reference: CapturedFrame,
        alignment: StitchAlignment, plan: CapturePlan) -> Homography3x3 {
        relativePose(yaw: reading.yawDegrees, pitch: reading.pitchDegrees, roll: reading.rollDegrees,
                     reference: reference, plan: plan)
            .concatenating(Homography3x3(alignment.normalizedHomography))
    }

    private nonisolated static func relativePose(yaw: Double, pitch: Double, roll: Double,
        reference: CapturedFrame, plan: CapturePlan) -> Homography3x3 {
        func rotation(yaw: Double, pitch: Double, roll: Double) -> Homography3x3 {
            let yaw = yaw * .pi / 180
            // MotionGuide projects both angular readings onto the reference
            // optical depth. For Ry(yaw) * Rx(eulerPitch), its pitch is
            // atan(tan(eulerPitch) / cos(yaw)), not the Euler rotation itself.
            let projectedPitch = pitch * .pi / 180
            let pitch = atan(tan(projectedPitch) * cos(yaw))
            let roll = roll * .pi / 180
            // Rz rotates image-up around the forward axis. Positive rotation
            // has the same sign as expectedUp.cross(up).dot(forward) in
            // MotionGuide (image x right, y down, optical z forward).
            let rz = Homography3x3([cos(roll), -sin(roll), 0, sin(roll), cos(roll), 0, 0, 0, 1])
            let rx = Homography3x3([1, 0, 0, 0, cos(pitch), -sin(pitch), 0, sin(pitch), cos(pitch)])
            let ry = Homography3x3([cos(yaw), 0, sin(yaw), 0, 1, 0, -sin(yaw), 0, cos(yaw)])
            return rz.concatenating(rx).concatenating(ry)
        }
        let intrinsics = Homography3x3([
            1 / (2 * tan(plan.sourceHorizontalFOV * .pi / 360)), 0, 0.5,
            0, 1 / (2 * tan(plan.sourceVerticalFOV * .pi / 360)), 0.5, 0, 0, 1
        ])
        return intrinsics.inverted()!.concatenating(rotation(yaw: yaw, pitch: pitch, roll: roll))
            .concatenating(rotation(yaw: reference.yawDegrees, pitch: reference.pitchDegrees,
                                   roll: reference.rollDegrees).inverted()!).concatenating(intrinsics)
    }

    private func retainedIDs(_ frames: [CapturedFrame]) -> Set<UUID> {
        guard let anchor = frames.first?.id else { return [] }
        // Disconnected images stay available for a future bridge. Only
        // confirmed redundant views may be retired while acquiring images.
        var kept = frames
        while kept.count > SweepFrameReducer.preferredFrameCount {
            let coverage = VisualSweepCoverage(polygons: kept.compactMap { views[$0.id]?.polygon }).fraction
            var removed = false
            for index in kept.indices where kept[index].id != anchor && kept[index].id != frames.last?.id {
                guard views[kept[index].id] != nil else { continue }
                let remaining = kept.enumerated().filter { $0.offset != index }.map(\.element)
                let polygons = remaining.compactMap { views[$0.id]?.polygon }
                guard VisualSweepCoverage(polygons: polygons).fraction + 1e-10 >= coverage,
                      Self.connected(polygons) else { continue }
                kept = remaining; removed = true; break
            }
            if !removed { break }
        }
        return Set(kept.map(\.id))
    }

    private static func connected(_ polygons: [[CGPoint]]) -> Bool {
        guard !polygons.isEmpty else { return true }
        var visited: Set<Int> = [0], frontier = [0]
        while let index = frontier.popLast() {
            for other in polygons.indices where !visited.contains(other) {
                if VisualSweepCoverage.overlap(polygons[index], polygons[other]) >= 0.15 {
                    visited.insert(other); frontier.append(other)
                }
            }
        }
        return visited.count == polygons.count
    }

    private static func read(_ url: URL) -> (RegistrationImage, CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        let size = (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        return (RegistrationImage(thumbnail), size)
    }

    private func render(_ aligned: [View], plan: CapturePlan) -> CGImage? {
        guard !aligned.isEmpty else { return nil }
        let height = plan.orientation.isPortrait ? 560.0 : 420.0
        let width = plan.orientation.isPortrait ? 420.0 : 560.0
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        var composite = CIImage(color: .clear).cropped(to: canvas)
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        for view in aligned {
            let projected = corners.compactMap { view.transform.transform($0) }
            guard projected.count == 4 else { continue }
            func vector(_ point: CGPoint) -> CIVector {
                // Core Image uses bottom-left coordinates.
                CIVector(x: point.x * width, y: (1 - point.y) * height)
            }
            let source = CIImage(cgImage: view.image.cgImage)
            let gain = view.luminanceGain
            let corrected = source.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0)
            ])
            let feather = max(2, min(source.extent.width, source.extent.height) * 0.02)
            let mask = CIImage(color: .white).cropped(to: source.extent.insetBy(dx: feather, dy: feather))
                .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": feather * 0.5])
                .cropped(to: source.extent)
            let softened = corrected.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: source.extent),
                kCIInputMaskImageKey: mask
            ])
            let image = softened.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": vector(projected[0]), "inputTopRight": vector(projected[1]),
                "inputBottomRight": vector(projected[2]), "inputBottomLeft": vector(projected[3])
            ])
            composite = image.cropped(to: canvas).composited(over: composite)
        }
        return imageContext.createCGImage(composite, from: canvas, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
    }
}

/// Photometry is measured only after registration has validated the overlap.
/// A robust scalar ratio avoids changing the white balance or mistaking a
/// clipped lamp, black edge, moving object, or small mismatch for exposure.
private struct LinearLuminanceImage {
    let width: Int
    let height: Int
    let values: [Float]
    let valid: [UInt8]

    init?(_ image: CGImage) {
        // Exposure varies slowly across a view. This smaller cached plane
        // keeps the progressive worker's time and memory bounded.
        let scale = min(1, 256.0 / Double(max(image.width, image.height)))
        let width = max(2, Int((Double(image.width) * scale).rounded()))
        let height = max(2, Int((Double(image.height) * scale).rounded()))
        self.width = width; self.height = height
        guard width > 1, height > 1 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            // Bitmap rows retain CGImage's pixel order, matching registration.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let linear = (0...255).map { value -> Float in
            let encoded = Float(value) / 255
            return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
        }
        var luminance = [Float](repeating: 0, count: width * height)
        var eligibility = [UInt8](repeating: 0, count: width * height)
        for index in luminance.indices {
            let offset = index * 4
            let r = rgba[offset], g = rgba[offset + 1], b = rgba[offset + 2]
            let y = 0.22897456 * linear[Int(r)] + 0.69173852 * linear[Int(g)] + 0.07928691 * linear[Int(b)]
            luminance[index] = y
            // Clipping in any channel makes a radiometric ratio unreliable.
            eligibility[index] = rgba[offset + 3] >= 250 && max(r, max(g, b)) < 250 && y > 0.012 ? 1 : 0
        }
        values = luminance; valid = eligibility
    }

    private func sample(_ point: CGPoint) -> Double? {
        let x = Double(point.x) * Double(width - 1), y = Double(point.y) * Double(height - 1)
        guard x.isFinite, y.isFinite, x >= 1, y >= 1,
              x < Double(width - 2), y < Double(height - 2) else { return nil }
        let ix = Int(x), iy = Int(y), fx = x - Double(ix), fy = y - Double(iy)
        let indices = [iy * width + ix, iy * width + ix + 1, (iy + 1) * width + ix, (iy + 1) * width + ix + 1]
        guard indices.allSatisfy({ valid[$0] != 0 }) else { return nil }
        return Double(values[indices[0]]) * (1 - fx) * (1 - fy)
            + Double(values[indices[1]]) * fx * (1 - fy)
            + Double(values[indices[2]]) * (1 - fx) * fy + Double(values[indices[3]]) * fx * fy
    }

    static func gain(source: Self?, reference: Self?, sourceToReference: Homography3x3,
                     referenceGain: Double) -> Double {
        guard let source, let reference else { return 1 }
        var ratios: [Double] = []
        var cells: Set<Int> = []
        for row in 0..<48 {
            for column in 0..<48 {
                let point = CGPoint(x: 0.03 + 0.94 * (Double(column) + 0.5) / 48,
                                    y: 0.03 + 0.94 * (Double(row) + 0.5) / 48)
                guard let other = sourceToReference.transform(point),
                      let a = source.sample(point), let b = reference.sample(other) else { continue }
                let ratio = log2(b / a)
                guard ratio.isFinite, abs(ratio) <= 3 else { continue }
                ratios.append(ratio); cells.insert((row / 12) * 4 + column / 12)
            }
        }
        guard ratios.count >= 80, cells.count >= 3 else { return 1 }
        ratios.sort()
        let median = ratios[ratios.count / 2]
        let deviations = ratios.map { abs($0 - median) }.sorted()
        // Strong spatial changes cannot be repaired with one exposure gain.
        guard deviations[deviations.count / 2] < 0.4 else { return 1 }
        return min(4, max(0.25, exp2(median) * referenceGain))
    }
}
