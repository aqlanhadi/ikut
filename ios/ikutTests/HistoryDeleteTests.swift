import FirebaseFirestore
import Foundation
import Testing

@testable import ikut

/// Delete from history (D107): what is done for each kind of entry, and that nothing local goes before the server step.
@MainActor
struct HistoryDeleteTests {
    private func entry(_ id: String = "t-\(UUID().uuidString)", ended: Bool = true, left: Bool = false) -> PastTrips.Entry {
        PastTrips.Entry(id: id, name: "Balik", destination: "Ipoh", endedAt: ended ? Date() : nil, seenAt: Date(),
                        others: ["Wyna"], leftAt: left ? Date() : nil)
    }

    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue)
    }

    /// Runs the delete with a fake leave; returns the outcome, the ids the leave was asked for and those removed locally.
    private func run(_ e: PastTrips.Entry, leave: @escaping (String) async throws -> Bool) async -> (HistoryDelete.Outcome, [String], [String]) {
        var asked: [String] = [], removed: [String] = []
        let outcome = await HistoryDelete.run(e, leave: { asked.append($0); return try await leave($0) }, removeLocal: { removed.append($0.id) })
        return (outcome, asked, removed)
    }

    @Test func thePlanFollowsTheEntry() {
        #expect(HistoryDelete.plan(for: entry()) == .leaveThenRemove)
        #expect(HistoryDelete.plan(for: entry(left: true)) == .removeOnly)
        #expect(HistoryDelete.canDelete(entry()))
        #expect(HistoryDelete.canDelete(entry(left: true)))
        #expect(!HistoryDelete.canDelete(entry(ended: false)))
    }

    @Test func anEndedTripYouAreStillInIsLeftThenForgotten() async {
        let e = entry()
        let (outcome, asked, removed) = await run(e) { _ in true }
        #expect(outcome == .removed)
        #expect(asked == [e.id] && removed == [e.id])
    }

    @Test func aTripYouLeftEarlierNeedsNoServerStep() async {
        let e = entry(left: true)
        let (outcome, asked, removed) = await run(e) { _ in Issue.record("no leave expected"); return true }
        #expect(outcome == .removed)
        #expect(asked.isEmpty && removed == [e.id])
    }

    @Test func aTripGoneFromTheServerCountsAsLeft() async {
        for code in [FirestoreErrorCode.Code.notFound, .permissionDenied] {
            let e = entry()
            let (outcome, _, removed) = await run(e) { _ in throw firestoreError(code) }
            #expect(outcome == .removed)
            #expect(removed == [e.id])
        }
    }

    @Test func aRefusedOrFailedLeaveKeepsEverything() async {
        let e = entry()
        let (outcome, _, removed) = await run(e) { _ in throw firestoreError(.unavailable) }
        #expect(outcome == .kept(HistoryDelete.couldntLeave))
        #expect(removed.isEmpty)
    }

    @Test func anOfflineWriteKeepsEverything() async {
        let e = entry()
        let (outcome, _, removed) = await run(e) { _ in false }
        #expect(outcome == .kept(HistoryDelete.couldntLeave))
        #expect(removed.isEmpty)
    }

    @Test func aTripStillRunningIsNeverDeleted() async {
        let e = entry(ended: false)
        let (outcome, asked, removed) = await run(e) { _ in true }
        #expect(outcome == .kept(HistoryDelete.couldntLeave))
        #expect(asked.isEmpty && removed.isEmpty)
    }

    @Test func removingDropsTheEntryItsRecapAndItsRoute() throws {
        let suite = "ikut.historydelete.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keep = entry(), drop = entry()
        for e in [keep, drop] {
            PastTrips.record(tripId: e.id, name: e.name, destination: e.destination, endedAt: e.endedAt, defaults: defaults)
            var snap = RecapSnapshot.demo(); snap.tripId = e.id
            RecapService.save(snap)
            PastTripsMapService.remember(PastTripsMapLogic.route(id: e.id, name: e.name, destinationName: "Ipoh",
                                                                 destination: snap.destination, encodedRoute: snap.route))
        }
        defer { HistoryDelete.removeLocalFiles(keep, defaults: defaults) }
        HistoryDelete.removeLocalFiles(drop, defaults: defaults)
        #expect(PastTrips.all(defaults: defaults).map(\.id) == [keep.id])
        #expect(RecapService.cached(tripId: drop.id) == nil)
        #expect(RecapService.cached(tripId: keep.id) != nil)
        #expect(PastTripsMapService.cachedRoutes()[drop.id] == nil)
        #expect(PastTripsMapService.cachedRoutes()[keep.id] != nil)
    }

    @Test func homeDropsTheRowAndItsRouteOnlyOnceDeleted() async {
        let a = entry("a"), b = entry("b")
        let drawn = { (id: String) in PastTripRoute(id: id, name: id, destinationName: "I", destinationLatitude: 4, destinationLongitude: 101, points: []) }
        let model = HomeModel(past: [a, b], routes: [drawn("a"), drawn("b")])
        await model.delete(a, leave: { _ in false }, removeLocal: { _ in })
        #expect(model.past.map(\.id) == ["a", "b"])
        #expect(model.deleteProblem == HistoryDelete.couldntLeave)
        await model.delete(a, leave: { _ in true }, removeLocal: { _ in })
        #expect(model.past.map(\.id) == ["b"])
        #expect(model.routes.map(\.id) == ["b"])
        #expect(model.deleteProblem == nil)
    }
}

/// The emulator: a member leaves an ended trip through the app's own path, and the entry's local files go.
@Suite(.emulator, .serialized)
@MainActor
struct HistoryDeleteEmulatorTests {
    @Test func aMemberLeavesAnEndedTripAndItsLocalFilesGo() async throws {
        Backend.configure()
        let s = try await EmulatorTrip.make(name: "History")
        let db = Firestore.firestore()
        try await db.document(FirestorePaths.trip(s.tripId)).updateData(["status": "ended", "endedAt": FieldValue.serverTimestamp()])
        let suite = "ikut.historydelete.emu.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let e = PastTrips.Entry(id: s.tripId, name: "History", destination: "Kota Bharu", endedAt: Date(), seenAt: Date(), others: nil)
        PastTrips.record(tripId: e.id, name: e.name, destination: e.destination, endedAt: e.endedAt, defaults: defaults)
        var snap = RecapSnapshot.demo(); snap.tripId = e.id
        RecapService.save(snap)

        let outcome = await HistoryDelete.run(e, leave: { try await HistoryDelete.leaveOnServer(tripId: $0) },
                                              removeLocal: { HistoryDelete.removeLocalFiles($0, defaults: defaults) })
        #expect(outcome == .removed)
        let member = FirestorePaths.member(tripId: s.tripId, userId: s.uid)
        // No longer a member: the doc is gone, or the rules refuse the read (leaving ends read access).
        let stillThere = (try? await db.document(member).getDocument(source: .server).exists) ?? false
        #expect(!stillThere)
        #expect(PastTrips.all(defaults: defaults).isEmpty)
        #expect(RecapService.cached(tripId: e.id) == nil)

        // Again: the trip is no longer readable by this phone, which counts as left.
        let again = await HistoryDelete.run(e, leave: { try await HistoryDelete.leaveOnServer(tripId: $0) }, removeLocal: { _ in })
        #expect(again == .removed)
    }
}
