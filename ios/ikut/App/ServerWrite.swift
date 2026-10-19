import Foundation

/// Waits a bounded time for the server to accept a Firestore write.
///
/// Firestore's async writes resolve only once the server answers, and ignore task cancellation,
/// so racing one in a task group still waits for it (the group awaits every child). Offline that
/// is forever. Here the write runs in its own task and the caller is released at the deadline,
/// with Firestore keeping the write queued.
enum ServerWrite {
    static let defaultTimeout: Duration = .seconds(8)

    /// Raised by callers that can't proceed on a queued write.
    struct Offline: LocalizedError {
        var errorDescription: String? { "No connection to the server. Check your signal and try again." }
    }

    /// Returns true once the server accepts the write, false if `timeout` passes first (still
    /// queued), and throws if the server rejects it.
    @discardableResult
    static func commit(
        within timeout: Duration = defaultTimeout,
        _ write: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let outcome = WriteOutcome<Bool>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outcome.install(continuation)
                Task {
                    do {
                        try await write()
                        outcome.finish(.success(true))
                    } catch {
                        outcome.finish(.failure(error))
                    }
                }
                Task {
                    try? await Task.sleep(for: timeout)
                    outcome.finish(.success(false))
                }
            }
        } onCancel: {
            outcome.finish(.failure(CancellationError()))
        }
    }
}

/// Resumes a continuation exactly once with whichever result arrives first.
final class WriteOutcome<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func finish(_ outcome: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }
}

extension WriteOutcome where Value == Void {
    func finish(_ error: Error?) {
        finish(error.map { .failure($0) } ?? .success(()))
    }
}
