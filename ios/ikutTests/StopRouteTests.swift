import CoreLocation
import FirebaseFirestore
import MapKit
import Foundation
import Testing
@testable import ikut

private let earth = RouteLine.earthRadius
private let start = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)

private func move(_ c: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: c.latitude + north / earth * 180 / .pi,
        longitude: c.longitude + east / (earth * cos(c.latitude * .pi / 180)) * 180 / .pi)
}

/// Points every `step` meters from `a` to `b`, both included.
private func line(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, step: Double = 500) -> [CLLocationCoordinate2D] {
    let length = RouteLine.haversine(a, b)
    let count = max(1, Int((length / step).rounded(.up)))
    return (0...count).map { i in
        let t = Double(i) / Double(count)
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

private func leg(_ points: [CLLocationCoordinate2D], seconds: Double? = nil, name: String = "E1") -> RouteLeg {
    let length = RouteLine(points).length
    return RouteLeg(coordinates: points, distance: length, travelTime: seconds ?? length / 25, name: name)
}

/// Straight roads between any two points, 25 m/s, counting the requests it gets.
private final class StraightRoads: LegRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
    /// Destinations (latitude) that have no road.
    var noRoadTo: Set<Double> = []

    var requests: Int { lock.withLock { _requests.count } }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        lock.withLock { _requests.append((from, to)) }
        if lock.withLock({ noRoadTo.contains(to.latitude) }) { throw RouteError.noRoute }
        return ikutTests.leg(line(from, to))
    }
}

/// Answers "throttled" the first `throttles` times, then like StraightRoads.
private final class ThrottledRoads: LegRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    private(set) var requests = 0
    init(throttles: Int) { left = throttles }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        let throttled: Bool = lock.withLock {
            requests += 1
            if left > 0 { left -= 1; return true }
            return false
        }
        if throttled { throw MKError(.loadingThrottled) }
        return ikutTests.leg(line(from, to))
    }
}

private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Duration] = []
    var items: [Duration] { lock.withLock { _items } }
    func add(_ d: Duration) { lock.withLock { _items.append(d) } }
}

struct ThrottleRetryTests {
    private let a = move(start, north: 60_000)
    private let end = move(start, north: 200_000)

    @Test func oneThrottleWaitsAndTriesOnceMoreAndSucceeds() async throws {
        let base = ThrottledRoads(throttles: 1)
        let waits = Waits()
        let router = ThrottleRetryRouter(base: base, wait: .seconds(4), sleep: { waits.add($0) })
        let leg = try await router.leg(from: start, to: a)
        #expect(leg.coordinates.count > 2)
        #expect(base.requests == 2)
        #expect(waits.items == [.seconds(4)])
    }

    @Test func noThrottleIsOneRequestAndNoWait() async throws {
        let base = ThrottledRoads(throttles: 0)
        let waits = Waits()
        _ = try await ThrottleRetryRouter(base: base, sleep: { waits.add($0) }).leg(from: start, to: a)
        #expect(base.requests == 1)
        #expect(waits.items.isEmpty)
    }

    @Test @MainActor func twoThrottlesInARowAreALegFailureForThatLeg() async {
        let base = ThrottledRoads(throttles: 2)
        let router = ThrottleRetryRouter(base: base, sleep: { _ in })
        do {
            _ = try await StopRouting.build(from: start, via: [a], to: end, router: router)
            Issue.record("expected a failure")
        } catch let failure as LegFailure {
            #expect(failure.index == 0)
            #expect(base.requests == 2)
        } catch {
            Issue.record("expected a LegFailure, got \(error)")
        }
    }
}

struct StopRoutingTests {
    // MARK: Joining legs

    @Test func joinedLegsHaveIncreasingOffsetsThatLandAtEachStop() throws {
        let a = move(start, north: 60_000)
        let b = move(start, north: 120_000)
        let end = move(start, north: 200_000)
        let joined = StopRouting.join([
            leg(line(start, a)), leg(line(a, b)), leg(line(b, end)),
        ])
        #expect(joined.stopOffsets.count == 2)
        #expect(joined.stopOffsets[0] < joined.stopOffsets[1])
        let routeLine = RouteLine(Polyline.decode(joined.route.polyline))
        // The encoded line has 5-decimal precision, about a meter.
        let atA = try #require(routeLine.coordinate(atOffset: joined.stopOffsets[0]))
        let atB = try #require(routeLine.coordinate(atOffset: joined.stopOffsets[1]))
        #expect(RouteLine.haversine(atA, a) < 5)
        #expect(RouteLine.haversine(atB, b) < 5)
        #expect(abs(joined.stopOffsets[0] - 60_000) < 20)
        #expect(abs(joined.stopOffsets[1] - 120_000) < 20)
        #expect(abs(joined.route.distance - 200_000) < 50)
    }

    @Test func theSharedJunctionPointIsKeptOnce() {
        let a = move(start, north: 10_000)
        let first = line(start, a)
        let second = line(a, move(start, north: 20_000))
        let joined = StopRouting.join([leg(first), leg(second)])
        #expect(Polyline.decode(joined.route.polyline).count == first.count + second.count - 1)
    }

    @Test func aGapBetweenLegsStaysAndOffsetsStillIncrease() {
        let a = move(start, north: 10_000)
        // The second leg starts 40 m from where the first ended (MapKit snapped to another road).
        let second = line(move(a, east: 40), move(start, north: 20_000, east: 40))
        let joined = StopRouting.join([leg(line(start, a)), leg(second)])
        #expect(joined.stopOffsets[0] > 9_900 && joined.stopOffsets[0] < 10_100)
        #expect(joined.route.distance > 20_000)
    }

    @Test func driveTimesAddUp() {
        let a = move(start, north: 10_000)
        let joined = StopRouting.join([
            leg(line(start, a), seconds: 600), leg(line(a, move(start, north: 20_000)), seconds: 500),
        ])
        #expect(joined.route.travelTime == 1_100)
    }

    @Test @MainActor func buildAsksForOneLegPerStopInOrder() async throws {
        let roads = StraightRoads()
        let stopA = move(start, north: 60_000)
        let stopB = move(start, north: 120_000)
        let end = move(start, north: 200_000)
        let built = try await StopRouting.build(from: start, via: [stopA, stopB], to: end, router: roads)
        #expect(roads.requests == 3)
        #expect(built.stopOffsets.count == 2)
    }

    @Test @MainActor func aLegThatCannotRouteNamesTheStop() async {
        let roads = StraightRoads()
        let stopA = move(start, north: 60_000)
        let end = move(start, north: 200_000)
        roads.noRoadTo = [stopA.latitude]
        await #expect(throws: LegFailure(index: 0, reason: .noRoute)) {
            _ = try await StopRouting.build(from: start, via: [stopA], to: end, router: roads)
        }
        roads.noRoadTo = [end.latitude]
        await #expect(throws: LegFailure(index: 1, reason: .noRoute)) {
            _ = try await StopRouting.build(from: start, via: [stopA], to: end, router: roads)
        }
    }

    @Test @MainActor func legsAlreadyRoutedAreNotAskedForAgain() async throws {
        let roads = StraightRoads()
        let cache = LegCache()
        let a = move(start, north: 60_000)
        let b = move(start, north: 120_000)
        let end = move(start, north: 200_000)
        _ = try await StopRouting.build(from: start, via: [a], to: end, router: roads, cache: cache)
        #expect(roads.requests == 2)
        // A second stop is added: start → a is known; a → b and b → end are new.
        _ = try await StopRouting.build(from: start, via: [a, b], to: end, router: roads, cache: cache)
        #expect(roads.requests == 4)
    }

    // MARK: The other side of the highway

    /// North on the northbound carriageway (east 0) to an interchange `reach` meters past the R&R, round, back
    /// south on the other carriageway to the R&R, which sits on that side.
    private func wrongSideRoute(reach: Double = 3_000, leaving: Bool) -> (line: RouteLine, stopOffset: Double) {
        let rr = move(start, north: 60_000, east: -60)
        var points = line(start, move(start, north: 60_000 + reach))
        points += line(move(start, north: 60_000 + reach, east: -60), rr).dropFirst(0)
        let stopOffset = RouteLine(points).length
        if leaving {
            // On south to the next interchange, round, and back north past the R&R on the other side.
            points += line(rr, move(start, north: 60_000 - reach, east: -60))
            points += line(move(start, north: 60_000 - reach), move(start, north: 120_000))
        }
        return (RouteLine(points), stopOffset)
    }

    @Test func aStopOnTheOtherCarriagewayIsFlaggedWithTheExtraDistance() throws {
        let route = wrongSideRoute(leaving: false)
        let extra = try #require(StopRouting.uTurnExtra(on: route.line, stopOffset: route.stopOffset))
        // Out to the interchange and back: 6 km.
        #expect(extra > 5_500 && extra < 6_500)
    }

    @Test func turningRoundAfterTheStopCountsToo() throws {
        let route = wrongSideRoute(leaving: true)
        let extra = try #require(StopRouting.uTurnExtra(on: route.line, stopOffset: route.stopOffset))
        #expect(extra > 11_000 && extra < 13_000)
    }

    @Test func aStopOnTheRouteIsNotFlagged() {
        let end = move(start, north: 120_000)
        let straight = RouteLine(line(start, end))
        #expect(StopRouting.uTurnExtra(on: straight, stopOffset: 60_000) == nil)
    }

    @Test func aTownStopOnADeadEndRoadIsNotFlagged() {
        // Highway north, exit at 50 km, 5 km east into town and back out the same road, on to the end.
        let exit = move(start, north: 50_000)
        let town = move(exit, east: 5_000)
        var points = line(start, exit)
        points += line(exit, town)
        let stopOffset = RouteLine(points).length
        points += line(town, exit)
        points += line(exit, move(start, north: 120_000))
        #expect(StopRouting.uTurnExtra(on: RouteLine(points), stopOffset: stopOffset) == nil)
    }
}

struct StopListLogicTests {
    private func draft(_ id: String, _ kind: PlannedStopKind = .fuel, offset: Double?) -> StopDraft {
        StopDraft(id: id, name: id, coordinate: start, kind: kind, routeOffset: offset)
    }

    @Test func aNewStopGoesWhereItFallsAlongTheRoute() {
        let items = [draft("a", offset: 30_000), draft("b", offset: 90_000)]
        #expect(StopListLogic.insertIndex(of: draft("x", offset: 10_000), among: items) == 0)
        #expect(StopListLogic.insertIndex(of: draft("x", offset: 60_000), among: items) == 1)
        #expect(StopListLogic.insertIndex(of: draft("x", offset: 120_000), among: items) == 2)
        #expect(StopListLogic.insertIndex(of: draft("x", offset: nil), among: items) == 2)
    }

    @Test func nothingGoesAboveAMeetingPoint() {
        let items = [draft("m", .meet, offset: 0), draft("a", offset: 30_000)]
        #expect(StopListLogic.insertIndex(of: draft("x", offset: 0), among: items) == 1)
        #expect(StopListLogic.insertIndex(of: draft("m2", .meet, offset: 0), among: [draft("a", offset: 30_000)]) == 0)
    }

    @Test func aMeetingPointCanOnlyBeTheFirstStop() {
        #expect(StopListLogic.canMeet(among: []))
        #expect(!StopListLogic.canMeet(among: [draft("a", offset: 1)]))
    }

    @Test func aDragKeepsAMeetingPointFirst() {
        let items = [draft("m", .meet, offset: 0), draft("a", offset: 1), draft("b", offset: 2)]
        #expect(StopListLogic.moved(items, from: IndexSet(integer: 2), to: 0) == nil)
        #expect(StopListLogic.moved(items, from: IndexSet(integer: 0), to: 3) == nil)
        #expect(StopListLogic.moved(items, from: IndexSet(integer: 2), to: 1)?.map(\.id) == ["m", "b", "a"])
        #expect(StopListLogic.moved(items, from: IndexSet(integer: 1), to: 1) == nil)
    }

    @Test func aMeetingPointHasNoLength() {
        let meet = StopDraft(name: "Petronas", coordinate: start, kind: .meet, minutes: 20, meetAt: Fixtures.t0)
        #expect(meet.minutes == nil)
        let fuel = StopDraft(name: "R&R", coordinate: start, kind: .fuel, minutes: 20, meetAt: Fixtures.t0)
        #expect(fuel.minutes == 20)
        #expect(fuel.meetAt == nil)
    }

    @Test func stopTimeAddsUpAndTheListIsCapped() {
        let items = [draft("a", offset: 1), draft("b", offset: 2)].map { var d = $0; d.minutes = 20; return d }
        #expect(StopListLogic.plannedMinutes(items) == 40)
        let full = (0..<PlannedStop.maxCount).map { draft("s\($0)", offset: Double($0)) }
        #expect(!StopListLogic.canAdd(among: full))
        #expect(StopListLogic.canAdd(among: Array(full.dropLast())))
    }
}

struct StopNoteTextTests {
    private func failure(_ place: StopPlanner.Failure.Place, _ reason: RouteError) -> StopPlanner.Failure { .init(place: place, reason: reason) }

    @Test func noRoadAndNoAnswerReadDifferently() {
        #expect(StopNoteText.failureDetail(failure(.stop("a"), .noRoute))
            == "There’s no road to this stop from the one before. Pick another place.")
        #expect(StopNoteText.failureDetail(failure(.stop("a"), .timedOut))
            == "Maps didn’t answer. Try again, or pick another place.")
        #expect(StopNoteText.failureDetail(failure(.stop("a"), .failed("x")))
            == "Maps didn’t answer. Try again, or pick another place.")
        #expect(StopNoteText.failureDetail(failure(.destination, .noRoute)).hasPrefix("There’s no road to the destination"))
        #expect(StopNoteText.failureTitle(failure(.stop("a"), .noRoute), stopName: "Lunch", destinationName: "Ipoh") == "Couldn’t find a road to Lunch")
        #expect(StopNoteText.failureTitle(failure(.destination, .noRoute), stopName: nil, destinationName: "Ipoh") == "Couldn’t find a road to Ipoh")
    }

    @Test func aRefusedSaveAndAQueuedOneAreTold() {
        #expect(StopNoteText.failureTitle(failure(.saving, .failed("x")), stopName: nil, destinationName: "") == "Couldn’t save the stops")
        #expect(StopNoteText.failureDetail(failure(.saving, .failed("x"))) == "The change wasn’t accepted. Try again in a moment.")
        #expect(StopNoteText.queuedTitle == "Not saved yet")
        #expect(StopNoteText.queuedDetail == "It saves when you’re back online.")
    }

    @Test func onlyFuelRestAndToiletAreRestAreas() {
        for kind in [PlannedStopKind.fuel, .rest, .toilet] {
            #expect(StopNoteText.turnBack(kind: kind, extraMeters: 6_000).title == "This R&R is on the other side of the highway")
        }
        for kind in [PlannedStopKind.food, .sight] {
            let text = StopNoteText.turnBack(kind: kind, extraMeters: 6_000)
            #expect(text.title == "This stop is across the road")
            #expect(text.detail == "The route turns back at the next exit, about 6 km extra.")
        }
    }
}

struct StopFormatTests {
    @Test func theLineUnderAStop() {
        let nine = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 9, minute: 0))!
        #expect(StopFormat.detail(kind: .fuel, minutes: 20, meetAt: nil) == "Fuel · 20 min")
        #expect(StopFormat.detail(kind: .food, minutes: nil, meetAt: nil) == "Food")
        #expect(StopFormat.detail(kind: .rest, minutes: 60, meetAt: nil) == "Rest · 1 h")
        #expect(StopFormat.detail(kind: .meet, minutes: nil, meetAt: nine) == "Meet · at 9:00")
        #expect(StopFormat.detail(kind: .meet, minutes: nil, meetAt: nil) == "Meet")
    }

    @Test func theTotalOnTheRouteCard() {
        #expect(StopFormat.total(distance: 205_400, driveSeconds: 2 * 3600 + 40 * 60, stopMinutes: 35)
            == "205 km · 2 h 40 + 35 min of stops")
        #expect(StopFormat.total(distance: 205_400, driveSeconds: 2 * 3600 + 25 * 60, stopMinutes: 0) == "205 km · 2 h 25")
        #expect(StopFormat.total(distance: 80_000, driveSeconds: 2 * 3600 + 5 * 60, stopMinutes: 75)
            == "80 km · 2 h 05 + 1 h 15 min of stops")
        #expect(StopFormat.drive(seconds: 45 * 60) == "45 min")
        #expect(StopFormat.drive(seconds: 2 * 3600) == "2 h")
    }

    @Test func aMeetingTimePickedAsAClockTimeIsTheNextTimeItOccurs() throws {
        let now = Calendar.current.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 10, minute: 0))!
        let nineTomorrow = try #require(StopFormat.nextTime(hour: 9, minute: 0, after: now))
        #expect(nineTomorrow > now)
        #expect(nineTomorrow.timeIntervalSince(now) < 24 * 3600)
        let elevenToday = try #require(StopFormat.nextTime(hour: 11, minute: 0, after: now))
        #expect(elevenToday.timeIntervalSince(now) == 3600)
    }
}

@MainActor
private final class PendingGate {
    private var isOpen = false
    func open() { isOpen = true }
    func wait() async { while !isOpen { try? await Task.sleep(for: .milliseconds(5)) } }
}

@MainActor
struct StopPlannerTests {
    private let end = move(start, north: 200_000)
    private let a = move(start, north: 60_000)
    private let b = move(start, north: 120_000)

    private func trip(route: String = "") -> Trip {
        Trip.fixture(
            organizerId: "u", route: route,
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: end.latitude, longitude: end.longitude)))
    }

    private func planner(_ roads: StraightRoads, saved: SavedPlans) -> StopPlanner {
        let planner = StopPlanner(router: roads, delay: .zero, origin: { start }, save: { saved.plans.append($0) })
        planner.sync(trip: trip(route: Polyline.encode(line(start, end))), stops: [])
        return planner
    }

    private final class SavedPlans { var plans: [StopPlanSave] = [] }

    private func fuel(_ name: String, _ at: CLLocationCoordinate2D, minutes: Int? = 20) -> StopDraft {
        StopDraft(name: name, coordinate: at, kind: .fuel, minutes: minutes)
    }

    @Test func addingAStopRebuildsTheRouteThroughItAndSavesBoth() async throws {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        planner.add(fuel("R&R Tapah", a))
        #expect(planner.status == .building)
        await waitUntil { planner.status == .saved }
        let plan = try #require(saved.plans.last)
        #expect(plan.stops.map(\.name) == ["R&R Tapah"])
        #expect(plan.stops[0].order == 0)
        #expect(abs(plan.stops[0].routeOffset - 60_000) < 20)
        #expect(plan.removedIds.isEmpty)
        // The route goes start → stop → end.
        #expect(roads.requests == 2)
        #expect(abs(plan.route.distance - 200_000) < 50)
        #expect(planner.items.first?.routeOffset == plan.stops[0].routeOffset)
    }

    @Test func movingAndRemovingStopsRebuildsInTheNewOrder() async throws {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        planner.add(fuel("A", a))
        await waitUntil { planner.status == .saved }
        planner.add(fuel("B", b))
        await waitUntil { planner.status == .saved && planner.items.count == 2 }
        #expect(planner.items.map(\.name) == ["A", "B"])
        let requestsBefore = roads.requests

        // Reorder: B first. The road goes start → B → A → end, so it doubles back.
        planner.move(from: IndexSet(integer: 1), to: 0)
        #expect(planner.items.map(\.name) == ["B", "A"])
        await waitUntil { planner.status == .saved && saved.plans.last?.stops.map(\.name) == ["B", "A"] }
        let moved = try #require(saved.plans.last)
        #expect(moved.stops.map(\.order) == [0, 1])
        #expect(moved.stops[0].routeOffset > 119_000 && moved.stops[0].routeOffset < 121_000)
        #expect(moved.stops[1].routeOffset > 179_000 && moved.stops[1].routeOffset < 181_000)
        #expect(roads.requests > requestsBefore)

        let removedId = try #require(planner.items.first?.id)
        planner.remove(id: removedId)
        await waitUntil { planner.status == .saved && saved.plans.last?.stops.count == 1 }
        let last = try #require(saved.plans.last)
        #expect(last.stops.map(\.name) == ["A"])
        #expect(last.removedIds == [removedId])
    }

    @Test func aMeetingPointStartsTheRouteThere() async throws {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        let meet = StopDraft(name: "Petronas Sungai Buloh", coordinate: move(start, north: 5_000), kind: .meet, meetAt: Fixtures.t0)
        planner.add(meet)
        await waitUntil { planner.status == .saved }
        let plan = try #require(saved.plans.last)
        let first = try #require(Polyline.decode(plan.route.polyline).first)
        #expect(RouteLine.haversine(first, meet.coordinate) < 5)
        #expect(plan.stops[0].routeOffset == 0)
        #expect(plan.stops[0].kind == .meet)
        // One leg only: the meeting point to the destination, not the organizer's own start.
        #expect(roads.requests == 1)
        #expect(abs(plan.route.distance - 195_000) < 50)
    }

    @Test func aMeetingPointCannotBeAddedAfterAnotherStop() async {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        planner.add(fuel("A", a))
        await waitUntil { planner.status == .saved }
        planner.add(StopDraft(name: "Meet", coordinate: start, kind: .meet))
        #expect(planner.items.map(\.name) == ["A"])
    }

    @Test func aLegWithNoRoadFlagsItsStopAndSavesNothingUntilItWorks() async throws {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        let lunch = fuel("Lunch, Ipoh Lama", a)
        roads.noRoadTo = [a.latitude]
        planner.add(lunch)
        await waitUntil { if case .failed = planner.status { true } else { false } }
        #expect(planner.status == .failed(.init(place: .stop(lunch.id), reason: .noRoute)))
        #expect(saved.plans.isEmpty)
        #expect(planner.items.map(\.name) == ["Lunch, Ipoh Lama"])

        roads.noRoadTo = []
        planner.retry()
        await waitUntil { planner.status == .saved }
        #expect(saved.plans.count == 1)
    }

    @Test func aFailedLastLegFlagsTheDestination() async {
        let roads = StraightRoads()
        let saved = SavedPlans()
        let planner = planner(roads, saved: saved)
        roads.noRoadTo = [end.latitude]
        planner.add(fuel("A", a))
        await waitUntil { if case .failed = planner.status { true } else { false } }
        #expect(planner.status == .failed(.init(place: .destination, reason: .noRoute)))
    }

    @Test func aSaveQueuedOfflineKeepsThePlanAndSaysItIsNotSavedYetUntilTheServerHasIt() async {
        let roads = StraightRoads()
        let pending = PendingGate()
        let planner = StopPlanner(
            router: roads, delay: .zero, origin: { start }, waitForPending: { await pending.wait() },
            save: { _ in throw ServerWrite.Offline() })
        planner.sync(trip: trip(route: Polyline.encode(line(start, end))), stops: [])
        planner.add(fuel("A", a))
        await waitUntil { planner.queued }
        #expect(planner.queued)
        #expect(planner.status == .saved)
        #expect(planner.items.map(\.name) == ["A"])
        pending.open()
        await waitUntil { !planner.queued }
        #expect(!planner.queued)
    }

    @Test func anEditBeforeTheTripHasLoadedSaysSoInsteadOfWaitingForever() async {
        let planner = StopPlanner(router: StraightRoads(), delay: .zero, origin: { start }, save: { _ in })
        planner.add(fuel("A", a))
        await waitUntil { if case .failed = planner.status { true } else { false } }
        guard case .failed = planner.status else {
            Issue.record("still \(planner.status)")
            return
        }
    }

    @Test func aSaveThatFailsKeepsTheListAndSaysSo() async {
        let roads = StraightRoads()
        struct Offline: Error {}
        let planner = StopPlanner(router: roads, delay: .zero, origin: { start }, save: { _ in throw Offline() })
        planner.sync(trip: trip(route: Polyline.encode(line(start, end))), stops: [])
        planner.add(fuel("A", a))
        await waitUntil { if case .failed = planner.status { true } else { false } }
        guard case .failed(let failure) = planner.status else {
            Issue.record("not failed")
            return
        }
        #expect(failure.place == .saving)
        #expect(planner.items.count == 1)
    }

    @Test func theListFollowsTheTripWhenNothingIsBeingBuilt() {
        let saved = SavedPlans()
        let planner = planner(StraightRoads(), saved: saved)
        let stops = [
            PlannedStop(id: "s2", name: "B", coordinate: GeoPoint(latitude: 1, longitude: 1), routeOffset: 2, kind: .food, order: 1),
            PlannedStop(id: "s1", name: "A", coordinate: GeoPoint(latitude: 1, longitude: 1), routeOffset: 1, kind: .fuel, minutes: 20, order: 0),
        ]
        planner.sync(trip: trip(), stops: stops)
        #expect(planner.items.map(\.id) == ["s1", "s2"])
        #expect(planner.items[0].minutes == 20)
    }

    @Test func aStopWhoseRoadTurnsBackIsFlaggedFromTheSavedRoute() {
        // The wrong-side route from StopRoutingTests, as a saved trip.
        let rr = move(start, north: 60_000, east: -60)
        var points = line(start, move(start, north: 63_000))
        points += line(move(start, north: 63_000, east: -60), rr)
        let stopOffset = RouteLine(points).length
        points += line(rr, move(start, north: 120_000, east: -60))
        let item = StopDraft(id: "s", name: "R&R", coordinate: rr, kind: .fuel, routeOffset: stopOffset)
        let flags = StopPlanner.turnBacks(route: Polyline.encode(points), items: [item])
        #expect((flags["s"] ?? 0) > 5_500)
        let straight = StopPlanner.turnBacks(route: Polyline.encode(line(start, end)), items: [
            StopDraft(id: "s", name: "R&R", coordinate: a, kind: .fuel, routeOffset: 60_000),
        ])
        #expect(straight.isEmpty)
    }
}
