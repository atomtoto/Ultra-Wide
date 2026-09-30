import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

@MainActor
final class CaptureSessionStore {
    private let rootURL: URL
    private let manager = FileManager.default
    private let fileIO = CaptureFileIO()

    init(rootURL: URL? = nil) {
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.rootURL = rootURL ?? support.appendingPathComponent("UltraWideCapture", isDirectory: true)
    }

    private var currentURL: URL { rootURL.appendingPathComponent("current", isDirectory: true) }
    private var metadataURL: URL { currentURL.appendingPathComponent("session.json") }

    func create(_ snapshot: CaptureSessionSnapshot) throws {
        do {
            try fileIO.queue.sync {
                if manager.fileExists(atPath: currentURL.path) {
                    try manager.removeItem(at: currentURL)
                }
                try manager.createDirectory(at: currentURL, withIntermediateDirectories: true)
                fileIO.sessionID = snapshot.sessionID
            }
            try save(snapshot)
        } catch {
            throw CaptureError.diskWriteFailed
        }
    }

    func save(_ snapshot: CaptureSessionSnapshot) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try fileIO.queue.sync {
                guard fileIO.sessionID == snapshot.sessionID else { throw CaptureError.noSavedSession }
                try data.write(to: metadataURL, options: .atomic)
            }
        } catch {
            throw CaptureError.diskWriteFailed
        }
    }

    func photoURL(id: UUID) -> URL {
        currentURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    func writePhoto(_ data: Data, id: UUID, sessionID: UUID) async throws -> URL {
        let isJPEG = data.count >= 2 && data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
        let url = currentURL.appendingPathComponent("\(id.uuidString).\(isJPEG ? "jpg" : "heic")")
        let fileIO = fileIO
        return try await withCheckedThrowingContinuation { continuation in
            fileIO.queue.async {
                do {
                    guard fileIO.sessionID == sessionID else { throw CaptureError.noSavedSession }
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: url)
                } catch {
                    continuation.resume(throwing: CaptureError.diskWriteFailed)
                }
            }
        }
    }

    func saveAsync(_ snapshot: CaptureSessionSnapshot) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = metadataURL
        let fileIO = fileIO
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            fileIO.queue.async {
                do {
                    guard fileIO.sessionID == snapshot.sessionID else { throw CaptureError.noSavedSession }
                    try data.write(to: url, options: .atomic)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CaptureError.diskWriteFailed)
                }
            }
        }
    }

    func removePhoto(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == currentURL.standardizedFileURL else { return }
        fileIO.queue.sync { try? manager.removeItem(at: url) }
    }

    func load() throws -> CaptureSessionSnapshot {
        guard manager.fileExists(atPath: metadataURL.path) else {
            throw CaptureError.noSavedSession
        }
        do {
            var snapshot = try JSONDecoder().decode(
                CaptureSessionSnapshot.self,
                from: fileIO.queue.sync { try Data(contentsOf: metadataURL) }
            )
            fileIO.queue.sync { fileIO.sessionID = snapshot.sessionID }
            var needsPathUpdate = false
            for index in snapshot.slots.indices {
                guard let frame = snapshot.slots[index].frame else { continue }
                let name = frame.fileURL.lastPathComponent
                guard frame.slotID == snapshot.slots[index].id,
                      name == "\(frame.id.uuidString).heic" || name == "\(frame.id.uuidString).jpg" else {
                    throw CaptureError.corruptSavedSession
                }
                let resolved = currentURL.appendingPathComponent(name)
                guard manager.fileExists(atPath: resolved.path) else {
                    throw CaptureError.corruptSavedSession
                }
                if frame.fileURL.standardizedFileURL != resolved.standardizedFileURL {
                    needsPathUpdate = true
                    snapshot.slots[index].frame = CapturedFrame(
                        id: frame.id,
                        slotID: frame.slotID,
                        fileURL: resolved,
                        pass: frame.pass,
                        capturedAt: frame.capturedAt,
                        yawDegrees: frame.yawDegrees,
                        pitchDegrees: frame.pitchDegrees,
                        rollDegrees: frame.rollDegrees,
                        sharpnessScore: frame.sharpnessScore,
                        meanBrightness: frame.meanBrightness,
                        quality: frame.quality
                    )
                }
            }
            let isLegacyGrid = snapshot.coverageFraction == nil
            let centerID = "r\(snapshot.plan.rows / 2)c\(snapshot.plan.columns / 2)"
            let centerFrameExists = snapshot.slots.first { $0.id == centerID }?.frame != nil
            guard snapshot.slots.count <= 60,
                  Set(snapshot.slots.map(\.id)).count == snapshot.slots.count,
                  (!isLegacyGrid || snapshot.slots.count == snapshot.plan.expectedFrameCount),
                  (!isLegacyGrid || snapshot.frames.isEmpty || centerFrameExists),
                  (1...2).contains(snapshot.currentPass),
                  (0...60).contains(snapshot.retakeCount) else {
                throw CaptureError.corruptSavedSession
            }
            if isLegacyGrid {
                snapshot.coverageFraction = CoverageTracker(
                    plan: snapshot.plan, frames: snapshot.frames
                ).fraction
                needsPathUpdate = true
            }
            if needsPathUpdate { try? save(snapshot) }
            return snapshot
        } catch let error as CaptureError {
            throw error
        } catch {
            throw CaptureError.corruptSavedSession
        }
    }

    func discard() {
        fileIO.queue.sync {
            fileIO.sessionID = nil
            try? manager.removeItem(at: currentURL)
        }
    }
}

private final class CaptureFileIO: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.ultrawide.capture.files", qos: .userInitiated)
    // Accessed only on queue, including session replacement and discard.
    var sessionID: UUID?
}

struct PhotoQualityResult: Sendable {
    let sharpness: Double
    let brightness: Double
    let quality: CaptureQuality
}

enum PhotoQualityAnalyzer {
    /// Read a small luma grid directly from AVFoundation's buffer. There is
    /// no GPU render, image allocation or JPEG decode on the selection path.
    static func analyze(_ buffer: CVPixelBuffer) -> PhotoQualityResult {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let isLuma = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard isLuma || format == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let scale = min(1, 192 / Double(max(sourceWidth, sourceHeight)))
        let width = Int(Double(sourceWidth) * scale)
        let height = Int(Double(sourceHeight) * scale)
        let address = isLuma ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
            : CVPixelBufferGetBaseAddress(buffer)
        guard width >= 5, height >= 5, let address else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }
        let stride = isLuma ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            : CVPixelBufferGetBytesPerRow(buffer)
        let source = address.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = min(sourceHeight - 1, (2 * y + 1) * sourceHeight / (2 * height)) * stride
            for x in 0..<width {
                let column = min(sourceWidth - 1, (2 * x + 1) * sourceWidth / (2 * width))
                if isLuma {
                    let value = Int(source[row + column])
                    pixels[y * width + x] = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        ? UInt8(clamping: (value - 16) * 255 / 219) : UInt8(value)
                } else {
                    let index = row + column * 4
                    pixels[y * width + x] = UInt8((29 * Int(source[index])
                        + 150 * Int(source[index + 1]) + 77 * Int(source[index + 2])) >> 8)
                }
            }
        }
        return analyze(pixels, width: width, height: height)
    }

    static func analyze(_ data: Data) -> PhotoQualityResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 192,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }
        return analyze(image)
    }

    static func analyze(_ image: CGImage) -> PhotoQualityResult {
        let scale = min(1, 192 / Double(max(image.width, image.height)))
        let width = Int((Double(image.width) * scale).rounded())
        let height = Int((Double(image.height) * scale).rounded())
        guard width >= 5, height >= 5 else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }

        return analyze(pixels, width: width, height: height)
    }

    private static func analyze(_ pixels: [UInt8], width: Int, height: Int) -> PhotoQualityResult {
        let count = Double(width * height)
        let brightness = pixels.reduce(0.0) { $0 + Double($1) } / count
        let contrast = pixels.reduce(0.0) {
            let difference = Double($1) - brightness
            return $0 + difference * difference
        } / count
        var laplacianEnergy = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let index = y * width + x
                let laplacian = 4 * Int(pixels[index])
                    - Int(pixels[index - 1]) - Int(pixels[index + 1])
                    - Int(pixels[index - width]) - Int(pixels[index + width])
                laplacianEnergy += Double(laplacian * laplacian)
            }
        }
        let sharpness = laplacianEnergy / Double((width - 2) * (height - 2))
        let quality: CaptureQuality
        if brightness < 24 {
            quality = .dark
        } else if contrast < 80 {
            quality = .unknown // a blank wall or sky has no measurable detail
        } else if sharpness < 45 {
            quality = .soft
        } else {
            quality = .good
        }
        return PhotoQualityResult(
            sharpness: sharpness,
            brightness: brightness / 255,
            quality: quality
        )
    }
}
