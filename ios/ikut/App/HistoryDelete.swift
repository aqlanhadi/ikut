import FirebaseAuth
import FirebaseFirestore
import Foundation

/// Delete from history (D107): an ended trip's entry leaves this phone's Past trips and the person leaves the trip, so
/// nothing of it stays here. History is on this phone only; the server deletes the trip 90 days after it ended.
enum HistoryDelete {
    enum Plan: Equatable {
        /// Leave the trip on the server first, then forget it here.
        case leaveThenRemove
        /// Left earlier (nothing to leave on the server), or not a member any more: forget it here.
        case removeOnly
    }

    enum Outcome: Equatable {
        case removed
        /// Nothing was changed; the words say why (the entry stays and Delete can be tried again).
        case kept(String)
    }

    static let couldntLeave = "Couldn’t leave the trip. Check your signal and try again."

    /// Only an ended trip in Past trips can be deleted; one still running is in Now and has no Delete.
    static func canDelete(_ entry: PastTrips.Entry) -> Bool { entry.endedAt != nil }

    static func plan(for entry: PastTrips.Entry) -> Plan {
        entry.leftAt == nil ? .leaveThenRemove : .removeOnly
    }

    /// `leave` deletes this phone's member doc and returns whether the server accepted it (false: still queued,
    /// offline). A refusal that says the phone isn't a member, or the trip is gone, counts as left
    /// (`HomeNow.isGone`); any other failure, or an unanswered write, keeps the entry and its files.
    @MainActor
    static func run(_ entry: PastTrips.Entry, leave: (String) async throws -> Bool,
                    removeLocal: (PastTrips.Entry) -> Void) async -> Outcome {
        guard canDelete(entry) else { return .kept(couldntLeave) }
        if plan(for: entry) == .leaveThenRemove {
            do {
                guard try await leave(entry.id) else { return .kept(couldntLeave) }
            } catch where HomeNow.isGone(error) {
                // Already out of it: nothing left to leave.
            } catch {
                return .kept(couldntLeave)
            }
        }
        removeLocal(entry)
        return .removed
    }

    /// Everything this phone keeps for the trip: its entry, its cached recap and its route on Home's map.
    static func removeLocalFiles(_ entry: PastTrips.Entry, defaults: UserDefaults = .standard) {
        PastTrips.remove(tripId: entry.id, defaults: defaults)
        RecapService.removeCache(tripId: entry.id)
        PastTripsMapService.forget(tripId: entry.id)
    }

    /// The real leave: one delete of this phone's member doc, as the rules allow on an ended trip (D98).
    @MainActor
    static func leaveOnServer(tripId: String) async throws -> Bool {
        guard let userId = Auth.auth().currentUser?.uid else { return false }
        let ref = Firestore.firestore().document(FirestorePaths.member(tripId: tripId, userId: userId))
        return try await ServerWrite.commit { try await ref.delete() }
    }
}
