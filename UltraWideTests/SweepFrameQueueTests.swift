import XCTest
@testable import UltraWide

@MainActor
final class SweepFrameQueueTests: XCTestCase {
    private func frame() -> CapturedFrame {
        let id = UUID()
        return CapturedFrame(
            id: id, slotID: id.uuidString,
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(id).jpg"),
            pass: 1, capturedAt: Date(), yawDegrees: 0, pitchDegrees: 0, rollDegrees: 0,
            sharpnessScore: 100, meanBrightness: 0.5, quality: .good
        )
    }

    func testSlowWriterDoesNotBlockSelectionAndHasFixedMemoryBound() async throws {
        let queue = SweepFrameQueue()
        let gate = WriterGate()
        let started = expectation(description: "Writer started")
        var written: [UUID] = []
        let frames = (0..<3).map { _ in frame() }
        let first = try XCTUnwrap(queue.enqueue(frames[0]) {
            started.fulfill()
            await gate.wait()
            written.append(frames[0].id)
            return frames[0]
        })
        await fulfillment(of: [started], timeout: 1)
        // The first JPEG is deliberately stalled. Two more camera buffers
        // can already be selected and contribute to live coverage.
        for frame in frames.dropFirst() {
            XCTAssertNotNil(queue.enqueue(frame) { written.append(frame.id); return frame })
        }
        XCTAssertEqual(Set(queue.frames.map(\.id)), Set(frames.map(\.id)))
        XCTAssertTrue(queue.isFull)
        XCTAssertNil(queue.enqueue(frame()) { XCTFail("Queue exceeded its capacity"); return nil })
        XCTAssertTrue(written.isEmpty)
        gate.open()
        _ = await first.value
        await queue.drain()
        XCTAssertEqual(written, frames.map(\.id))
        XCTAssertEqual(queue.count, 0)
    }

    func testCancellingOldSweepDoesNotDelayOrMutateNewSweep() async throws {
        let queue = SweepFrameQueue()
        let gate = WriterGate()
        let started = expectation(description: "Old writer started")
        let oldFrame = frame()
        let old = try XCTUnwrap(queue.enqueue(oldFrame) {
            started.fulfill()
            await gate.wait()
            return oldFrame
        })
        await fulfillment(of: [started], timeout: 1)
        var retiredWriteRan = false
        XCTAssertNotNil(queue.enqueue(frame()) { retiredWriteRan = true; return nil })
        queue.cancel()
        let nextFrame = frame()
        let next = try XCTUnwrap(queue.enqueue(nextFrame) { nextFrame })
        let result = await next.value
        XCTAssertEqual(result?.id, nextFrame.id)
        XCTAssertEqual(queue.count, 0)
        gate.open()
        _ = await old.value
        await Task.yield()
        XCTAssertFalse(retiredWriteRan)
        XCTAssertEqual(queue.count, 0)
    }
}

@MainActor
private final class WriterGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
