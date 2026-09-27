import CoreGraphics
import Foundation
import ImageIO

@MainActor
final class CaptureSessionStore {
    private let rootURL: URL
    private let manager = FileManager.default

    init() {
        let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("UltraWideCapture", isDirectory: true)
    }

    private var currentURL: URL { rootURL.appendingPathComponent("current", isDirectory: true) }
    private var metadataURL: URL { currentURL.appendingPathComponent("session.json") }

    func create(_ snapshot: CaptureSessionSnapshot) throws {
        do {
            if manager.fileExists(atPath: currentURL.path) {
                try manager.removeItem(at: currentURL)
            }
            try manager.createDirectory(at: currentURL, withIntermediateDirectories: true)
            try save(snapshot)
        } catch {
            throw CaptureError.diskWriteFailed
        }
    }

    func save(_ snapshot: CaptureSessionSnapshot) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(snapshot).write(to: metadataURL, options: .atomic)
        } catch {
            throw CaptureError.diskWriteFailed
        }
    }

    func writePhoto(_ data: Data, id: UUID) throws -> URL {
        let isJPEG = data.count >= 2 && data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
        let url = currentURL.appendingPathComponent("\(id.uuidString).\(isJPEG ? "jpg" : "heic")")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            throw CaptureError.diskWriteFailed
        }
    }

    func removePhoto(at url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == currentURL.standardizedFileURL else { return }
        try? manager.removeItem(at: url)
    }

    func load() throws -> CaptureSessionSnapshot {
        guard manager.fileExists(atPath: metadataURL.path) else {
            throw CaptureError.noSavedSession
        }
        do {
            var snapshot = try JSONDecoder().decode(
                CaptureSessionSnapshot.self,
                from: Data(contentsOf: metadataURL)
            )
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
            let centerID = "r\(snapshot.plan.rows / 2)c\(snapshot.plan.columns / 2)"
            let centerFrameExists = snapshot.slots.first { $0.id == centerID }?.frame != nil
            guard snapshot.slots.count == snapshot.plan.expectedFrameCount,
                  (snapshot.frames.isEmpty || centerFrameExists),
                  (1...2).contains(snapshot.currentPass),
                  (0...6).contains(snapshot.retakeCount) else {
                throw CaptureError.corruptSavedSession
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
        try? manager.removeItem(at: currentURL)
    }
}

struct PhotoQualityResult: Sendable {
    let sharpness: Double
    let brightness: Double
    let quality: CaptureQuality
}

enum PhotoQualityAnalyzer {
    static func analyze(_ data: Data) -> PhotoQualityResult {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceThumbnailMaxPixelSize: 192,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else {
            return PhotoQualityResult(sharpness: 0, brightness: 0, quality: .unknown)
        }

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
