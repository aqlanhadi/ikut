import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

private let r = RouteLine.earthRadius
private let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)

private func move(_ c: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
    CLLocationCoordinate2D(
        latitude: c.latitude + north / r * 180 / .pi,
        longitude: c.longitude + east / (r * cos(c.latitude * .pi / 180)) * 180 / .pi)
}

/// Main route: due east from `origin`, `km` long, a vertex every 500 m.
private func makeMainCoords(km: Int = 100) -> [CLLocationCoordinate2D] {
    stride(from: 0.0, through: Double(km) * 1000, by: 500).map { move(origin, east: $0) }
}

/// A car route starting `south` m south of the main route at `startEast`, running diagonally to
/// join the main route at `mergeEast`, then along it to `endEast`.
private func joiningRoute(startEast: Double = 20_000, south: Double = 10_000, mergeEast: Double = 40_000, endEast: Double = 100_000) -> [CLLocationCoordinate2D] {
    let start = move(origin, north: -south, east: startEast)
    var pts = (0...20).map { i -> CLLocationCoordinate2D in
        let t = Double(i) / 20
        return move(origin, north: -south * (1 - t), east: startEast + (mergeEast - startEast) * t)
    }
    pts[0] = start
    pts += stride(from: mergeEast + 500, through: endEast, by: 500).map { move(origin, east: $0) }
    return pts
}

private func close(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

struct CarRouteLogicTests {
    private let main = RouteLine(makeMainCoords())

    @Test func carOnMainRouteNeedsNoRoute() throws {
        let plan = try #require(CarRouteLogic.planIfOnMain(location: move(origin, north: 80, east: 12_345), main: main))
        #expect(plan.route == nil)
        #expect(plan.state == .convoy)
        #expect(plan.kind == .onMainRoute)
        #expect(close(try #require(plan.mergeOffset), 12_345, 2))
    }

    @Test func thresholdBoundary() {
        #expect(CarRouteLogic.planIfOnMain(location: move(origin, north: 140, east: 5_000), main: main) != nil)
        #expect(CarRouteLogic.planIfOnMain(location: move(origin, north: 160, east: 5_000), main: main) == nil)
    }

    @Test func carElsewhereNeedsRoute() {
        #expect(CarRouteLogic.planIfOnMain(location: move(origin, north: -10_000, east: 20_000), main: main) == nil)
    }

    @Test func joiningRouteMergesAtExpectedOffset() throws {
        let plan = try #require(CarRouteLogic.makePlan(computed: joiningRoute(), main: main))
        #expect(plan.state == .joining)
        #expect(plan.kind == .merges)
        // Within the 50 m tolerance the diagonal is "on" the main route a little before 40 km.
        #expect(close(try #require(plan.mergeOffset), 40_000, 400))
    }

    @Test func storedRouteIsTruncatedPastMerge() throws {
        let computed = joiningRoute()
        let plan = try #require(CarRouteLogic.makePlan(computed: computed, main: main))
        let stored = RouteLine(Polyline.decode(try #require(plan.route)))
        #expect(stored.length < RouteLine(computed).length / 2)
        let merge = try #require(main.mergeOffset(of: stored))
        #expect(stored.length - merge.otherOffset <= CarRouteLogic.tailPastMerge + 5)
        #expect(stored.length - merge.otherOffset >= CarRouteLogic.tailPastMerge - 5)
    }

    /// What `PositionBuilder` derives from the stored route must equal the stored `mergeOffset`.
    @Test func storedMergeAgreesWithPositionBuilder() throws {
        let plan = try #require(CarRouteLogic.makePlan(computed: joiningRoute(), main: main))
        let stored = RouteLine(Polyline.decode(try #require(plan.route)))
        var builder = PositionBuilder(mainRoute: main, carRoute: stored)
        let merge = try #require(main.mergeOffset(of: stored))
        #expect(close(merge.mainOffset, try #require(plan.mergeOffset), 0.5))
        // Driving the stored route: convoyOffset appears exactly when the merge point is passed.
        var firstConvoy: Double?
        for s in stride(from: 0.0, through: stored.length, by: 100) {
            let c = try #require(stored.coordinate(atOffset: s))
            let pos = builder.build(from: LocationFix(latitude: c.latitude, longitude: c.longitude, speed: 20, course: 90, timestamp: Date()), battery: nil)
            if pos.convoyOffset != nil, firstConvoy == nil { firstConvoy = s }
        }
        #expect(close(try #require(firstConvoy), merge.otherOffset, 100))
    }

    @Test func routeThatEndsEarlyJoinsAtItsEnd() throws {
        // Joins at 40 km and stops there (the destination is at the join).
        let computed = joiningRoute(endEast: 40_000)
        let plan = try #require(CarRouteLogic.makePlan(computed: computed, main: main))
        #expect(plan.kind == .merges)
        #expect(close(try #require(plan.mergeOffset), 40_000, 400))
    }

    @Test func neverMergingRouteFallsBackToWholeRouteAndNearestMainPoint() throws {
        // Runs parallel, 2 km south of the main route, ending 2 km south of its end.
        let parallel = stride(from: 10_000.0, through: 100_000, by: 500).map { move(origin, north: -2_000, east: $0) }
        let plan = try #require(CarRouteLogic.makePlan(computed: parallel, main: main))
        #expect(plan.kind == .neverMerges)
        #expect(plan.state == .joining)
        #expect(close(try #require(plan.mergeOffset), 100_000, 5))
        let stored = RouteLine(Polyline.decode(try #require(plan.route)))
        #expect(close(stored.length, RouteLine(parallel).length, 5))
    }

    @Test func degenerateRoutesGiveNoPlan() {
        #expect(CarRouteLogic.makePlan(computed: [origin], main: main) == nil)
        #expect(CarRouteLogic.makePlan(computed: joiningRoute(), main: RouteLine([])) == nil)
    }

    @Test func hasMergedUsesGreaterOrEqual() {
        #expect(!CarRouteLogic.hasMerged(ownOffset: 999.9, ownMergeOffset: 1000))
        #expect(CarRouteLogic.hasMerged(ownOffset: 1000, ownMergeOffset: 1000))
    }

    @Test func truncateEndsAtOffset() {
        let line = RouteLine(makeMainCoords(km: 10))
        let cut = CarRouteLogic.truncate(line, atOffset: 2_250)
        #expect(close(RouteLine(cut).length, 2_250, 1))
        #expect(CarRouteLogic.truncate(line, atOffset: 50_000).count == line.coordinates.count)
    }
}

struct SimplifierTests {
    @Test func collinearPointsCollapse() {
        let out = RouteSimplifier.simplify(makeMainCoords(km: 50), tolerance: 5)
        #expect(out.count == 2)
    }

    @Test func keepsCornersAndStaysWithinTolerance() {
        let pts = [origin, move(origin, east: 5_000), move(origin, north: 5_000, east: 5_000)]
        let dense = RouteLine(pts).coordinates
        #expect(RouteSimplifier.simplify(dense, tolerance: 10).count == 3)

        // A wiggly densified line stays within tolerance of the original.
        let wiggle = (0...2000).map { i in move(origin, north: sin(Double(i) / 20) * 40, east: Double(i) * 20) }
        let simplified = RouteSimplifier.simplify(wiggle, tolerance: 15)
        #expect(simplified.count < wiggle.count / 4)
        let line = RouteLine(simplified)
        let worst = wiggle.compactMap { line.project($0)?.distance }.max() ?? .infinity
        #expect(worst <= 16)
        #expect(simplified.first!.latitude == wiggle.first!.latitude)
        #expect(simplified.last!.longitude == wiggle.last!.longitude)
    }

    @Test func longRouteIsSimplifiedUnderTheCap() {
        // ~400 km, a point every 8 m with sub-meter-scale road wobble: far over any sensible size.
        var seed: UInt64 = 42
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        let pts = (0..<50_000).map { i in
            move(origin, north: sin(Double(i) / 900) * 3_000 + rnd() * 3, east: Double(i) * 8)
        }
        let big = Polyline.encode(pts)
        #expect(big.utf8.count > 100_000)
        let out = RouteSimplifier.simplify(pts, maxEncodedLength: 100_000)
        #expect(Polyline.encode(out).utf8.count <= 100_000)
        // And the plan built from it stays under the cap too.
        let main = RouteLine(pts)
        let plan = CarRouteLogic.makePlan(computed: pts, main: main)
        #expect((plan?.route?.utf8.count ?? 0) <= CarRouteLogic.maxEncodedLength)
    }

    @Test func shortRouteIsUntouched() {
        let pts = joiningRoute()
        #expect(RouteSimplifier.simplify(pts, maxEncodedLength: 100_000).count == pts.count)
    }
}

struct OffRouteDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    private func fire(_ d: inout OffRouteDetector, distanceFromRoute: Double, at time: Date) -> Bool {
        d.observe(distanceFromRoute: distanceFromRoute, at: time)
    }

    @Test func firesAfterConsecutiveFixes() {
        var d = OffRouteDetector()
        for i in 0..<4 { #expect(!fire(&d, distanceFromRoute: 300, at: t(Double(i)))) }
        #expect(fire(&d, distanceFromRoute: 300, at: t(4)))
    }

    @Test func backOnRouteResetsTheRun() {
        var d = OffRouteDetector()
        for i in 0..<4 { _ = d.observe(distanceFromRoute: 300, at: t(Double(i))) }
        #expect(!fire(&d, distanceFromRoute: 20, at: t(4)))
        for i in 5..<9 { #expect(!fire(&d, distanceFromRoute: 300, at: t(Double(i)))) }
        #expect(fire(&d, distanceFromRoute: 300, at: t(9)))
    }

    @Test func firesAfterDurationWithFewFixes() {
        var d = OffRouteDetector()
        #expect(!fire(&d, distanceFromRoute: 300, at: t(0)))
        #expect(!fire(&d, distanceFromRoute: 300, at: t(14)))
        #expect(fire(&d, distanceFromRoute: 300, at: t(15)))
    }

    @Test func nearRouteNeverFires() {
        var d = OffRouteDetector()
        for i in 0..<100 { #expect(!fire(&d, distanceFromRoute: 99, at: t(Double(i)))) }
    }

    @Test func throttlesToOncePerMinuteThenFiresAsSoonAsAllowed() {
        var d = OffRouteDetector()
        for i in 0..<5 { _ = d.observe(distanceFromRoute: 300, at: t(Double(i))) }
        d.markRecomputed(at: t(4))
        // Still off-route: confirmed again quickly, but throttled until 60 s after the recompute.
        for i in 5..<64 { #expect(!fire(&d, distanceFromRoute: 300, at: t(Double(i)))) }
        #expect(fire(&d, distanceFromRoute: 300, at: t(64)))
        #expect(fire(&d, distanceFromRoute: 300, at: t(65)))
    }
}

private struct CarRouteFakeDirections: CarRouteDirections {
    var routes: Box
    final class Box: @unchecked Sendable {
        var queue: [[CLLocationCoordinate2D]]
        var calls: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        var fail = false
        init(_ q: [[CLLocationCoordinate2D]]) { queue = q }
    }
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        routes.calls.append((from, to))
        if routes.fail { throw RouteError.noRoute }
        return routes.queue.count > 1 ? routes.queue.removeFirst() : routes.queue[0]
    }
}

private final class CarRouteFakeWriter: CarRouteWriting, @unchecked Sendable {
    var writes: [CarRoutePlan] = []
    func write(_ plan: CarRoutePlan, tripId: String, carId: String) async throws { writes.append(plan) }
}

@MainActor
struct CarRouteServiceTests {
    private let mainCoords = makeMainCoords()
    private var mainString: String { Polyline.encode(mainCoords) }
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    private func fix(_ c: CLLocationCoordinate2D, at s: Double) -> LocationFix {
        LocationFix(latitude: c.latitude, longitude: c.longitude, speed: 20, course: 90, timestamp: t0.addingTimeInterval(s))
    }

    private func service(_ box: CarRouteFakeDirections.Box, _ writer: CarRouteFakeWriter, route: String? = nil, state: CarState = .joining) throws -> CarRouteService {
        try CarRouteService(
            tripId: "t", carId: "c", mainRoute: mainString, destination: mainCoords.last!,
            route: route, state: state, directions: CarRouteFakeDirections(routes: box), writer: writer)
    }

    @Test func onMainRouteWritesConvoyWithoutDirections() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute()])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        let plan = try await s.ensureRoute(at: move(origin, north: 30, east: 7_000))
        #expect(plan.kind == .onMainRoute)
        #expect(box.calls.isEmpty)
        #expect(writer.writes == [plan])
        #expect(s.state == .convoy)
        #expect(s.routeLine == nil)
    }

    @Test func offRouteStartComputesAndWritesJoiningRoute() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute()])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        let start = move(origin, north: -10_000, east: 20_000)
        let plan = try await s.ensureRoute(at: start)
        #expect(box.calls.count == 1)
        #expect(box.calls[0].1.longitude == mainCoords.last!.longitude)
        #expect(plan.state == .joining)
        #expect(plan.route != nil)
        #expect(s.state == .joining)
        #expect(s.ownMergeOffset != nil)
    }

    @Test func mergeIsMarkedWhenOffsetPassesMergePoint() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute()])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        try await s.ensureRoute(at: move(origin, north: -10_000, east: 20_000))
        let own = try #require(s.routeLine)
        let merge = try #require(s.ownMergeOffset)
        var events: [CarRouteEvent] = []
        var clock = 0.0
        for off in stride(from: 0.0, to: merge - 50, by: 200) {
            events.append(await s.handle(fix: fix(try #require(own.coordinate(atOffset: off)), at: clock)))
            clock += 1
        }
        #expect(events.allSatisfy { $0 == .none })
        #expect(s.state == .joining)
        let e = await s.handle(fix: fix(try #require(own.coordinate(atOffset: merge + 10)), at: clock))
        #expect(e == .merged)
        #expect(s.state == .convoy)
        let last = try #require(writer.writes.last)
        #expect(last.state == .convoy)
        #expect(last.route == writer.writes.first?.route)
        #expect(last.mergeOffset == writer.writes.first?.mergeOffset)
        // Merged once only.
        let again = await s.handle(fix: fix(try #require(own.coordinate(atOffset: merge + 100)), at: clock + 1))
        #expect(again == .none)
    }

    @Test func offRouteRecomputesOnceAndThrottles() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute(), joiningRoute(startEast: 25_000, south: 6_000)])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        try await s.ensureRoute(at: move(origin, north: -10_000, east: 20_000))
        // The car turns off: 3 km west of its route's start, far from both routes.
        let lost = move(origin, north: -15_000, east: 5_000)
        var events: [CarRouteEvent] = []
        for i in 0..<5 { events.append(await s.handle(fix: fix(lost, at: Double(i)))) }
        #expect(events[0..<4].allSatisfy { $0 == .none })
        guard case .rerouted(let plan) = events[4] else { Issue.record("expected reroute, got \(events[4])"); return }
        #expect(plan.state == .joining)
        #expect(box.calls.count == 2)
        // Still lost: no new directions request for a minute.
        for i in 5..<60 { _ = await s.handle(fix: fix(lost, at: Double(i))) }
        #expect(box.calls.count == 2)
        let later = await s.handle(fix: fix(lost, at: 64))
        if case .rerouted = later {} else { Issue.record("expected reroute after throttle, got \(later)") }
        #expect(box.calls.count == 3)
    }

    @Test func failedRecomputeIsReportedAndThrottled() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute()])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        try await s.ensureRoute(at: move(origin, north: -10_000, east: 20_000))
        box.fail = true
        let lost = move(origin, north: -15_000, east: 5_000)
        var last: CarRouteEvent = .none
        for i in 0..<5 { last = await s.handle(fix: fix(lost, at: Double(i))) }
        guard case .failed = last else { Issue.record("expected failure, got \(last)"); return }
        #expect(s.routeLine != nil)
        for i in 5..<30 { _ = await s.handle(fix: fix(lost, at: Double(i))) }
        #expect(box.calls.count == 2)
    }

    @Test func convoyCarLeavingMainRouteGetsOwnRoute() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute(startEast: 50_000, south: 8_000, mergeEast: 60_000)])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer, state: .convoy)
        let off = move(origin, north: -8_000, east: 50_000)
        var last: CarRouteEvent = .none
        for i in 0..<5 { last = await s.handle(fix: fix(off, at: Double(i))) }
        guard case .rerouted(let plan) = last else { Issue.record("expected reroute, got \(last)"); return }
        #expect(plan.state == .joining)
        #expect(s.state == .joining)
        #expect(s.routeLine != nil)
    }

    @Test func resumedConvoyCarOnMainRouteStaysQuiet() async throws {
        let box = CarRouteFakeDirections.Box([joiningRoute()])
        let s = try service(box, CarRouteFakeWriter(), state: .convoy)
        for i in 0..<20 {
            let e = await s.handle(fix: fix(move(origin, north: 40, east: 3_000 + Double(i) * 30), at: Double(i)))
            #expect(e == .none)
        }
        #expect(box.calls.isEmpty)
    }

    @Test func neverMergingCarIsMarkedConvoyWhenItReachesTheMainRoute() async throws {
        let parallel = stride(from: 10_000.0, through: 100_000, by: 500).map { move(origin, north: -2_000, east: $0) }
        let box = CarRouteFakeDirections.Box([parallel])
        let writer = CarRouteFakeWriter()
        let s = try service(box, writer)
        let plan = try await s.ensureRoute(at: parallel[0])
        #expect(plan.kind == .neverMerges)
        #expect(s.ownMergeOffset == nil)
        #expect(await s.handle(fix: fix(parallel[3], at: 0)) == .none)
        #expect(await s.handle(fix: fix(move(origin, north: 20, east: 90_000), at: 1)) == .merged)
    }

    @Test func invalidMainRouteThrows() {
        #expect(throws: CarRouteError.invalidMainRoute) {
            try CarRouteService(tripId: "t", carId: "c", mainRoute: "", destination: origin)
        }
    }
}

/// Runs against the local emulators; see TripServiceEmulatorTests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct CarRouteEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func trackerWritesRouteMergeOffsetAndState() async throws {
        let organizer = AuthModel()
        try await organizer.signInAsGuest(name: "Aqlan")
        let uid = try #require(Auth.auth().currentUser?.uid)
        let main = makeMainCoords()
        let ids = try await TripService.createTrip(
            name: "Route test \(UUID().uuidString.prefix(8))",
            destination: DestinationResult(name: "End", subtitle: "", coordinate: main.last!),
            route: BuiltRoute(distance: 100_000, travelTime: 3_600, name: "", polyline: Polyline.encode(main)),
            organizer: TripOrganizer(id: uid, displayName: "Aqlan"),
            carName: "Aqlan's Myvi", carColor: TripService.palette[0])
        let carPath = FirestorePaths.car(tripId: ids.tripId, carId: ids.carId)

        let service = try CarRouteService(
            tripId: ids.tripId, carId: ids.carId, mainRoute: Polyline.encode(main), destination: main.last!,
            directions: CarRouteFakeDirections(routes: .init([joiningRoute()])))
        let plan = try await service.ensureRoute(at: move(origin, north: -10_000, east: 20_000))
        var car = try await Firestore.firestore().document(carPath).getDocument(as: Car.self)
        #expect(car.state == .joining)
        #expect(car.route == plan.route)
        #expect(car.mergeOffset == plan.mergeOffset)
        #expect(car.trackerUserId == uid)

        // The merge write and the on-main write (which deletes route) are accepted too.
        let own = try #require(service.routeLine)
        let merge = try #require(service.ownMergeOffset)
        let event = await service.handle(fix: LocationFix(
            latitude: own.coordinate(atOffset: merge + 10)!.latitude, longitude: own.coordinate(atOffset: merge + 10)!.longitude,
            speed: 20, course: 90, timestamp: Date()))
        #expect(event == .merged)
        car = try await Firestore.firestore().document(carPath).getDocument(as: Car.self)
        #expect(car.state == .convoy)
        #expect(car.route == plan.route)

        let onMain = try await service.ensureRoute(at: move(origin, east: 9_000))
        #expect(onMain.kind == .onMainRoute)
        car = try await Firestore.firestore().document(carPath).getDocument(as: Car.self)
        #expect(car.route == nil)
        #expect(car.state == .convoy)
        #expect(car.mergeOffset != nil)

        // A member who is not this car's tracker is rejected.
        let code = try await Firestore.firestore().document(FirestorePaths.trip(ids.tripId)).getDocument(as: Trip.self).code
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        _ = try await LiveJoinAPI().join(
            code: code, displayName: "Daniel", car: .new(name: "Daniel's City", color: TripService.palette[1]), tracker: true)
        await #expect(throws: Error.self) {
            try await FirestoreCarRouteWriter().write(plan, tripId: ids.tripId, carId: ids.carId)
        }
        car = try await Firestore.firestore().document(carPath).getDocument(as: Car.self)
        #expect(car.route == nil)
    }
}
