import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import UltraWide

final class ProgressiveSweepAssemblerTests: XCTestCase {
    func testRealTiltedSweepConfirmsFullFieldAndReusesVisualAlignments() async throws {
        let plan = try XCTUnwrap(CapturePlan.make(lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 70, lensHorizontalFOV: 70, sourceLandscapeAspectRatio: 16.0 / 9.0))
        let positions: [(yaw: Double, pitch: Double)] = [
            (0, 0), (-32, -32), (0, -32), (32, -32), (-32, 0),
            (32, 0), (-32, 32), (0, 32), (32, 32)
        ]
        let bundle = Bundle(for: Self.self)
        let frames = try positions.enumerated().map { index, pose -> CapturedFrame in
            let name = String(format: "tilt%02d", index)
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "jpg",
                subdirectory: "Fixtures/TiltedSweep") ?? bundle.url(forResource: name, withExtension: "jpg"))
            return CapturedFrame(id: UUID(), slotID: name, fileURL: url, pass: 0, capturedAt: Date(),
                yawDegrees: pose.yaw,
                pitchDegrees: projectedPitch(eulerPitch: pose.pitch, yaw: pose.yaw),
                rollDegrees: index == 0 ? 0 : 15,
                sharpnessScore: 20, meanBrightness: 0.5, quality: .good)
        }
        let assembler = ProgressiveSweepAssembler()
        let session = UUID()
        let first = try await assembler.update(sessionID: session, plan: plan, frames: frames)
        let second = try await assembler.update(sessionID: session, plan: plan, frames: frames)

        let diagnostics = """
        Real Vision registration of nine tilted camera views.
        First update: aligned=\(first.alignments.count), rejected=\(first.rejectedFrameIDs.count), coverage=\(first.coverage.fraction)
        Second update: aligned=\(second.alignments.count), rejected=\(second.rejectedFrameIDs.count), coverage=\(second.coverage.fraction), complete=\(second.coverage.isComplete)
        \(frames.map { frame in
            let matrix = second.alignments[frame.id]?.normalizedHomography.map { String(format: "%.6f", $0) }.joined(separator: ", ") ?? "rejected"
            return "\(frame.slotID) yaw=\(frame.yawDegrees) pitch=\(frame.pitchDegrees) roll=\(frame.rollDegrees): \(matrix)"
        }.joined(separator: "\n"))
        """
        let report = XCTAttachment(string: diagnostics)
        report.name = "Progressive tilted sweep registration and coverage"
        report.lifetime = .keepAlways
        add(report)
        if let preview = second.preview {
            let attachment = XCTAttachment(image: UIImage(cgImage: preview))
            attachment.name = "Real Vision progressive tilted sweep"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        XCTAssertNotNil(first.alignments[frames[0].id], diagnostics)
        XCTAssertNotNil(second.alignments[frames[0].id], diagnostics)
        XCTAssertGreaterThanOrEqual(second.alignments.count, 8, diagnostics)
        // The exact camera projection of these nine fixtures covers the full
        // field, including the 1.5% image inset and 2.5% target overscan.
        XCTAssertTrue(second.coverage.isComplete, diagnostics)
        XCTAssertEqual(second.coverage.fraction, 1, accuracy: 1e-6, diagnostics)
        for frameID in first.alignments.keys {
            XCTAssertEqual(second.alignments[frameID]?.normalizedHomography,
                           first.alignments[frameID]?.normalizedHomography,
                           "An existing visual alignment must not be estimated again.\n\(diagnostics)")
        }
    }

    func testPredictedCornerTransformUsesProjectedMotionAnglesAndPreservesTilt() throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try XCTUnwrap(CapturePlan.make(lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 70, lensHorizontalFOV: 70, sourceLandscapeAspectRatio: 16.0 / 9.0))
        // MotionGuide measures both angles against forward depth. At a corner,
        // its vertical angle is larger than the camera's Euler pitch.
        XCTAssertEqual(projectedPitch(eulerPitch: 32, yaw: 32), 36.383993076218225, accuracy: 1e-9)
        let references: [(yaw: Double, eulerPitch: Double, roll: Double)] = [(0, 0, 0), (32, 32, 15)]
        let readings: [(yaw: Double, eulerPitch: Double, roll: Double)] = [(32, 32, 15), (40, 32, 15), (40, 32, -12)]
        for referencePose in references {
            let reference = try fixture.frame(width: 540, height: 960, yaw: referencePose.yaw,
                pitch: projectedPitch(eulerPitch: referencePose.eulerPitch, yaw: referencePose.yaw),
                roll: referencePose.roll)
            let referenceAlignment = StitchAlignment(normalizedHomography: physicalProjection(
                yaw: referencePose.yaw, eulerPitch: referencePose.eulerPitch, roll: referencePose.roll,
                plan: plan).elements, sourcePixelWidth: 540, sourcePixelHeight: 960)
            for pose in readings {
                let projectedVerticalAngle = projectedPitch(eulerPitch: pose.eulerPitch, yaw: pose.yaw)
                let reading = MotionReading(yawDegrees: pose.yaw, pitchDegrees: projectedVerticalAngle,
                    rollDegrees: pose.roll, angularSpeed: 0.5, orientationMatchesConfiguration: true,
                    sampleTimestamp: 1)
                let predicted = ProgressiveSweepAssembler.predictedTransform(reading, relativeTo: reference,
                    alignment: referenceAlignment, plan: plan)
                let center = try XCTUnwrap(predicted.transform(CGPoint(x: 0.5, y: 0.5)))
                let expectedX = (1 + tan(pose.yaw * .pi / 180) / tan(plan.targetHorizontalFOV * .pi / 360)) / 2
                let expectedY = (1 - tan(projectedVerticalAngle * .pi / 180) / tan(plan.targetVerticalFOV * .pi / 360)) / 2
                XCTAssertEqual(Double(center.x), expectedX, accuracy: 1e-10)
                XCTAssertEqual(Double(center.y), expectedY, accuracy: 1e-10,
                    "A local yaw turn near a corner must not introduce an artificial pitch change.")
                for point in [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.85, y: 0.15),
                              CGPoint(x: 0.85, y: 0.85), CGPoint(x: 0.15, y: 0.85)] {
                    let actual = try XCTUnwrap(predicted.transform(point))
                    let expected = projectRay(point, yaw: pose.yaw, eulerPitch: pose.eulerPitch,
                                              roll: pose.roll, plan: plan)
                    XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9)
                    XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9,
                        "The projected corners must preserve the camera's physical tilt.")
                }
            }
        }
    }

    func testAppendingDurableFramesRegistersOnlyNewImages() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = CountingFrameRegistration(transforms: [
            264: Homography3x3([1, 0, 0.1, 0, 1, 0, 0, 0, 1]),
            288: Homography3x3([1, 0, -0.1, 0, 1, 0, 0, 0, 1])
        ])
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let center = try fixture.frame(width: 240, height: 320)
        let right = try fixture.frame(width: 264, height: 352, yaw: 8)
        let left = try fixture.frame(width: 288, height: 384, yaw: -8)

        let first = try await assembler.update(sessionID: session, plan: plan, frames: [center])
        XCTAssertEqual(Set(first.alignments.keys), [center.id])
        let second = try await assembler.update(sessionID: session, plan: plan, frames: [center, right])
        let third = try await assembler.update(sessionID: session, plan: plan, frames: [center, right, left])
        _ = try await assembler.update(sessionID: session, plan: plan, frames: [center, right, left])

        let sources = await registration.registeredSourceWidths()
        XCTAssertEqual(sources, [264, 288], "Existing durable frames must retain their cached registration.")
        XCTAssertEqual(Set(third.alignments.keys), [center.id, right.id, left.id])
        XCTAssertEqual(third.alignments[center.id]?.normalizedHomography,
                       first.alignments[center.id]?.normalizedHomography)
        XCTAssertEqual(third.alignments[right.id]?.normalizedHomography,
                       second.alignments[right.id]?.normalizedHomography)
        XCTAssertGreaterThan(third.coverage.fraction, first.coverage.fraction)
        XCTAssertEqual(third.alignments[left.id]?.sourcePixelWidth, 288)
        XCTAssertEqual(third.alignments[left.id]?.sourcePixelHeight, 384)
        XCTAssertTrue(third.rejectedFrameIDs.isEmpty)
    }

    func testRejectedImageAddsNeitherCoverageNorExportAlignment() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = CountingFrameRegistration(rejectAll: true)
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let center = try fixture.frame(width: 240, height: 320)
        let missing = try fixture.frame(width: 264, height: 352, yaw: 20)
        let first = try await assembler.update(sessionID: session, plan: plan, frames: [center])
        let second = try await assembler.update(sessionID: session, plan: plan, frames: [center, missing])

        XCTAssertEqual(second.frameIDs, [center.id, missing.id])
        XCTAssertEqual(Set(second.alignments.keys), [center.id])
        XCTAssertEqual(Set(second.polygonsByFrame.keys), [center.id])
        XCTAssertEqual(second.rejectedFrameIDs, [missing.id])
        XCTAssertTrue(second.retainedFrameIDs.contains(missing.id), "A provisional reject stays available for a future aligned bridge.")
        XCTAssertEqual(second.coverage.fraction, first.coverage.fraction, accuracy: 1e-12)
        XCTAssertFalse(second.coverage.isComplete)
        _ = try await assembler.update(sessionID: session, plan: plan, frames: [center, missing])
        let sources = await registration.registeredSourceWidths()
        XCTAssertEqual(sources, [264], "An unchanged failed reference graph must not repeat the same work.")
    }

    func testDenseSweepRetiresRedundancyWhileKeepingUniqueCoverageAndAnchors() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let center = try fixture.frame(width: 240, height: 320)
        let edge = try fixture.frame(width: 264, height: 352, yaw: 8)
        let redundant = try (0..<58).map { _ in try fixture.frame(width: 240, height: 320) }
        let frames = [center, edge] + redundant
        let registration = CountingFrameRegistration(transforms: [
            264: Homography3x3([1, 0, 0.1, 0, 1, 0, 0, 0, 1])
        ])
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let original = try await assembler.update(sessionID: session, plan: plan, frames: [center, edge])
        let dense = try await assembler.update(sessionID: session, plan: plan, frames: frames)
        XCTAssertEqual(dense.retainedFrameIDs.count, SweepFrameReducer.preferredFrameCount)
        XCTAssertTrue(dense.retainedFrameIDs.contains(center.id))
        XCTAssertTrue(dense.retainedFrameIDs.contains(edge.id), "A view extending the field must not be retired.")
        XCTAssertTrue(dense.retainedFrameIDs.contains(try XCTUnwrap(frames.last).id))
        XCTAssertEqual(dense.coverage.fraction, original.coverage.fraction, accuracy: 1e-10)
        XCTAssertEqual(Set(dense.alignments.keys), dense.retainedFrameIDs)
        let retained = frames.filter { dense.retainedFrameIDs.contains($0.id) }
        let next = try await assembler.update(sessionID: session, plan: plan, frames: retained)
        XCTAssertEqual(next.coverage.fraction, dense.coverage.fraction, accuracy: 1e-10)
        let attempts = await registration.registeredSourceWidths()
        XCTAssertEqual(attempts.count, frames.count - 1, "Retained views must reuse their verified alignments.")
    }

    func testIncrementalPreviewMatchesFreshRenderingAndClearsRemovedFootprints() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let center = try fixture.frame(width: 240, height: 320)
        let right = try fixture.frame(width: 264, height: 352, yaw: 16)
        let transforms = [264: Homography3x3([1, 0, 0.45, 0, 1, 0, 0, 0, 1])]
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration(transforms: transforms))
        let session = UUID()
        let first = try await assembler.update(sessionID: session, plan: plan, frames: [center])
        let repeated = try await assembler.update(sessionID: session, plan: plan, frames: [center])
        XCTAssertTrue(first.preview === repeated.preview, "An unchanged sweep should reuse its rendered preview.")
        let appended = try await assembler.update(sessionID: session, plan: plan, frames: [center, right])
        let fresh = try await ProgressiveSweepAssembler(registration: CountingFrameRegistration(transforms: transforms))
            .update(sessionID: UUID(), plan: plan, frames: [center, right])
        // Compare in the preview's actual output space. Converting saturated
        // P3 colors to device RGB can amplify a one-level rounding difference.
        let outputSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let incrementalPixels = try RGBAImage(XCTUnwrap(appended.preview), colorSpace: outputSpace)
        let freshPixels = try RGBAImage(XCTUnwrap(fresh.preview), colorSpace: outputSpace)
        let differences = zip(incrementalPixels.pixels, freshPixels.pixels).map { abs(Int($0) - Int($1)) }
        let largestDifference = differences.max() ?? 0
        let offset = differences.firstIndex(of: largestDifference) ?? 0
        XCTAssertLessThanOrEqual(largestDifference, 3,
            "Caching must preserve colors, alpha, and softened seams: x=\((offset / 4) % incrementalPixels.width), "
            + "y=\((offset / 4) / incrementalPixels.width), channel=\(offset % 4), "
            + "cached=\(incrementalPixels.pixels[offset]), fresh=\(freshPixels.pixels[offset]).")
        let removed = try await assembler.update(sessionID: session, plan: plan, frames: [center])
        let removedPixels = try RGBAImage(XCTUnwrap(removed.preview), colorSpace: outputSpace)
        let firstPixels = try RGBAImage(XCTUnwrap(first.preview), colorSpace: outputSpace)
        XCTAssertTrue(removedPixels.pixels == firstPixels.pixels, "A retired view must not remain in the cached composite.")
        let x = Int(Double(incrementalPixels.width) * 0.85)
        XCTAssertGreaterThan(incrementalPixels.pixel(x: x, y: 280).alpha, 240)
        XCTAssertEqual(removedPixels.pixel(x: x, y: 280).alpha, 0)
    }

    func testRejectedViewIsNotRetriedWhenOnlyDistantReferencesChange() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = CountingFrameRegistration(rejectedWidths: [264])
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let anchor = try fixture.frame(width: 240, height: 320)
        let near = try fixture.frame(width: 252, height: 336, yaw: 2)
        let next = try fixture.frame(width: 276, height: 368, yaw: 4)
        let rejected = try fixture.frame(width: 264, height: 352, yaw: 6)
        let original = [anchor, near, next, rejected]
        _ = try await assembler.update(sessionID: session, plan: plan, frames: original)
        let before = await registration.registeredSourceWidths().filter { $0 == 264 }.count
        XCTAssertEqual(before, 3)

        let distant = try fixture.frame(width: 288, height: 384, yaw: -8)
        let update = try await assembler.update(sessionID: session, plan: plan, frames: original + [distant])
        XCTAssertNotNil(update.alignments[distant.id])
        XCTAssertTrue(update.rejectedFrameIDs.contains(rejected.id))
        let after = await registration.registeredSourceWidths().filter { $0 == 264 }.count
        XCTAssertEqual(after, before, "The same three failed reference images must not be tried again.")
    }

    func testNeighborDisagreementRejectsAnOtherwiseLocallyMatchedView() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let center = try fixture.frame(width: 240, height: 320)
        let right = try fixture.frame(width: 264, height: 352, yaw: 8)
        let farther = try fixture.frame(width: 288, height: 384, yaw: 12)
        let registration = InconsistentNeighborRegistration()
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let before = try await assembler.update(sessionID: session, plan: makePlan(), frames: [center, right])
        let after = try await assembler.update(sessionID: session, plan: makePlan(), frames: [center, right, farther])
        XCTAssertNil(after.alignments[farther.id])
        XCTAssertNil(after.polygonsByFrame[farther.id])
        XCTAssertTrue(after.rejectedFrameIDs.contains(farther.id))
        XCTAssertTrue(after.retainedFrameIDs.contains(farther.id))
        XCTAssertEqual(after.coverage.fraction, before.coverage.fraction, accuracy: 1e-12)
        let checked = await registration.checkedWidths()
        XCTAssertEqual(Set(checked), [240, 264], "Both candidate paths must be checked against their other neighbor.")
    }

    func testProvisionalRejectIsRetainedAndRecoversThroughNewBridgeImage() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = BridgingFrameRegistration()
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let session = UUID()
        let anchor = try fixture.frame(width: 240, height: 320)
        let disconnected = try fixture.frame(width: 264, height: 352, yaw: 16)
        let bridge = try fixture.frame(width: 288, height: 384, yaw: 8)

        let center = try await assembler.update(sessionID: session, plan: plan, frames: [anchor])
        let blocked = try await assembler.update(sessionID: session, plan: plan, frames: [anchor, disconnected])
        XCTAssertEqual(blocked.rejectedFrameIDs, [disconnected.id])
        XCTAssertNil(blocked.alignments[disconnected.id])
        XCTAssertEqual(blocked.coverage.fraction, center.coverage.fraction, accuracy: 1e-12)
        XCTAssertTrue(blocked.retainedFrameIDs.contains(disconnected.id),
                      "A source awaiting a visual bridge must remain available for another chance.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: disconnected.fileURL.path))

        let recovered = try await assembler.update(sessionID: session, plan: plan,
            frames: [anchor, disconnected, bridge])
        XCTAssertEqual(Set(recovered.alignments.keys), [anchor.id, disconnected.id, bridge.id])
        XCTAssertEqual(Set(recovered.polygonsByFrame.keys), [anchor.id, disconnected.id, bridge.id])
        XCTAssertTrue(recovered.rejectedFrameIDs.isEmpty)
        XCTAssertTrue(recovered.retainedFrameIDs.contains(disconnected.id))
        XCTAssertGreaterThan(recovered.coverage.fraction, blocked.coverage.fraction)
        let alignment = try XCTUnwrap(recovered.alignments[disconnected.id])
        let mappedCenter = try XCTUnwrap(Homography3x3(alignment.normalizedHomography)
            .transform(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertEqual(mappedCenter.x, 0.6, accuracy: 1e-10,
                       "B must compose its new alignment through C into the anchored target field.")
        XCTAssertEqual(mappedCenter.y, 0.5, accuracy: 1e-10)

        _ = try await assembler.update(sessionID: session, plan: plan,
            frames: [anchor, disconnected, bridge])
        let attempts = await registration.attempts()
        XCTAssertEqual(attempts, ["264 -> 240", "288 -> 240", "264 -> 288"],
                       "B fails against A; C connects to A; then cached B gets its chance against C.")
    }

    func testNewSessionClearsCachedRegistrationEvenWhenFrameIDsAreReused() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = CountingFrameRegistration()
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let center = try fixture.frame(width: 240, height: 320)
        let other = try fixture.frame(width: 264, height: 352, yaw: 8)
        _ = try await assembler.update(sessionID: UUID(), plan: plan, frames: [center, other])
        let nextSession = UUID()
        let next = try await assembler.update(sessionID: nextSession, plan: plan, frames: [center, other])
        let sources = await registration.registeredSourceWidths()
        XCTAssertEqual(sources, [264, 264])
        XCTAssertEqual(next.sessionID, nextSession)
        XCTAssertEqual(next.frameIDs, [center.id, other.id])
    }

    func testGyroscopeCoverageCannotCompleteWithoutVisualAlignments() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        var frames = [try fixture.frame(width: 240, height: 320)]
        for pitch in [-32.0, 0, 32] {
            for yaw in [-32.0, 0, 32] where yaw != 0 || pitch != 0 {
                frames.append(try fixture.frame(width: 264, height: 352, yaw: yaw, pitch: pitch))
            }
        }
        let angular = CoverageTracker(plan: plan, frames: frames)
        XCTAssertTrue(angular.isComplete, "The fixture deliberately covers the whole field in motion space.")
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration(rejectAll: true))
        let result = try await assembler.update(sessionID: UUID(), plan: plan, frames: frames)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertLessThan(result.coverage.fraction, 0.3)
        XCTAssertEqual(result.alignments.count, 1)
        XCTAssertEqual(result.rejectedFrameIDs.count, frames.count - 1)
    }

    func testPreviewKeepsMissingAreasTransparentAndSourceOrientation() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let frame = try fixture.frame(width: 240, height: 320)
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration())
        let update = try await assembler.update(sessionID: UUID(), plan: makePlan(), frames: [frame])
        let preview = try XCTUnwrap(update.preview)
        XCTAssertEqual(preview.width, 420)
        XCTAssertEqual(preview.height, 560)
        let pixels = try RGBAImage(preview)
        XCTAssertEqual(pixels.pixel(x: 10, y: 10).alpha, 0,
                       "Missing borders must remain transparent rather than fabricated.")
        let top = pixels.pixel(x: preview.width * 40 / 100, y: preview.height * 35 / 100)
        let bottom = pixels.pixel(x: preview.width * 40 / 100, y: preview.height * 65 / 100)
        let topRight = pixels.pixel(x: preview.width * 60 / 100, y: preview.height * 35 / 100)
        let bottomRight = pixels.pixel(x: preview.width * 60 / 100, y: preview.height * 65 / 100)
        XCTAssertGreaterThan(top.red, 200)
        XCTAssertLessThan(top.blue, 50)
        XCTAssertGreaterThan(bottom.blue, 200)
        XCTAssertLessThan(bottom.red, 50)
        XCTAssertGreaterThan(topRight.green, 200)
        XCTAssertLessThan(topRight.red, 50)
        XCTAssertGreaterThan(bottomRight.red, 200)
        XCTAssertGreaterThan(bottomRight.green, 200)
        XCTAssertLessThan(bottomRight.blue, 50)
        XCTAssertEqual(top.alpha, 255)
        XCTAssertEqual(bottom.alpha, 255)
        XCTAssertFalse(update.coverage.isComplete)
    }

    func testLinearExposureDifferencesAreCompensatedWithoutChangingPreviewColors() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        for scale in [0.5, 2.0] {
            let anchor = try fixture.photometricFrame(linearScale: 1)
            let changed = try fixture.photometricFrame(linearScale: scale, yaw: 8)
            let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration())
            let session = UUID()
            let before = try await assembler.update(sessionID: session, plan: plan, frames: [anchor])
            let after = try await assembler.update(sessionID: session, plan: plan, frames: [anchor, changed])
            let gain = try XCTUnwrap(after.alignments[changed.id]?.luminanceGain)
            XCTAssertEqual(gain, 1 / scale, accuracy: 0.06,
                           "Compensation must estimate the linear-light ratio, not a gamma-encoded RGB ratio.")
            XCTAssertEqual(after.alignments[anchor.id]?.luminanceGain, 1)

            let previewBefore = try XCTUnwrap(before.preview)
            let previewAfter = try XCTUnwrap(after.preview)
            let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
            let original = try RGBAImage(previewBefore, colorSpace: colorSpace)
                .pixel(x: previewBefore.width / 2, y: previewBefore.height / 2)
            let corrected = try RGBAImage(previewAfter, colorSpace: colorSpace)
                .pixel(x: previewAfter.width / 2, y: previewAfter.height / 2)
            for (actual, expected) in [(corrected.red, original.red),
                                       (corrected.green, original.green),
                                       (corrected.blue, original.blue)] {
                XCTAssertEqual(Double(actual), Double(expected), accuracy: 4,
                               "An exposure change must not produce a visible brightness or color step in the overlap.")
            }
            XCTAssertEqual(corrected.alpha, 255)
        }
    }

    func testClippedAndBlackPixelsDoNotBiasOverlapExposureGain() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let anchor = try fixture.photometricFrame(linearScale: 1)
        // More than a quarter of the new image is invalid for exposure
        // estimation. Its remaining corresponding pixels are exactly half as
        // bright in linear light.
        let changed = try fixture.photometricFrame(linearScale: 0.5, yaw: 8,
                                                    invalidExposurePatches: true)
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration())
        let result = try await assembler.update(sessionID: UUID(), plan: makePlan(), frames: [anchor, changed])
        XCTAssertNotNil(result.alignments[changed.id], "Photometric outliers cannot invalidate a verified geometric alignment.")
        let gain = try XCTUnwrap(result.alignments[changed.id]?.luminanceGain)
        XCTAssertEqual(gain, 2, accuracy: 0.08,
                       "Black and saturated patches must not pull the estimated gain toward their invalid ratios.")
    }

    func testExposureGainUsesOnlyTheGeometricallyAlignedOverlap() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let anchor = try fixture.photometricFrame(linearScale: 1, flatColor: true)
        let moved = try fixture.photometricFrame(linearScale: 0.5, yaw: 20,
                                                  flatColor: true, nonoverlappingBrightHalf: true)
        let registration = CountingFrameRegistration(transforms: [
            240: Homography3x3([1, 0, 0.5, 0, 1, 0, 0, 0, 1])
        ])
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let result = try await assembler.update(sessionID: UUID(), plan: makePlan(), frames: [anchor, moved])
        let alignment = try XCTUnwrap(result.alignments[moved.id])
        XCTAssertEqual(alignment.luminanceGain, 2, accuracy: 0.06,
                       "The bright half outside the matching footprint describes a different scene and must not affect compensation.")
    }

    func testUnmeasurableExposureKeepsTheMatchedReferenceCorrection() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let anchor = try fixture.photometricFrame(linearScale: 1)
        let darker = try fixture.photometricFrame(linearScale: 0.5, yaw: 8)
        let clipped = try fixture.photometricFrame(linearScale: 100, yaw: 16)
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration())
        let result = try await assembler.update(sessionID: UUID(), plan: makePlan(), frames: [anchor, darker, clipped])
        let inherited = try XCTUnwrap(result.alignments[darker.id]?.luminanceGain)
        XCTAssertEqual(inherited, 2, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(result.alignments[clipped.id]?.luminanceGain), inherited,
                       "An unmeasurable overlap must not reset the inherited correction to unity.")
    }

    func testPreviewFeathersSourceEdgesAndKeepsItsInteriorOpaque() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let frame = try fixture.photometricFrame(linearScale: 1)
        let assembler = ProgressiveSweepAssembler(registration: CountingFrameRegistration())
        let update = try await assembler.update(sessionID: UUID(), plan: makePlan(), frames: [frame])
        let preview = try XCTUnwrap(update.preview)
        let alignment = try XCTUnwrap(update.alignments[frame.id])
        let transform = Homography3x3(alignment.normalizedHomography)
        let featherPoint = try XCTUnwrap(transform.transform(CGPoint(x: 0.008, y: 0.5)))
        let interiorPoint = try XCTUnwrap(transform.transform(CGPoint(x: 0.08, y: 0.5)))
        let pixels = try RGBAImage(preview)
        let edge = pixels.pixel(x: Int(featherPoint.x * Double(preview.width)),
                                y: Int(featherPoint.y * Double(preview.height)))
        let interior = pixels.pixel(x: Int(interiorPoint.x * Double(preview.width)),
                                    y: Int(interiorPoint.y * Double(preview.height)))
        XCTAssertGreaterThan(edge.alpha, 0)
        XCTAssertLessThan(edge.alpha, 240,
                          "The source boundary needs a soft transition instead of an opaque rectangular replacement.")
        XCTAssertEqual(interior.alpha, 255)
    }

    func testChangedSessionRejectsAnOldRegistrationResumingLater() async throws {
        let fixture = try ProgressiveFixture()
        defer { fixture.remove() }
        let plan = try makePlan()
        let registration = SuspendingFrameRegistration()
        let assembler = ProgressiveSweepAssembler(registration: registration)
        let center = try fixture.frame(width: 240, height: 320)
        let other = try fixture.frame(width: 264, height: 352, yaw: 8)
        let oldTask = Task {
            try await assembler.update(sessionID: UUID(), plan: plan, frames: [center, other])
        }
        for _ in 0..<200 {
            if await registration.isPending() { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let pending = await registration.isPending()
        XCTAssertTrue(pending)
        let nextSession = UUID()
        let next = try await assembler.update(sessionID: nextSession, plan: plan, frames: [center])
        await registration.resume()
        do {
            _ = try await oldTask.value
            XCTFail("A previous session returned an update after its registration resumed.")
        } catch is CancellationError {
            // Expected: the stale worker cannot reintroduce old image footprints.
        }
        XCTAssertEqual(next.sessionID, nextSession)
        XCTAssertEqual(Set(next.alignments.keys), [center.id])
        let current = try await assembler.update(sessionID: nextSession, plan: plan, frames: [center])
        XCTAssertEqual(Set(current.alignments.keys), [center.id])
        XCTAssertFalse(current.frameIDs.contains(other.id))
    }

    private func makePlan() throws -> CapturePlan {
        try XCTUnwrap(CapturePlan.make(lens: .wide, target: .half, orientation: .portrait,
            wideHorizontalFOV: 75, lensHorizontalFOV: 75, sourceLandscapeAspectRatio: 4.0 / 3.0))
    }

    private func projectedPitch(eulerPitch: Double, yaw: Double) -> Double {
        atan(tan(eulerPitch * .pi / 180) / cos(yaw * .pi / 180)) * 180 / .pi
    }

    /// Physical pinhole projection from the fixture generator's Euler poses.
    /// This is used only to seed a visually known reference for the regression.
    private func physicalProjection(yaw: Double, eulerPitch: Double, roll: Double,
                                    plan: CapturePlan) -> Homography3x3 {
        let y = yaw * .pi / 180, p = eulerPitch * .pi / 180, r = roll * .pi / 180
        let sourceIntrinsics = Homography3x3([
            1 / (2 * tan(plan.sourceHorizontalFOV * .pi / 360)), 0, 0.5,
            0, 1 / (2 * tan(plan.sourceVerticalFOV * .pi / 360)), 0.5, 0, 0, 1
        ])
        let targetIntrinsics = Homography3x3([
            1 / (2 * tan(plan.targetHorizontalFOV * .pi / 360)), 0, 0.5,
            0, 1 / (2 * tan(plan.targetVerticalFOV * .pi / 360)), 0.5, 0, 0, 1
        ])
        let rz = Homography3x3([cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1])
        let rx = Homography3x3([1, 0, 0, 0, cos(p), -sin(p), 0, sin(p), cos(p)])
        let ry = Homography3x3([cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)])
        return sourceIntrinsics.inverted()!.concatenating(rz).concatenating(rx)
            .concatenating(ry).concatenating(targetIntrinsics)
    }

    /// Direct ray equations independently check every predicted corner,
    /// including roll; the expected values do not use the assembler's prior.
    private func projectRay(_ point: CGPoint, yaw: Double, eulerPitch: Double, roll: Double,
                            plan: CapturePlan) -> CGPoint {
        let y = yaw * .pi / 180, p = eulerPitch * .pi / 180, r = roll * .pi / 180
        let rayX = (2 * Double(point.x) - 1) * tan(plan.sourceHorizontalFOV * .pi / 360)
        let rayY = (2 * Double(point.y) - 1) * tan(plan.sourceVerticalFOV * .pi / 360)
        let rx = rayX * cos(r) - rayY * sin(r)
        let ry = rayX * sin(r) + rayY * cos(r)
        let x = rx * cos(y) + (ry * sin(p) + cos(p)) * sin(y)
        let vertical = ry * cos(p) - sin(p)
        let depth = -rx * sin(y) + (ry * sin(p) + cos(p)) * cos(y)
        return CGPoint(x: (x / depth / tan(plan.targetHorizontalFOV * .pi / 360) + 1) / 2,
                       y: (vertical / depth / tan(plan.targetVerticalFOV * .pi / 360) + 1) / 2)
    }
}

private actor InconsistentNeighborRegistration: FrameRegistration {
    private var checked: [Int] = []

    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration {
        VisualRegistration(homography: .identity, overlapFraction: 0.9, visualAgreement: 0.95)
    }

    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws {
        checked.append(reference.cgImage.width)
        throw VisualRegistrationFailure.inconsistentContent
    }

    func checkedWidths() -> [Int] { checked }
}

private actor CountingFrameRegistration: FrameRegistration {
    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws { }
    private let transforms: [Int: Homography3x3]
    private let rejectAll: Bool
    private let rejectedWidths: Set<Int>
    private var sources: [Int] = []

    init(transforms: [Int: Homography3x3] = [:], rejectAll: Bool = false, rejectedWidths: Set<Int> = []) {
        self.transforms = transforms
        self.rejectAll = rejectAll
        self.rejectedWidths = rejectedWidths
    }

    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration {
        sources.append(source.cgImage.width)
        if rejectAll || rejectedWidths.contains(source.cgImage.width) { throw VisualRegistrationFailure.noAlignment }
        return VisualRegistration(homography: transforms[source.cgImage.width] ?? .identity,
                                  overlapFraction: 0.8, visualAgreement: 1)
    }

    func registeredSourceWidths() -> [Int] { sources }
}

private actor BridgingFrameRegistration: FrameRegistration {
    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws { }
    private var pairs: [String] = []

    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration {
        let sourceWidth = source.cgImage.width, referenceWidth = reference.cgImage.width
        pairs.append("\(sourceWidth) -> \(referenceWidth)")
        guard (sourceWidth == 288 && referenceWidth == 240) ||
              (sourceWidth == 264 && referenceWidth == 288) else {
            throw VisualRegistrationFailure.noAlignment
        }
        return VisualRegistration(homography: Homography3x3([1, 0, 0.1, 0, 1, 0, 0, 0, 1]),
                                  overlapFraction: 0.8, visualAgreement: 1)
    }

    func attempts() -> [String] { pairs }
}

private actor SuspendingFrameRegistration: FrameRegistration {
    func validate(source: RegistrationImage, reference: RegistrationImage,
                  homography: Homography3x3) async throws { }
    private var continuation: CheckedContinuation<Void, Never>?

    func register(source: RegistrationImage, reference: RegistrationImage) async throws -> VisualRegistration {
        await withCheckedContinuation { continuation = $0 }
        return VisualRegistration(homography: .identity, overlapFraction: 1, visualAgreement: 1)
    }

    func isPending() -> Bool { continuation != nil }
    func resume() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }
}

private struct ProgressiveFixture {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    func photometricFrame(linearScale: Double, yaw: Double = 0,
                          invalidExposurePatches: Bool = false, flatColor: Bool = false,
                          nonoverlappingBrightHalf: Bool = false) throws -> CapturedFrame {
        let width = 240, height = 320
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let colors: [[Double]] = [
            [0.12, 0.24, 0.08], [0.08, 0.12, 0.28],
            [0.25, 0.08, 0.16], [0.18, 0.22, 0.12]
        ]
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let patch = ((x / 30) + 3 * (y / 40)) % colors.count
                // Keep a large, uniform colored region around the sample used
                // to independently check the rendered preview.
                let color = flatColor || (abs(x - width / 2) < 24 && abs(y - height / 2) < 32)
                    ? colors[0] : colors[patch]
                for channel in 0..<3 {
                    let linear = nonoverlappingBrightHalf && x >= width / 2
                        ? [0.7, 0.5, 0.6][channel] : color[channel] * linearScale
                    let encoded = linear <= 0.0031308 ? 12.92 * linear
                        : 1.055 * pow(linear, 1 / 2.4) - 0.055
                    rgba[offset + channel] = UInt8((min(1, max(0, encoded)) * 255).rounded())
                }
                if invalidExposurePatches && y < height / 3 {
                    let invalid: UInt8 = x < width / 2 ? 0 : 255
                    for channel in 0..<3 { rgba[offset + channel] = invalid }
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let id = UUID(), url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return CapturedFrame(id: id, slotID: id.uuidString, fileURL: url, pass: 0, capturedAt: Date(),
            yawDegrees: yaw, pitchDegrees: 0, rollDegrees: 0,
            sharpnessScore: 20, meanBrightness: 0.5, quality: .good)
    }

    func frame(width: Int, height: Int, yaw: Double = 0, pitch: Double = 0, roll: Double = 0) throws -> CapturedFrame {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let top = y < height / 2, left = x < width / 2
                rgba[offset] = (top && left) || (!top && !left) ? 255 : 0
                rgba[offset + 1] = left ? 0 : 255
                rgba[offset + 2] = !top && left ? 255 : 0
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image,
            [kCGImageDestinationLossyCompressionQuality: 0.98] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return CapturedFrame(id: id, slotID: id.uuidString, fileURL: url, pass: 0, capturedAt: Date(),
            yawDegrees: yaw, pitchDegrees: pitch, rollDegrees: roll,
            sharpnessScore: 20, meanBrightness: 0.5, quality: .good)
    }
}

private struct RGBAImage {
    let width: Int
    let pixels: [UInt8]

    init(_ image: CGImage, colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws {
        width = image.width
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.pixels = pixels
    }

    func pixel(x: Int, y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let offset = (y * width + x) * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3])
    }
}
