import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// D25 4d: the main route rebuilt mid-trip from where the organizer is, through the stops still ahead.

/// `north` and `east` meters from the origin.
private func at(north: Double, east: Double = 0) -> CLLocationCoordinate2D {
    move(origin, north: north, east: east)
}

/// The trip as planned: north from the meeting point, out east to a town at 70 km and back to the highway at 80 km,
/// through R&R Tapah at 120 km, to Ipoh at 200 km.
private let town = at(north: 70_000, east: 8_000)
private let tapah = at(north: 120_000)
private let ipoh = at(north: 200_000)
private let oldCoordinates = line(origin, at(north: 60_000)) + line(at(north: 60_000), town).dropFirst()
    + line(town, at(north: 80_000)).dropFirst() + line(at(north: 80_000), ipoh).dropFirst()
private let oldLine = RouteLine(oldCoordinates)
private let oldRoute = Polyline.encode(oldCoordinates)

private func stop(
    _ id: String, _ c: CLLocationCoordinate2D, order: Int, kind: PlannedStopKind = .fuel, skipped: Bool = false,
    left: Bool = false, arrived: Bool = false
) -> PlannedStop {
    PlannedStop.fixture(
        id, name: id, offset: oldLine.project(c)?.offset ?? 0, coordinate: GeoPoint(latitude: c.latitude, longitude: c.longitude),
        kind: kind, minutes: nil, order: order, skipped: skipped ? true : nil,
        arrivedAt: arrived ? Date(timeIntervalSince1970: 2_000) : nil, leftAt: left ? Date(timeIntervalSince1970: 1_000) : nil)
}

/// The meeting point (left), a fuel stop the organizer drove past at 30 km, the town (skipped for everyone), Tapah.
private let stops = [
    stop("Meet", origin, order: 0, kind: .meet, left: true),
    stop("Petronas", at(north: 30_000), order: 1),
    stop("Bidor", town, order: 2, kind: .food, skipped: true),
    stop("R&R Tapah", tapah, order: 3, kind: .rest),
]

private func input(organizer: CLLocationCoordinate2D = at(north: 50_000), stops: [PlannedStop] = stops) -> RouteRebuild.Input {
    RouteRebuild.Input(
        route: oldRoute, routeSeconds: 9_000, stops: stops, destination: ipoh, destinationName: "Ipoh",
        organizer: organizer, organizerOffset: oldLine.project(organizer)?.offset)
}


@MainActor
struct RouteRebuildTests {
    @Test func theRouteGoesFromTheOrganizerThroughTheStopsAheadToTheDestination() async throws {
        let result = try await RouteRebuild.build(input(), router: StraightRoads())
        let new = RouteLine(Polyline.decode(result.route.polyline))
        // Straight north now: 200 km instead of the detour through the town.
        #expect(close(new.length, 200_000, 50))
        #expect(oldLine.length > new.length + 5_000)
        // Only Tapah moves: the meeting point and the stop passed are behind, the town is skipped.
        #expect(Set(result.offsets.keys) == ["R&R Tapah"])
        let offset = try #require(result.offsets["R&R Tapah"])
        #expect(close(offset, 120_000, 50))
        #expect(RouteLine.haversine(try #require(new.coordinate(atOffset: offset)), tapah) < 20)
        #expect(result.sentence == "The route now goes through R&R Tapah and Ipoh")
    }

    /// Answer 1: a car behind the organizer reads the same offset on both lines, so the convoy order holds while
    /// cars still project on the old one.
    @Test func behindTheOrganizerOffsetsAreTheSameOnBothLines() async throws {
        let result = try await RouteRebuild.build(input(), router: StraightRoads())
        let new = RouteLine(Polyline.decode(result.route.polyline))
        for north in [0.0, 10_000, 30_000, 49_000] {
            let car = at(north: north, east: 20)
            var onOld = PositionBuilder(mainRoute: oldLine, carRoute: nil)
            var onNew = PositionBuilder(mainRoute: new, carRoute: nil)
            let fix = LocationFix(latitude: car.latitude, longitude: car.longitude, speed: 25, course: 0, timestamp: Date())
            #expect(close(onOld.build(from: fix, battery: nil).routeOffset, onNew.build(from: fix, battery: nil).routeOffset, 3))
        }
        // The stops behind keep their offsets, and those still fall on the new line where the stop is.
        let passed = stops[1]
        #expect(RouteLine.haversine(try #require(new.coordinate(atOffset: passed.routeOffset)), at(north: 30_000)) < 20)
    }

    /// The driving time keeps the old route's share for the stretch behind and adds the new legs'.
    @Test func theDrivingTimeIsTheKeptShareAndTheNewLegs() async throws {
        let result = try await RouteRebuild.build(input(), router: StraightRoads())
        let kept = 9_000 * 50_000 / oldLine.length
        #expect(close(result.route.travelTime, kept + 150_000 / 25, 5))
    }

    /// Answer 2: a hazard on the direct road, off the old detour, is on the new route by its coordinate.
    @Test func aHazardOnTheDirectRoadIsOnTheNewRoute() async throws {
        let result = try await RouteRebuild.build(input(), router: StraightRoads())
        let new = RouteLine(Polyline.decode(result.route.polyline))
        let spot = at(north: 70_000)
        let event = TripEvent(
            type: .debris, location: GeoPoint(latitude: spot.latitude, longitude: spot.longitude), heading: 0,
            routeOffset: 1, authorId: "u", carId: "c", createdAt: Date())
        #expect(HazardGeometry.offset(of: event, on: oldLine, tolerance: 60) == nil)
        #expect(close(try #require(HazardGeometry.offset(of: event, on: new, tolerance: 60)), 70_000, 30))
    }

    /// Answer 3 (#235): a car that kept to the direct road past the skipped town went joining; on the rebuilt
    /// route its next start reads it as a convoy car, without asking for a route of its own.
    @Test func aCarOnTheDirectRoadIsConvoyAgain() async throws {
        let result = try await RouteRebuild.build(input(), router: StraightRoads())
        let car = at(north: 72_000, east: 30)
        let directions = CarRouteFakeDirections(routes: .init())
        let writer = CarRouteFakeWriter()
        let before = try CarRouteService(
            tripId: "t", carId: "c", mainRoute: oldRoute, destination: ipoh, state: .joining,
            directions: directions, writer: writer)
        #expect(CarRouteLogic.planIfOnMain(location: car, main: oldLine) == nil)
        _ = before
        let after = try CarRouteService(
            tripId: "t", carId: "c", mainRoute: result.route.polyline, destination: ipoh, state: .joining,
            directions: directions, writer: writer)
        let plan = try await after.ensureRoute(at: car)
        #expect(plan.kind == .onMainRoute)
        #expect(plan.route == nil)
        #expect(after.state == .convoy)
        #expect(directions.routes.calls.isEmpty)
    }

    @Test func aStopTheLeadCarIsAtStaysOnTheRouteWithItsOffset() async throws {
        var withArrival = stops
        withArrival[3] = stop("R&R Tapah", tapah, order: 3, kind: .rest, arrived: true)
        let result = try await RouteRebuild.build(input(organizer: at(north: 119_900), stops: withArrival), router: StraightRoads())
        #expect(result.offsets.isEmpty)
        #expect(result.sentence == "The route now goes through R&R Tapah and Ipoh")
    }

    @Test func withNoStopsAheadItGoesStraightToTheDestination() async throws {
        let result = try await RouteRebuild.build(input(organizer: at(north: 150_000)), router: StraightRoads())
        #expect(result.offsets.isEmpty)
        #expect(result.sentence == "The route now goes straight to Ipoh")
    }

    /// The new legs start on the old route where the organizer is nearest: well off it (a petrol station down a side
    /// road) the line does not jump across country, and close to it the organizer's own fix is never a point of the
    /// shared route (their sharing may be paused).
    @Test func theNewLegsStartOnTheRouteNeverAtTheOrganizer() async throws {
        for east in [1_000.0, 100, 20] {
            let roads = StraightRoads()
            let organizer = at(north: 50_000, east: east)
            let result = try await RouteRebuild.build(input(organizer: organizer), router: roads)
            #expect(RouteLine.haversine(try #require(roads.starts.first), at(north: 50_000)) < 5)
            let points = Polyline.decode(result.route.polyline)
            #expect(points.allSatisfy { RouteLine.haversine($0, organizer) > east - 5 })
        }
    }

    @Test func sentences() {
        #expect(RouteRebuild.sentence(through: ["R&R Tapah", "Ipoh"]) == "The route now goes through R&R Tapah and Ipoh")
        #expect(RouteRebuild.sentence(through: ["Bidor", "R&R Tapah", "Ipoh"])
            == "The route now goes through Bidor, R&R Tapah and Ipoh")
        #expect(RouteRebuild.sentence(through: ["Ipoh"]) == "The route now goes straight to Ipoh")
    }
}

/// Answer 4: the skip lands on its own; the rebuild after it keeps trying until Maps answers.
@MainActor
struct RouteRebuilderTests {
    private func defaults() -> UserDefaults {
        let name = "RouteRebuilderTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func settle(_ rebuilder: RouteRebuilder) async {
        for _ in 0..<2_000 where rebuilder.isPending { await Task.yield() }
    }

    @Test func theRebuildKeepsTryingUntilMapsAnswers() async throws {
        let sleeps = Waits(hangFor: RouteRebuilder.noticeTime)
        let store = defaults()
        var writes: [RouteRebuild.Result] = []
        let rebuilder = RouteRebuilder(
            tripId: "t1", router: StraightRoads(failures: 2), defaults: store, sleep: { try await sleeps.sleep($0) }
        ) { result, _ in writes.append(result) }
        rebuilder.input = { input() }
        rebuilder.request()
        #expect(store.bool(forKey: "routeRebuild.pending.t1"))
        await settle(rebuilder)
        #expect(!rebuilder.isPending)
        #expect(Array(sleeps.items.prefix(2)) == [.seconds(15), .seconds(30)])
        #expect(writes.count == 1)
        #expect(rebuilder.notice == RouteRebuilder.Notice(text: "The route now goes through R&R Tapah and Ipoh", waiting: false))
        #expect(!store.bool(forKey: "routeRebuild.pending.t1"))
        rebuilder.cancel()
    }

    @Test func whileItWaitsTheOrganizerReadsOneLine() async throws {
        let store = defaults()
        let rebuilder = RouteRebuilder(
            tripId: "t2", router: StraightRoads(failures: 100, error: RouteError.timedOut), defaults: store, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        ) { _, _ in }
        rebuilder.input = { input() }
        rebuilder.request()
        for _ in 0..<2_000 where rebuilder.notice == nil { await Task.yield() }
        #expect(rebuilder.notice == RouteRebuilder.Notice(text: "The route will change once you have signal again", waiting: true))
        #expect(rebuilder.isPending)
        rebuilder.cancel()
    }

    /// The waiting line says what it waits for: signal (Maps or the network), a location fix, or a road Maps finds.
    @Test func theWaitingLineSaysWhatItWaitsFor() async throws {
        let cases: [(Error, String)] = [
            (LegFailure(index: 0, reason: .timedOut), "The route will change once you have signal again"),
            (LegFailure(index: 1, reason: .failed("The Internet connection appears to be offline.")),
             "The route will change once you have signal again"),
            (NSError(domain: "FIRFirestoreErrorDomain", code: 14), "The route will change once you have signal again"),
            (RouteError.locationUnavailable, "The route will change once your phone finds where you are"),
            (LegFailure(index: 0, reason: .noRoute), "Maps can’t find a road for the new route yet. Trying again soon."),
        ]
        for (error, line) in cases { #expect(RouteRebuilder.waitingLine(for: error) == line) }

        // No fix yet: the input throws, and the organizer reads the location line.
        let rebuilder = RouteRebuilder(
            tripId: "t6", router: StraightRoads(), defaults: defaults(), sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        ) { _, _ in }
        rebuilder.input = { throw RouteError.locationUnavailable }
        rebuilder.request()
        for _ in 0..<2_000 where rebuilder.notice == nil { await Task.yield() }
        #expect(rebuilder.notice?.text == "The route will change once your phone finds where you are")
        rebuilder.cancel()
    }

    @Test func aWishFromBeforeARelaunchIsCarriedOut() async throws {
        let store = defaults()
        store.set(true, forKey: "routeRebuild.pending.t3")
        var writes = 0
        let rebuilder = RouteRebuilder(tripId: "t3", router: StraightRoads(), defaults: store, sleep: { _ in }) { _, _ in writes += 1 }
        rebuilder.input = { input() }
        rebuilder.resumeIfPending()
        await settle(rebuilder)
        #expect(writes == 1)
        #expect(!store.bool(forKey: "routeRebuild.pending.t3"))
        rebuilder.cancel()
    }

    /// Not the organizer any more, or the trip ended: nothing to rebuild, the wish goes.
    @Test func withNothingToRebuildTheWishIsDropped() async throws {
        let store = defaults()
        var writes = 0
        let rebuilder = RouteRebuilder(tripId: "t4", router: StraightRoads(), defaults: store, sleep: { _ in }) { _, _ in writes += 1 }
        rebuilder.request()
        await settle(rebuilder)
        #expect(writes == 0)
        #expect(rebuilder.notice == nil)
        #expect(!store.bool(forKey: "routeRebuild.pending.t4"))
    }

    @Test func aNewDestinationIsWrittenWithTheRoute() async throws {
        var written: (RouteRebuild.Result, DestinationResult?)?
        let rebuilder = RouteRebuilder(tripId: "t5", router: StraightRoads(), defaults: defaults(), sleep: { _ in }) { written = ($0, $1) }
        rebuilder.input = { input() }
        let kampar = DestinationResult(name: "Kampar", subtitle: "", coordinate: at(north: 160_000))
        try await rebuilder.changeDestination(to: kampar)
        let (result, destination) = try #require(written)
        #expect(destination?.name == "Kampar")
        #expect(close(RouteLine(Polyline.decode(result.route.polyline)).length, 160_000, 50))
        #expect(result.sentence == "The route now goes through R&R Tapah and Kampar")
    }

    /// A retry still building with the old destination when the organizer picks a new one is stopped and waited
    /// for: the last write carries the new destination and a route to it.
    @Test func aNewDestinationIsNeverOverwrittenByARetryInFlight() async throws {
        let roads = SlowRoads()
        var writes: [(RouteRebuild.Result, DestinationResult?)] = []
        let rebuilder = RouteRebuilder(tripId: "t7", router: roads, defaults: defaults(), sleep: { _ in }) {
            writes.append(($0, $1))
        }
        rebuilder.input = { input() }
        rebuilder.request()
        // The retry is asking Maps for its first leg.
        for _ in 0..<2_000 where roads.waiting == 0 { await Task.yield() }
        #expect(roads.waiting == 1)
        let kampar = DestinationResult(name: "Kampar", subtitle: "", coordinate: at(north: 160_000))
        let change = Task { @MainActor in try await rebuilder.changeDestination(to: kampar) }
        for _ in 0..<200 { await Task.yield() }
        roads.open()
        try await change.value
        // Long enough for a stale retry, had it kept going, to finish and write.
        try await Task.sleep(for: .milliseconds(300))
        let (last, lastDestination) = try #require(writes.last)
        #expect(lastDestination?.name == "Kampar")
        #expect(close(RouteLine(Polyline.decode(last.route.polyline)).length, 160_000, 50))
        #expect(writes.allSatisfy { $0.1?.name == "Kampar" })
        #expect(!rebuilder.isPending)
        rebuilder.cancel()
    }

    /// The search says what went wrong in plain words: Maps' own reasons, else one line, never Firestore's or
    /// MapKit's text.
    @Test func aMidTripChangeThatFailsSaysSoPlainly() async throws {
        let model = CreateTripModel()
        let kampar = DestinationResult(name: "Kampar", subtitle: "", coordinate: at(north: 160_000))
        let cases: [(Error, String)] = [
            (LegFailure(index: 0, reason: .noRoute), "There’s no road to that place. Pick another."),
            (LegFailure(index: 1, reason: .failed("The operation couldn’t be completed.")),
             "Couldn’t change the route. Check your signal and try again."),
            (RouteError.locationUnavailable, "Can’t find where you are. Check that location is on, then try again."),
            (NSError(domain: "FIRFirestoreErrorDomain", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing or insufficient permissions."]),
             "Couldn’t change the route. Check your signal and try again."),
        ]
        for (error, message) in cases {
            #expect(await model.use(kampar, rebuild: { _ in throw error }) == false)
            #expect(model.errorMessage == message)
        }
        // Through the rebuilder with a router that fails: no LegFailure text on screen.
        let rebuilder = RouteRebuilder(
            tripId: "t8", router: StraightRoads(failures: 1, error: NSError(domain: "MKErrorDomain", code: 1)),
            defaults: defaults(), sleep: { _ in }
        ) { _, _ in }
        rebuilder.input = { input() }
        #expect(await model.use(kampar, rebuild: { try await rebuilder.changeDestination(to: $0) }) == false)
        #expect(model.errorMessage == "Couldn’t change the route. Check your signal and try again.")
    }
}

/// Roads that hold the first leg asked for until `open()`, so a test can act while a rebuild is asking Maps; the
/// legs after it answer at once.
private final class SlowRoads: LegRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _waiting = 0
    private var _open = false
    var waiting: Int { lock.withLock { _waiting } }
    func open() { lock.withLock { _open = true } }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        let first = lock.withLock { _waiting += 1; return _waiting == 1 }
        while first, !lock.withLock({ _open }) { try await Task.sleep(for: .milliseconds(5)) }
        let points = line(from, to)
        let length = RouteLine(points).length
        return RouteLeg(coordinates: points, distance: length, travelTime: length / 25, name: "E1")
    }
}
