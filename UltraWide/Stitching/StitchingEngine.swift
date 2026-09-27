import Foundation

/// A still captured during one guided sweep. Angles, when available, are in radians.
public struct StitchInput: Sendable {
    public let url: URL
    public let yawRadians: Double?
    public let pitchRadians: Double?
    public let rollRadians: Double?

    public init(
        url: URL,
        yawRadians: Double? = nil,
        pitchRadians: Double? = nil,
        rollRadians: Double? = nil
    ) {
        self.url = url
        self.yawRadians = yawRadians
        self.pitchRadians = pitchRadians
        self.rollRadians = rollRadians
    }
}

public struct StitchResult: Sendable {
    public let imageURL: URL
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let usedFrameIndices: [Int]
    public let rejectedFrameIndices: [Int]
}

public enum StitchingFailure: Error, LocalizedError, Sendable {
    case insufficientImages
    case unreadableImage
    case insufficientOverlap(rejectedIndices: [Int])
    case invalidGeometry
    case incompleteCoverage(rejectedIndices: [Int])
    case exportFailed(String)
    case cancelled
    case unsupportedPlatform
    case unknown(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientImages: String(localized: "At least two photos are needed to assemble an image.")
        case .unreadableImage: String(localized: "One of the photos could not be opened.")
        case .insufficientOverlap: String(localized: "Some photos do not overlap enough. Retake the indicated views.")
        case .invalidGeometry: String(localized: "The photos could not be aligned reliably. Try a steadier sweep.")
        case .incompleteCoverage: String(localized: "The sweep does not cover the requested image. Capture the missing edges.")
        case .exportFailed(let reason): reason
        case .cancelled: String(localized: "Assembly was cancelled.")
        case .unsupportedPlatform: String(localized: "Photo assembly requires an iPhone.")
        case .unknown(let message): message
        }
    }

    init(_ error: NSError) {
        guard error.domain == UWStitcherErrorDomain else {
            self = .unknown(error.localizedDescription)
            return
        }
        let rejected = error.userInfo[UWStitcherRejectedIndexesKey] as? [Int] ?? []
        switch error.code {
        case UWStitcherErrorCode.insufficientImages.rawValue: self = .insufficientImages
        case UWStitcherErrorCode.unreadableImage.rawValue: self = .unreadableImage
        case UWStitcherErrorCode.insufficientOverlap.rawValue: self = .insufficientOverlap(rejectedIndices: rejected)
        case UWStitcherErrorCode.invalidGeometry.rawValue: self = .invalidGeometry
        case UWStitcherErrorCode.incompleteCoverage.rawValue: self = .incompleteCoverage(rejectedIndices: rejected)
        case UWStitcherErrorCode.exportFailed.rawValue: self = .exportFailed(error.localizedDescription)
        case UWStitcherErrorCode.cancelled.rawValue: self = .cancelled
        case UWStitcherErrorCode.unsupportedPlatform.rawValue: self = .unsupportedPlatform
        default: self = .unknown(error.localizedDescription)
        }
    }
}

/// Serializes assembly jobs and keeps the heavy native work off the main actor.
public actor StitchingEngine {
    public init() {}

    public func stitch(
        inputs: [StitchInput],
        outputURL: URL,
        maximumMegapixels: Int = 48,
        targetAspectRatio: Double? = nil,
        minimumHorizontalFOVDegrees: Double? = nil,
        minimumVerticalFOVDegrees: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) throws -> StitchResult {
        guard inputs.count >= 2 else { throw StitchingFailure.insufficientImages }
        guard !Task<Never, Never>.isCancelled else { throw StitchingFailure.cancelled }

        let frames = inputs.map { input in
            UWStitchFrame(
                url: input.url,
                yawRadians: input.yawRadians ?? 0,
                pitchRadians: input.pitchRadians ?? 0,
                rollRadians: input.rollRadians ?? 0,
                hasMotion: input.yawRadians != nil && input.pitchRadians != nil
            )
        }
        let outcome: UWStitchOutcome
        do {
            outcome = try UWStitcher.stitchFrames(
                frames,
                outputURL: outputURL,
                maximumMegapixels: maximumMegapixels,
                targetAspectRatio: targetAspectRatio ?? 0,
                minimumHorizontalFOVDegrees: minimumHorizontalFOVDegrees ?? 0,
                minimumVerticalFOVDegrees: minimumVerticalFOVDegrees ?? 0,
                progress: { fraction in
                    progress(fraction)
                    return !Task<Never, Never>.isCancelled
                }
            )
        } catch {
            throw StitchingFailure(error as NSError)
        }
        return StitchResult(
            imageURL: outcome.imageURL,
            pixelWidth: outcome.pixelWidth,
            pixelHeight: outcome.pixelHeight,
            usedFrameIndices: outcome.usedFrameIndexes.map(\.intValue),
            rejectedFrameIndices: outcome.rejectedFrameIndexes.map(\.intValue)
        )
    }
}
