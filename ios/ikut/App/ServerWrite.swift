import FirebaseFirestore
import Foundation

/// Waits a bounded time for the server to accept a Firestore write.
///
/// Firestore's async writes resolve only once the server answers, and ignore task cancellation,
/// so racing one in a task group still waits for it (the group awaits every child). Offline that
/// is forever. Here the write runs in its own task and the caller is released at the deadline,
/// with Firestore keeping the write queued.
enum ServerWrite {
    static let defaultTimeout: Duration = .seconds(8)

    /// Runs when a write hits its deadline, before the caller hears of it: AuthModel checks the user
    /// is still known to the server (a deleted one is signed out). Bounded by `checkTimeout`.
    nonisolated(unsafe) static var onTimeout: @Sendable () async -> Void = {}
    static let checkTimeout: Duration = .seconds(3)

    /// Raised by callers that can't proceed on a queued write.
    struct Offline: LocalizedError {
        var errorDescription: String? { "Can’t reach the server. Check your signal and try again." }
    }

    /// Returns true once the server accepts the write, false if `timeout` passes first (still
    /// queued), and throws if the server rejects it.
    @discardableResult
    static func commit(
        within timeout: Duration = defaultTimeout,
        _ write: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        let accepted: Bool
        do {
            accepted = try await attempt(within: timeout, write)
        } catch {
            // A deleted user whose token hasn't expired yet is turned away, not left hanging.
            if isUnauthorised(error) { await checkAfterTimeout() }
            throw error
        }
        if !accepted { await checkAfterTimeout() }
        return accepted
    }

    private static func isUnauthorised(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: ns.code) else { return false }
        return code == .permissionDenied || code == .unauthenticated
    }

    private static func attempt(
        within timeout: Duration,
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

    private static func checkAfterTimeout() async {
        let check = onTimeout
        let done = WriteOutcome<Bool>()
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
            done.install(continuation)
            Task { await check(); done.finish(.success(true)) }
            Task { try? await Task.sleep(for: checkTimeout); done.finish(.success(false)) }
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
