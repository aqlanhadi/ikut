import FirebaseFirestore
import Foundation

/// A car's answer about a planned stop (`trips/{id}/stops/{stopId}/answers/{carId}`): "we'll skip this stop"
/// and "we'll stop after all". The rules decide who may (a member of that car, not the lead car, before the car
/// reaches the stop); a rejected write throws, and offline the write stays queued
/// (as for the OK of a stop request).
enum StopAnswerService {
    /// The viewer's car says it is skipping the stop. Writes the same document again if a second phone in the car
    /// says it too.
    static func skip(tripId: String, stopId: String, carId: String, userId: String) async throws {
        nonisolated(unsafe) let payload: [String: Any] = [
            "answer": StopAnswerKind.skip.rawValue, "userId": userId, "at": FieldValue.serverTimestamp(),
        ]
        let ref = Firestore.firestore().document(FirestorePaths.answer(tripId: tripId, stopId: stopId, carId: carId))
        try await ServerWrite.commit { try await ref.setData(payload) }
    }

    /// "We'll stop after all": takes the car's answer back. Nothing to do if there is none.
    static func undo(tripId: String, stopId: String, carId: String) async throws {
        let ref = Firestore.firestore().document(FirestorePaths.answer(tripId: tripId, stopId: stopId, carId: carId))
        try await ServerWrite.commit { try await ref.delete() }
    }

    /// The answers on one stop, as they change.
    static func listen(tripId: String, stopId: String) -> AsyncStream<[StopAnswer]> {
        let query = Firestore.firestore().collection(FirestorePaths.answers(tripId: tripId, stopId: stopId))
        return AsyncStream { continuation in
            nonisolated(unsafe) let registration = query.addSnapshotListener { snapshot, _ in
                guard let snapshot else { return }
                continuation.yield(snapshot.documents.compactMap { try? $0.data(as: StopAnswer.self) })
            }
            continuation.onTermination = { _ in registration.remove() }
        }
    }
}
