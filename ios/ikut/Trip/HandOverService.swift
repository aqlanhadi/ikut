import FirebaseFunctions
import Foundation

/// The organiser's way out of a live trip (D106): hand it to another member, then leave as an ordinary member.
extension TripService {
    /// What the person reads when hand-over doesn't go through; the server's own words are never shown.
    struct HandOverFailure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static func handOverFailureMessage(code: FunctionsErrorCode?, retryAfterSeconds: Int? = nil) -> String {
        switch code {
        case .permissionDenied: "You’re not the organiser any more, so you can’t hand the trip over."
        case .failedPrecondition: "This trip has ended, so it can’t be handed over."
        case .invalidArgument: "That person isn’t in the trip any more. Pick someone else."
        case .resourceExhausted:
            retryAfterSeconds.map { "You’ve handed this trip over a lot lately. Try again in \(JoinService.waitPhrase(seconds: $0))." }
                ?? "You’ve handed this trip over a lot lately. Try again in a little while."
        case .unavailable, .deadlineExceeded: "Can’t reach the server. Check your signal and try again."
        default: "Couldn’t hand the trip over just now. Please try again."
        }
    }

    static func handOverFailure(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain else {
            return ns.domain == NSURLErrorDomain ? HandOverFailure(message: handOverFailureMessage(code: .unavailable)) : error
        }
        let details = ns.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        let wait = details?["reason"] as? String == "too-many-handovers" ? (details?["retryAfterSeconds"] as? NSNumber)?.intValue : nil
        return HandOverFailure(message: handOverFailureMessage(code: FunctionsErrorCode(rawValue: ns.code), retryAfterSeconds: wait))
    }

    /// Organiser only: makes `newOrganizerId` (another member) the trip's organiser (`handOverTrip`). The caller stays
    /// in the trip as a member until they leave.
    @MainActor
    static func handOver(tripId: String, to newOrganizerId: String) async throws {
        do {
            let callable = Backend.functions.httpsCallable("handOverTrip")
            callable.timeoutInterval = callTimeout
            _ = try await callable.call(["tripId": tripId, "newOrganizerId": newOrganizerId])
        } catch {
            throw handOverFailure(error)
        }
    }

    /// Hand over, then leave. A hand-over that doesn't land stops there; one that landed with the leave failing leaves
    /// the person in the trip as an ordinary member, and says so, so their next Leave works as any member's.
    @MainActor
    static func handOverAndLeave(
        to name: String, handOver: () async throws -> Void, leave: () async throws -> Void
    ) async throws {
        try await handOver()
        do {
            try await leave()
        } catch {
            throw HandOverFailure(message: "\(name) is the organiser now, but you’re still in the trip. Check your signal, then tap Leave trip.")
        }
    }
}
