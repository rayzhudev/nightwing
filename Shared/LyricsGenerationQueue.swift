import Foundation

/// One transcription at a time, with explicit requests ahead of library backfill.
@MainActor
final class LyricsGenerationQueue {
    private struct Waiter {
        let id: UUID
        var priority: Bool
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private(set) var activeID: UUID?
    var pendingIDs: [UUID] { waiters.map(\.id) }
    var stateChanged: (() -> Void)?

    func acquire(_ id: UUID, priority: Bool) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if activeID == nil {
                    activeID = id
                    stateChanged?()
                    continuation.resume()
                } else {
                    let waiter = Waiter(id: id, priority: priority, continuation: continuation)
                    let index = priority ? (waiters.firstIndex { !$0.priority } ?? waiters.count) : waiters.count
                    waiters.insert(waiter, at: index)
                    stateChanged?()
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    func promote(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }), !waiters[index].priority else { return }
        var waiter = waiters.remove(at: index)
        waiter.priority = true
        waiters.insert(waiter, at: waiters.firstIndex { !$0.priority } ?? waiters.count)
        stateChanged?()
    }

    func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        stateChanged?()
    }

    func release(_ id: UUID) {
        guard activeID == id else { return }
        activeID = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            activeID = next.id
            next.continuation.resume()
        }
        stateChanged?()
    }
}
