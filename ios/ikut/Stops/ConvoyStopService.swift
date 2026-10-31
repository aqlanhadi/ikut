import FirebaseFirestore
import Foundation

/// The two writes of the convoy's stopped phase (D122; rules: `firestore.rules`, `trips/{tripId}`, `startsStopPhase` and
/// `endsStopPhase`). Lead car's tracker or organizer only. No place is written, only when, who and which request.
enum ConvoyStopService {
    /// We’ve stopped from the lead car or the organizer: closes the request as stopped and starts the phase, in one
    /// batch, so neither lands without the other. Offline, the batch stays queued and the call returns false.
    @discardableResult
    static func stopped(tripId: String, eventId: String, userId: String, now: Date = Date()) async throws -> Bool {
        nonisolated(unsafe) let close = StopService.closeData(reason: .stopped, userId: userId, now: now)
        nonisolated(unsafe) let phase: [String: Any] = [
            "stoppedAt": FieldValue.serverTimestamp(), "stoppedBy": userId, "stoppedEventId": eventId,
        ]
        let db = Firestore.firestore()
        let event = db.document(FirestorePaths.event(tripId: tripId, eventId: eventId))
        let trip = db.document(FirestorePaths.trip(tripId))
        nonisolated(unsafe) let batch = db.batch()
        batch.updateData(close, forDocument: event)
        batch.updateData(phase, forDocument: trip)
        return try await ServerWrite.commit { try await batch.commit() }
    }

    /// Continue: the phase is over for everyone. Also sent after Leave on a planned stop, and by the lead car's phone
    /// once its car has moved off.
    @discardableResult
    static func resume(tripId: String) async throws -> Bool {
        nonisolated(unsafe) let cleared: [String: Any] = [
            "stoppedAt": FieldValue.delete(), "stoppedBy": FieldValue.delete(), "stoppedEventId": FieldValue.delete(),
        ]
        let ref = Firestore.firestore().document(FirestorePaths.trip(tripId))
        return try await ServerWrite.commit { try await ref.updateData(cleared) }
    }
}
