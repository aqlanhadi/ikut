import FirebaseFirestore
import Foundation

/// The two writes on a planned stop after the start (rules: `firestore.rules`, `stops/{stopId}`).
enum StopLeaveService {
    /// Leave: the stop is done for everyone. Lead car's tracker or the organizer; once. The server's own clock
    /// (the rules ask for `request.time`), so every phone reads the same `leftAt`. Offline, the write stays queued
    /// and the call returns false.
    @discardableResult
    static func leave(tripId: String, stopId: String, userId: String) async throws -> Bool {
        nonisolated(unsafe) let payload: [String: Any] = ["leftAt": FieldValue.serverTimestamp(), "leftBy": userId]
        let ref = Firestore.firestore().document(FirestorePaths.stop(tripId: tripId, stopId: stopId))
        return try await ServerWrite.commit { try await ref.updateData(payload) }
    }

    /// The lead car's phone marks when it first counted itself at the stop; "Leaving at" counts from it. Once: a
    /// second try (another phone in the lead car, or the organizer) is refused by the rules and is harmless.
    @discardableResult
    static func markArrived(tripId: String, stopId: String) async throws -> Bool {
        nonisolated(unsafe) let payload: [String: Any] = ["arrivedAt": FieldValue.serverTimestamp()]
        let ref = Firestore.firestore().document(FirestorePaths.stop(tripId: tripId, stopId: stopId))
        return try await ServerWrite.commit { try await ref.updateData(payload) }
    }
}
