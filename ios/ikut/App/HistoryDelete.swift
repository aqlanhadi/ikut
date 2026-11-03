import FirebaseAuth
import FirebaseFirestore
import Foundation
import UserNotifications

/// Delete from history (D107): an ended trip's entry leaves this phone's Past trips and the person leaves the trip.
/// Removed here: the entry, the saved recap and the route on Home's map. Firestore's own offline cache is the SDK's
/// to evict (kept for offline use), and delivered alert notifications for the trip are cleared. History is on this
/// phone only; the server deletes the trip 90 days after it ended.
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
    static let signedOut = "You’re signed out. Close ikut and open it again, then try again."

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
            } catch is SignedOut {
                return .kept(signedOut)
            } catch {
                return .kept(couldntLeave)
            }
        }
        removeLocal(entry)
        return .removed
    }

    /// Trips deleted since the app opened. A recap or route load already running when Delete lands must not write the
    /// trip back (its saves and `PastTrips.record` check this at write time).
    @MainActor private(set) static var removedIds: Set<String> = []

    /// Everything this phone keeps for the trip: its entry, its cached recap and its route on Home's map, plus
    /// delivered alerts for it and the "asked" memory if it is for this trip.
    @MainActor
    static func removeLocalFiles(_ entry: PastTrips.Entry, defaults: UserDefaults = .standard) {
        removedIds.insert(entry.id)
        PastTrips.remove(tripId: entry.id, defaults: defaults)
        RecapService.removeCache(tripId: entry.id)
        PastTripsMapService.forget(tripId: entry.id)
        let asked = UserDefaults.standard
        if asked.string(forKey: askedKey)?.hasPrefix(entry.id + "|") == true { asked.removeObject(forKey: askedKey) }
        let thread = AlertCenter.threadIdentifier(tripId: entry.id)
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// Everything this phone keeps of its trips (Sign out): every entry's local files, any cached route or recap
    /// left without an entry, and the "asked" memory.
    @MainActor
    static func removeAllLocal(defaults: UserDefaults = .standard) {
        for entry in PastTrips.all(defaults: defaults) { removeLocalFiles(entry, defaults: defaults) }
        for id in PastTripsMapService.cachedRoutes().keys {
            PastTripsMapService.forget(tripId: id)
            RecapService.removeCache(tripId: id)
        }
        UserDefaults.standard.removeObject(forKey: askedKey)
    }

    /// `TripMapView`'s `@AppStorage` key for which asks were answered for a trip.
    static let askedKey = "ikut.map.askedTrip"

    /// No one is signed in, so the leave can't be asked of the server.
    struct SignedOut: Error {}

    /// The real leave: one delete of this phone's member doc, as the rules allow on an ended trip (D98).
    @MainActor
    static func leaveOnServer(tripId: String) async throws -> Bool {
        guard let userId = Auth.auth().currentUser?.uid else { throw SignedOut() }
        let ref = Firestore.firestore().document(FirestorePaths.member(tripId: tripId, userId: userId))
        return try await ServerWrite.commit { try await ref.delete() }
    }
}
