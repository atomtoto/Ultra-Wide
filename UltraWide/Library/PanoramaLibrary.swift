import SwiftUI
import Photos

struct SavedPanorama: Codable, Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let width: Int
    let height: Int
    let frameCount: Int
    let lensName: String
    let isDemo: Bool
    var megapixels: String { String(format: "%.1f MP", Double(width * height) / 1_000_000) }
}

@MainActor
final class PanoramaLibrary: ObservableObject {
    @Published private(set) var items: [SavedPanorama] = []
    @Published var errorMessage: String?
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.documentsDirectory.appending(path: "Panoramas", directoryHint: .isDirectory)
        Task { await reload() }
    }

    func url(for item: SavedPanorama) -> URL { directory.appending(path: "\(item.id.uuidString).jpg") }

    func reload() async {
        let directory = directory
        do {
            let loaded = try await Task.detached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                return files.filter { $0.pathExtension == "json" }.compactMap { url -> SavedPanorama? in
                    guard let data = try? Data(contentsOf: url), let item = try? JSONDecoder().decode(SavedPanorama.self, from: data),
                          FileManager.default.fileExists(atPath: directory.appending(path: "\(item.id.uuidString).jpg").path) else { return nil }
                    return item
                }.sorted { $0.createdAt > $1.createdAt }
            }.value
            // Merge items saved during disk loading instead of overwriting them.
            items = Dictionary((loaded + items).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }).values.sorted { $0.createdAt > $1.createdAt }
        } catch { errorMessage = error.localizedDescription }
    }

    func store(_ result: CaptureResult) async throws -> SavedPanorama {
        if let existing = items.first(where: { $0.id == result.id }) { return existing }
        let item = SavedPanorama(id: result.id, createdAt: .now, width: result.image.width, height: result.image.height,
                                 frameCount: result.image.frameCount, lensName: result.lensName, isDemo: result.isDemo)
        let directory = directory, data = result.image.jpeg
        try await Task.detached {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let imageURL = directory.appending(path: "\(item.id.uuidString).jpg")
            try data.write(to: imageURL, options: .atomic)
            do { try JSONEncoder().encode(item).write(to: directory.appending(path: "\(item.id.uuidString).json"), options: .atomic) }
            catch { try? FileManager.default.removeItem(at: imageURL); throw error }
        }.value
        if !items.contains(where: { $0.id == item.id }) { items.insert(item, at: 0) }
        return item
    }

    func delete(_ item: SavedPanorama) throws {
        // Remove the image first; reload ignores metadata without an image.
        try FileManager.default.removeItem(at: url(for: item))
        try? FileManager.default.removeItem(at: directory.appending(path: "\(item.id.uuidString).json"))
        items.removeAll { $0.id == item.id }
    }

    static func exportToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "Autorisez l’ajout à Photos dans Réglages. Votre image reste disponible dans la galerie de l’app."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }
    }
}
