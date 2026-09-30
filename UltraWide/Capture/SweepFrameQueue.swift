import Foundation

/// Retain selected camera buffers while their JPEGs are saved. Selection can
/// continue without waiting for the writer, with a fixed memory bound.
@MainActor
final class SweepFrameQueue {
    static let capacity = 3
    private var generation = UUID()
    private var pending: [UUID: CapturedFrame] = [:]
    private var tasks: [UUID: Task<CapturedFrame?, Never>] = [:]
    private var tail: Task<CapturedFrame?, Never>?
    var onCompletion: (() -> Void)?

    var frames: [CapturedFrame] { Array(pending.values) }
    var count: Int { pending.count }
    var isFull: Bool { count >= Self.capacity }

    func enqueue(
        _ frame: CapturedFrame,
        write: @escaping @MainActor () async -> CapturedFrame?
    ) -> Task<CapturedFrame?, Never>? {
        guard !isFull, pending[frame.id] == nil else { return nil }
        let previous = tail
        let token = generation
        pending[frame.id] = frame
        let task = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, self?.generation == token else { return nil as CapturedFrame? }
            let result = await write()
            guard let self, self.generation == token else { return result }
            self.pending.removeValue(forKey: frame.id)
            self.tasks.removeValue(forKey: frame.id)
            if self.pending.isEmpty { self.tail = nil }
            self.onCompletion?()
            return result
        }
        tasks[frame.id] = task
        tail = task
        return task
    }

    func drain() async {
        let token = generation
        while generation == token, let task = tasks.values.first {
            _ = await task.value
        }
    }

    func cancel() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        pending.removeAll()
        tail = nil
    }
}
