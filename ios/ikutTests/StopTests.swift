import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: Pure logic

struct StopLogicTests {
    private let t0 = Fixtures.t0

    private func car(_ id: String, _ number: Int?, _ name: String, tracker: String? = nil, lead: Bool = false) -> Car {
        Car(
            id: id, name: name, color: "#2563EB", trackerUserId: tracker, isLead: lead, route: nil,
            mergeOffset: nil, state: .convoy, number: number)
    }

    private func stop(by carId: String = "c2", author: String = "u2", expires: Date? = nil, place: StopPlace? = nil) -> TripEvent {
        var e = TripEvent(
            type: .stopFuel, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: author, carId: carId, createdAt: t0)
        e.id = "stop1"
        e.expiresAt = expires
        e.place = place
        return e
    }

    private func vote(_ carId: String, agree: Bool, suggestion: StopPlace? = nil) -> StopVote {
        StopVote(id: carId, userId: "u-\(carId)", agree: agree, at: t0, suggestion: suggestion)
    }

    private func place(_ name: String = "R&R", offset: Double = 18_000, pinned: String? = nil) -> StopPlace {
        StopPlace(name: name, coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: offset, pinnedBy: pinned)
    }

    private var cars: [Car] {
        [
            car("c4", 4, "Daniel’s City", tracker: "u4"),
            car("c1", 1, "Aqlan’s Myvi", tracker: "u1", lead: true),
            car("c3", 3, "Hafiz’s Hilux", tracker: "u3"),
            car("c2", 2, "Wyna’s X70", tracker: "u2"),
            car("c5", 5, "Untracked"),
        ]
    }

    private func tally(
        _ event: TripEvent, votes: [StopVote] = [], me: String = "c1", user: String = "u1",
        organizer: Bool = false, offset: Double? = 0, now: Date? = nil
    ) throws -> StopRequestState {
        try #require(StopLogic.tally(
            event: event, votes: votes, cars: cars, myUserId: user, myCarId: me, isOrganizer: organizer,
            viewerOffset: offset, now: now ?? t0.addingTimeInterval(60)))
    }

    @Test func rowsAreOrderedByNumberAndSkipUntrackedCars() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.carId) == ["c1", "c2", "c3", "c4"])
        #expect(state.rows.first { $0.isMine }?.name == "Aqlan’s Myvi (you)")
    }

    @Test func requesterCountsAsAgreedOthersWaiting() throws {
        let state = try tally(stop())
        #expect(state.rows.map(\.status) == [.waiting, .agreed, .waiting, .waiting])
        #expect(state.agreedCount == 1)
        #expect(state.viewerAgrees == false)
    }

    @Test func votesTally() throws {
        let state = try tally(stop(), votes: [vote("c1", agree: true), vote("c3", agree: true), vote("c4", agree: false)])
        #expect(state.rows.map(\.status) == [.agreed, .agreed, .agreed, .waiting])
        #expect(state.agreedCount == 3)
        #expect(state.viewerAgrees)
    }

    @Test func aNoVoteWithSuggestionShowsSuggested() throws {
        let alt = place("Other R&R", offset: 26_000)
        let state = try tally(stop(), votes: [vote("c3", agree: false, suggestion: alt)])
        #expect(state.rows.first { $0.carId == "c3" }?.status == .suggested)
        #expect(state.alternatives.map(\.carId) == ["c3"])
        #expect(state.alternatives.first?.suggestion == alt)
    }

    @Test func requesterProposalIsItsOwnSuggestion() throws {
        let proposal = place("Proposed")
        let state = try tally(stop(), votes: [vote("c2", agree: true, suggestion: proposal)])
        #expect(state.proposal == proposal)
        #expect(state.alternatives.isEmpty)
        #expect(state.shownPlace == proposal)
    }

    @Test func pinnedPlaceWinsOverProposal() throws {
        let pinned = place("Pinned", pinned: "u1")
        let state = try tally(stop(place: pinned), votes: [vote("c2", agree: true, suggestion: place("Proposed"))])
        #expect(state.shownPlace == pinned)
    }

    @Test func aVoterOnAnUntrackedCarGetsARow() throws {
        let state = try tally(stop(), votes: [vote("c5", agree: true)])
        #expect(state.rows.map(\.carId).contains("c5"))
    }

    @Test func titleAndSubtitle() throws {
        let state = try tally(stop())
        #expect(state.title == "Wyna Needs Gas")
        #expect(state.subtitle(now: t0.addingTimeInterval(65)) == "Car 2 · asked 1 min ago")
        #expect(state.subtitle(now: t0.addingTimeInterval(5)) == "Car 2 · asked just now")
        #expect(StopLogic.ownerName(fromCarName: "Wyna's car") == "Wyna")
        #expect(StopLogic.ownerName(fromCarName: "Convoy") == "Convoy")
        #expect(StopRequestState.need(for: .stopFood) == "Needs Food")
        #expect(StopRequestState.need(for: .stopToilet) == "Needs a Toilet Break")
        #expect(StopRequestState.need(for: .stopRest) == "Needs a Rest")
    }

    @Test func distanceAndEtaToPlace() throws {
        let state = try tally(stop(place: place(offset: 18_000, pinned: "u1")), offset: 0)
        #expect(state.distanceText == "18 km ahead")
        #expect(state.etaText == "About 12 min")
        let passed = try tally(stop(place: place(offset: 18_000, pinned: "u1")), offset: 20_000)
        #expect(passed.distanceText == "Passed")
        #expect(passed.etaText == nil)
        let unknown = try tally(stop(place: place(pinned: "u1")), offset: nil)
        #expect(unknown.distanceText == nil)
    }

    // The UI gating: who may pin and resolve.

    @Test func leadCarTrackerCanPinAndResolve() throws {
        let state = try tally(stop(), me: "c1", user: "u1")
        #expect(state.canPin)
        #expect(state.canResolve)
    }

    @Test func organizerCanPinAndResolve() throws {
        let state = try tally(stop(), me: "c3", user: "u3", organizer: true)
        #expect(state.canPin)
        #expect(state.canResolve)
    }

    @Test func requesterCanResolveButNotPin() throws {
        let state = try tally(stop(), me: "c2", user: "u2")
        #expect(state.canPin == false)
        #expect(state.canResolve)
    }

    @Test func otherMemberCanNeitherPinNorResolve() throws {
        let state = try tally(stop(), me: "c3", user: "u3")
        #expect(state.canPin == false)
        #expect(state.canResolve == false)
    }

    @Test func leadFlagOnSomeoneElsesCarGrantsNothing() throws {
        // u9 shares car c1's lead flag in the viewer's context but doesn't track it.
        let state = try tally(stop(), me: "c1", user: "u9")
        #expect(state.canPin == false)
    }

    @Test func permissionsTruthTable() {
        #expect(StopPermissions.canPin(isLeadTracker: false, isOrganizer: false) == false)
        #expect(StopPermissions.canPin(isLeadTracker: true, isOrganizer: false))
        #expect(StopPermissions.canPin(isLeadTracker: false, isOrganizer: true))
        #expect(StopPermissions.canResolve(isAuthor: false, isLeadTracker: false, isOrganizer: false) == false)
        #expect(StopPermissions.canResolve(isAuthor: true, isLeadTracker: false, isOrganizer: false))
    }

    @Test func resolvedWhenExpired() throws {
        let state = try tally(stop(expires: t0), now: t0.addingTimeInterval(1))
        #expect(state.isResolved)
        #expect(try tally(stop()).isResolved == false)
    }

    @Test func activeStopPicksNewestOpenStop() {
        var old = stop(); old.id = "old"
        var new = stop(); new.id = "new"; new.createdAt = t0.addingTimeInterval(10)
        var done = stop(expires: t0.addingTimeInterval(5)); done.id = "done"; done.createdAt = t0.addingTimeInterval(20)
        var hazard = stop(); hazard.id = "h"; hazard.category = .hazard; hazard.createdAt = t0.addingTimeInterval(30)
        let now = t0.addingTimeInterval(60)
        #expect(StopLogic.activeStop(in: [old, new, done, hazard], now: now)?.id == "new")
        #expect(StopLogic.activeStop(in: [done, hazard], now: now) == nil)
    }

    // The card folding into a chip.

    @Test func newRequestOpensForOthersButNotTheRequester() throws {
        #expect(StopLogic.nextCardMemory(nil, state: try tally(stop())).collapsed == false)
        #expect(StopLogic.nextCardMemory(nil, state: try tally(stop(), me: "c2", user: "u2")).collapsed)
    }

    @Test func agreeingCollapsesAndThenTheViewersChoiceStands() throws {
        let open = StopLogic.nextCardMemory(nil, state: try tally(stop()))
        let agreed = try tally(stop(), votes: [vote("c1", agree: true)])
        var m = StopLogic.nextCardMemory(open, state: agreed)
        #expect(m.collapsed)
        m.collapsed = false  // reopened by a tap
        m = StopLogic.nextCardMemory(m, state: agreed)
        #expect(m.collapsed == false)
        m.collapsed = true  // minimized before voting
        let waiting = StopLogic.nextCardMemory(StopCardMemory(key: m.key, viewerAgreed: false, collapsed: true), state: try tally(stop()))
        #expect(waiting.collapsed)
    }

    @Test func pinningOrANewRequestReopensOnce() throws {
        let folded = StopLogic.nextCardMemory(nil, state: try tally(stop(), me: "c2", user: "u2"))
        var m = StopLogic.nextCardMemory(folded, state: try tally(stop(place: place(pinned: "u1")), me: "c2", user: "u2"))
        #expect(m.collapsed == false)
        m.collapsed = true
        m = StopLogic.nextCardMemory(m, state: try tally(stop(place: place(pinned: "u1")), me: "c2", user: "u2"))
        #expect(m.collapsed)
        var other = stop(); other.id = "stop2"
        #expect(StopLogic.nextCardMemory(m, state: try tally(other)).collapsed == false)
    }

    @Test func shortNamesLabelsAndChip() throws {
        let state = try tally(stop(place: place("R&R Demo", pinned: "u1")), votes: [vote("c1", agree: true), vote("c3", agree: true)])
        #expect(state.rows.map(StopLogic.shortName) == ["Me", "Wyna", "Hafiz", "Daniel"])
        #expect(StopLogic.voterAccessibilityLabel(state.rows[2]) == "Hafiz’s Hilux, agreed")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[3]) == "Daniel’s City, waiting")
        #expect(StopLogic.voterAccessibilityLabel(state.rows[0]) == "Aqlan’s Myvi, you, agreed")
        #expect(StopLogic.chipText(state) == "Fuel stop · R&R Demo · 3/4")
    }
}

// MARK: Suggestions

struct StopSuggestionTests {
    /// A straight east-west route from (3, 101), about 111 m per 0.001 deg, 60 km long.
    private let route = RouteLine((0...60).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.009) })

    private func at(km: Double, offRouteMeters: Double = 0) -> CLLocationCoordinate2D {
        route.coordinate(atOffset: km * 1000).map {
            CLLocationCoordinate2D(latitude: $0.latitude + offRouteMeters / 111_195, longitude: $0.longitude)
        }!
    }

    private func found(_ name: String, km: Double, off: Double = 0) -> FoundPlace {
        FoundPlace(name: name, coordinate: at(km: km, offRouteMeters: off))
    }

    @Test func rankSortsByDistanceAlongRoute() {
        let ranked = StopSuggestions.rank(
            [found("C", km: 24), found("A", km: 12), found("B", km: 18)], route: route, fromOffset: 0)
        #expect(ranked.map(\.name) == ["A", "B", "C"])
        #expect(abs(ranked[1].distanceAhead - 18_000) < 50)
        #expect(abs(ranked[1].routeOffset - 18_000) < 50)
    }

    @Test func rankMeasuresFromTheViewer() {
        let ranked = StopSuggestions.rank([found("A", km: 30)], route: route, fromOffset: 10_000)
        #expect(abs(ranked[0].distanceAhead - 20_000) < 50)
    }

    @Test func rankDropsPlacesBehindOrTooFarOffRoute() {
        let ranked = StopSuggestions.rank(
            [found("behind", km: 5), found("here", km: 10.2), found("far", km: 20, off: 5_000), found("ok", km: 20, off: 800)],
            route: route, fromOffset: 10_000)
        #expect(ranked.map(\.name) == ["ok"])
        #expect(abs(ranked[0].offRoute - 800) < 20)
    }

    @Test func rankCollapsesDuplicatesAndLimits() {
        let dupes = [found("Petronas", km: 15), found("Petronas", km: 15.05), found("Shell", km: 16)]
        #expect(StopSuggestions.rank(dupes, route: route, fromOffset: 0).map(\.name) == ["Petronas", "Shell"])
        let many = (1...9).map { found("P\($0)", km: Double($0) * 3) }
        #expect(StopSuggestions.rank(many, route: route, fromOffset: 0, limit: 3).count == 3)
    }

    @Test func rankOnEmptyRoute() {
        #expect(StopSuggestions.rank([found("A", km: 12)], route: RouteLine([]), fromOffset: 0).isEmpty)
    }

    @Test func candidateText() {
        let onRoute = StopSuggestions.rank([found("A", km: 18)], route: route, fromOffset: 0)[0]
        #expect(onRoute.costText == "On route")
        #expect(onRoute.whereText == "18 km ahead · about 12 min")
        let off = StopSuggestions.rank([found("B", km: 18, off: 1_500)], route: route, fromOffset: 0)[0]
        #expect(off.costText == "+4 min")
        #expect(off.whereText.hasSuffix("off route"))
    }

    @Test func queriesPerType() {
        #expect(StopSuggestions.queries(for: .stopFuel).contains("petrol station"))
        #expect(StopSuggestions.queries(for: .stopFood) == ["restaurant"])
        #expect(StopSuggestions.queries(for: .stopRest).contains("R&R"))
        #expect(StopSuggestions.queries(for: .stopToilet) == StopSuggestions.queries(for: .stopRest))
    }

    @Test func searchCenterIsTwentyKmAhead() throws {
        let center = try #require(StopSuggestions.searchCenter(on: route, from: 5_000))
        let expected = try #require(route.coordinate(atOffset: 25_000))
        #expect(RouteLine.haversine(center, expected) < 1)
        // Near the end it clamps to the route's end.
        let end = try #require(StopSuggestions.searchCenter(on: route, from: route.length - 1_000))
        #expect(RouteLine.haversine(end, route.coordinates.last!) < 1)
    }

    @Test func suggestSearchesEachQueryAndRanks() async throws {
        let searcher = FakeSearcher(results: [found("A", km: 14), found("B", km: 22)])
        let list = try await StopSuggestions.suggest(type: .stopRest, route: route, fromOffset: 0, searcher: searcher)
        #expect(list.map(\.name) == ["A", "B"])
        #expect(await searcher.queries == ["R&R", "rest area"])
        let center = try #require(await searcher.centers.first)
        #expect(RouteLine.haversine(center, try #require(route.coordinate(atOffset: 20_000))) < 1)
    }

    @Test func suggestToleratesOneFailingQueryButNotAll() async throws {
        let partial = FakeSearcher(results: [found("A", km: 14)], failOn: ["petrol station"])
        let list = try await StopSuggestions.suggest(type: .stopFuel, route: route, fromOffset: 0, searcher: partial)
        #expect(list.map(\.name) == ["A"])
        let broken = FakeSearcher(results: [], failOn: ["petrol station", "gas station"])
        await #expect(throws: (any Error).self) {
            try await StopSuggestions.suggest(type: .stopFuel, route: route, fromOffset: 0, searcher: broken)
        }
    }
}

private actor FakeSearcherState {
    var queries: [String] = []
    var centers: [CLLocationCoordinate2D] = []
    func record(_ q: String, _ c: CLLocationCoordinate2D) { queries.append(q); centers.append(c) }
}

private struct FakeSearcher: PlaceSearching {
    var results: [FoundPlace]
    var failOn: Set<String> = []
    private let state = FakeSearcherState()
    var queries: [String] { get async { await state.queries } }
    var centers: [CLLocationCoordinate2D] { get async { await state.centers } }

    init(results: [FoundPlace], failOn: Set<String> = []) {
        self.results = results
        self.failOn = failOn
    }

    func search(query: String, near center: CLLocationCoordinate2D, radius: CLLocationDistance) async throws -> [FoundPlace] {
        await state.record(query, center)
        if failOn.contains(query) { throw URLError(.notConnectedToInternet) }
        return results
    }
}

// MARK: Emulator

/// Runs against the local Auth, Functions and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct StopEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private let service = StopService()
    private let route = RouteLine((0...60).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.009) })

    private func makeTrip() async throws -> (tripId: String, carId: String, uid: String, code: String) {
        let trip = try await EmulatorTrip.make(name: "Stops")
        return (trip.tripId, trip.carId, trip.uid, try await trip.code())
    }

    private func context(_ tripId: String, uid: String, carId: String, organizer: Bool) -> StopContext {
        StopContext(
            tripId: tripId, userId: uid, carId: carId, isOrganizer: organizer,
            snapshot: {
                ReportSnapshot(
                    coordinate: .init(latitude: 3, longitude: 101.01), heading: 90, route: nil,
                    previousOffset: nil, capturedAt: Date())
            },
            mainRoute: route)
    }

    private func place(_ name: String, km: Double) -> StopPlace {
        let c = route.coordinate(atOffset: km * 1000)!
        return StopPlace(name: name, coordinate: GeoPoint(latitude: c.latitude, longitude: c.longitude), routeOffset: km * 1000, pinnedBy: nil)
    }

    /// First state from `stream` that satisfies `predicate`, or nil after `seconds`.
    private func next(
        _ stream: AsyncStream<StopRequestState?>, seconds: Double = 10, where predicate: @escaping @Sendable (StopRequestState?) -> Bool
    ) async -> StopRequestState?? {
        await withTaskGroup(of: StopRequestState??.self) { group in
            group.addTask {
                for await state in stream where predicate(state) { return .some(state) }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func state(
        _ stream: AsyncStream<StopRequestState?>, where predicate: @escaping @Sendable (StopRequestState) -> Bool
    ) async throws -> StopRequestState {
        let found = await next(stream) { $0.map(predicate) ?? false }
        return try #require(found ?? nil, "no matching state arrived")
    }

    /// Organizer (lead car) asks, votes, pins a place, then resolves; the listener sees each step.
    @Test func leadRequestsVotesPinsAndResolves() async throws {
        let trip = try await makeTrip()
        let ctx = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let eventId = try await service.request(
            type: .stopFuel, place: place("Petronas Tapah", km: 18), context: ctx, snapshot: try #require(ctx.snapshot()))
        let asked = try await state(stream) { $0.proposal != nil }
        #expect(asked.eventId == eventId)
        #expect(asked.proposal?.name == "Petronas Tapah")
        #expect(asked.place == nil)
        #expect(asked.canPin)
        #expect(asked.title == "Aqlan Needs Gas")

        try await service.vote(tripId: trip.tripId, eventId: eventId, carId: trip.carId, userId: trip.uid, agree: true)
        try await service.pin(tripId: trip.tripId, eventId: eventId, place: place("Petronas Tapah", km: 18), userId: trip.uid)
        let pinned = try await state(stream) { $0.place != nil }
        #expect(pinned.place?.name == "Petronas Tapah")
        #expect(pinned.place?.pinnedBy == trip.uid)
        #expect(pinned.distanceText != nil)

        try await service.resolve(tripId: trip.tripId, eventId: eventId, now: Date().addingTimeInterval(-1))
        let closed = await next(stream) { $0 == nil }
        #expect(closed != nil, "expected the listener to report no open stop")
    }

    /// A joined car votes and is tallied; it cannot pin (rejected by the rules) or resolve someone
    /// else's request, and the pin is not applied.
    @Test func memberVotesButCannotPinOrResolve() async throws {
        let trip = try await makeTrip()
        let orgContext = context(trip.tripId, uid: trip.uid, carId: trip.carId, organizer: true)
        let eventId = try await service.request(
            type: .stopFood, place: nil, context: orgContext, snapshot: try #require(orgContext.snapshot()))

        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joiner = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: trip.code, displayName: "Wyna", car: .new(name: "Wyna's X70", color: TripService.palette[1]), tracker: true)
        let ctx = context(trip.tripId, uid: joiner, carId: joined.carId, organizer: false)
        let stream = StopService.listen(context: ctx, refresh: .seconds(60))

        let before = try await state(stream) { $0.rows.count == 2 }
        #expect(before.canPin == false)
        #expect(before.canResolve == false)
        #expect(before.viewerAgrees == false)

        try await service.vote(tripId: trip.tripId, eventId: eventId, carId: joined.carId, userId: joiner, agree: true)
        let voted = try await state(stream) { $0.viewerAgrees }
        #expect(voted.agreedCount == 2)

        try await service.suggest(place: place("Other R&R", km: 26), eventId: eventId, canPin: false, context: ctx)
        let suggested = try await state(stream) { $0.alternatives.count == 1 }
        #expect(suggested.rows.first { $0.isMine }?.status == .suggested)

        await #expect(throws: (any Error).self) {
            try await service.pin(tripId: trip.tripId, eventId: eventId, place: place("Hax", km: 5), userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await service.resolve(tripId: trip.tripId, eventId: eventId)
        }
        // Voting for the organizer's car is also rejected.
        await #expect(throws: (any Error).self) {
            try await service.vote(tripId: trip.tripId, eventId: eventId, carId: trip.carId, userId: joiner, agree: true)
        }
        let doc = try await Firestore.firestore().document(FirestorePaths.event(tripId: trip.tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
        #expect(doc.place == nil)
        #expect(doc.expiresAt == nil)
    }
}
