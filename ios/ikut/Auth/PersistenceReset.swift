import FirebaseFirestore
import Foundation

/// Firestore keeps what it read (trips, members, positions) in an on-disk cache. After Delete account or Sign out that
/// must go (#749). Clearing needs Firestore not yet used, so the person's sign-out sets a flag and the next launch clears
/// the cache in `Backend.configure`, before anything reads.
enum PersistenceReset {
    static let key = "ikut.clearFirestoreCache"

    static func markPending(defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }

    static func isPending(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }

    /// Runs `clear` when the flag is set, and drops the flag once it reports success (a failure keeps it for next launch).
    /// Returns whether a clear was started.
    @discardableResult
    static func runIfPending(defaults: UserDefaults = .standard, clear: (@escaping @Sendable (Error?) -> Void) -> Void) -> Bool {
        guard isPending(defaults: defaults) else { return false }
        nonisolated(unsafe) let defaults = defaults
        clear { error in if error == nil { defaults.removeObject(forKey: key) } }
        return true
    }

    /// The real clear, on the default Firestore instance.
    static func clearFirestore() {
        runIfPending { done in Firestore.firestore().clearPersistence(completion: done) }
    }
}
