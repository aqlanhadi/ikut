import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// The organiser's two writes for who is in the trip (D104): a removal that records who was removed, and a new code.
extension TripService {
    /// What the person reads when the new-code call doesn't go through; the server's own words are never shown.
    struct NewCodeFailure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static func newCodeFailureMessage(code: FunctionsErrorCode?, retryAfterSeconds: Int?) -> String {
        switch code {
        case .resourceExhausted:
            guard let seconds = retryAfterSeconds else { return "You’ve made a lot of new codes lately. Try again in a little while." }
            if seconds > 12 * 3600 { return "You’ve made a lot of new codes today. Try again tomorrow." }
            return "You’ve made a lot of new codes lately. Wait \(JoinService.waitPhrase(seconds: seconds)) and try again."
        case .unavailable, .deadlineExceeded:
            return "Can’t reach the server. Check your signal and try again."
        case .failedPrecondition:
            return "This trip has ended, so it can’t have a new code."
        default:
            return "Couldn’t make a new code just now. Please try again."
        }
    }

    static func newCodeFailure(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain else {
            return ns.domain == NSURLErrorDomain
                ? NewCodeFailure(message: newCodeFailureMessage(code: .unavailable, retryAfterSeconds: nil)) : error
        }
        let details = ns.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        let wait = details?["reason"] as? String == "too-many-codes" ? (details?["retryAfterSeconds"] as? NSNumber)?.intValue : nil
        return NewCodeFailure(message: newCodeFailureMessage(code: FunctionsErrorCode(rawValue: ns.code), retryAfterSeconds: wait))
    }

    /// Organiser only: asks the server for a new code (`rotateTripCode`). The old code stops working, people already in
    /// the trip stay in, and anyone removed may join with the new one. Returns the code; the trip's own listener also
    /// brings it to every screen that shows the code.
    @MainActor
    static func newCode(tripId: String) async throws -> String {
        do {
            let callable = Backend.functions.httpsCallable("rotateTripCode")
            callable.timeoutInterval = callTimeout
            let result = try await callable.call(["tripId": tripId])
            guard let data = result.data as? [String: Any], let code = data["code"] as? String, !code.isEmpty else {
                throw NewCodeFailure(message: newCodeFailureMessage(code: nil, retryAfterSeconds: nil))
            }
            return code
        } catch {
            throw newCodeFailure(error)
        }
    }

    /// Organiser only (rules): removes someone else from the trip. The `removed` record and the member delete go in one
    /// batch, as the rules need; the record is what makes `joinTrip` turn them away until the next new code.
    @MainActor
    static func removeMember(tripId: String, userId: String, by organizerId: String) async throws {
        let db = Firestore.firestore()
        nonisolated(unsafe) let batch = db.batch()
        batch.setData(
            ["userId": userId, "removedAt": FieldValue.serverTimestamp(), "removedBy": organizerId],
            forDocument: db.document(FirestorePaths.removed(tripId: tripId, userId: userId)))
        batch.deleteDocument(db.document(FirestorePaths.member(tripId: tripId, userId: userId)))
        guard try await ServerWrite.commit({ try await batch.commit() }) else { throw ServerWrite.Offline() }
    }
}
