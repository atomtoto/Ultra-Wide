import XCTest
@testable import UltraWide

@MainActor
final class CaptureSessionStoreTests: XCTestCase {
    private func snapshot() throws -> CaptureSessionSnapshot {
        let plan = try XCTUnwrap(CapturePlan.make(
            lens: .wide, target: .half, wideHorizontalFOV: 75, lensHorizontalFOV: 75
        ))
        return CaptureSessionSnapshot(
            sessionID: UUID(), plan: plan, slots: [], currentPass: 1, isPassOpen: true,
            retakeCount: 0, coverageFraction: 0, createdAt: Date(), updatedAt: Date()
        )
    }

    func testAsyncPhotoAndManifestCanBeRecoveredTogether() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        var saved = try snapshot()
        try store.create(saved)
        let id = UUID()
        let data = Data([0xff, 0xd8, 0xff, 0xd9])
        let url = try await store.writePhoto(data, id: id, sessionID: saved.sessionID)
        XCTAssertEqual(url, store.photoURL(id: id))
        let frame = CapturedFrame(
            id: id, slotID: id.uuidString, fileURL: url, pass: 1, capturedAt: Date(),
            yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0, sharpnessScore: 50,
            meanBrightness: 0.5, quality: .good
        )
        saved.slots.append(CaptureSlot(id: frame.slotID, row: 1, column: 1,
                                      yawDegrees: 0, pitchDegrees: 0, frame: frame))
        try await store.saveAsync(saved)
        let recovered = try CaptureSessionStore(rootURL: folder).load()
        XCTAssertEqual(recovered.frames, [frame])
        XCTAssertEqual(try Data(contentsOf: recovered.frames[0].fileURL), data)
    }

    func testRetiredWriterCannotOverwriteReplacementSession() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CaptureSessionStore(rootURL: folder)
        let retired = try snapshot()
        try store.create(retired)
        store.discard()
        let fresh = try snapshot()
        try store.create(fresh)
        let id = UUID()
        do {
            _ = try await store.writePhoto(Data([0xff, 0xd8]), id: id, sessionID: retired.sessionID)
            XCTFail("Retired image entered the new session")
        } catch { }
        do {
            try await store.saveAsync(retired)
            XCTFail("Retired metadata replaced the new session")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL(id: id).path))
        XCTAssertEqual(try store.load().sessionID, fresh.sessionID)
    }
}
