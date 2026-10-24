import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// Synthetic geometry: the main route runs east along latitude 3 from longitude 101 (about 1,112 m per
/// 0.01 deg). A joining route comes up from the south at longitude 101.03 (2.2 km), then follows the
/// main route east, so it merges at about main offset 3,336 m.
private enum Fixture {
    static let now = Fixtures.t0
    static let main = RouteLine((0...10).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.01) })
    static let joining = RouteLine(
        [CLLocationCoordinate2D(latitude: 2.98, longitude: 101.03)]
            + (3...10).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.01) })
    static var merge: Double { main.mergeOffset(of: joining)!.mainOffset }
    static var joiningLeg: Double { main.mergeOffset(of: joining)!.otherOffset }

    static func main(at offset: Double, north: Double = 0) -> CLLocationCoordinate2D {
        let c = main.coordinate(atOffset: offset)!
        return CLLocationCoordinate2D(latitude: c.latitude + north / metersPerDegree, longitude: c.longitude)
    }

    static func event(
        _ type: EventType = .debris, id: String = "e1", at offset: Double, north: Double = 0,
        author: String = "u-other", car: String = "c-other", age: TimeInterval = 240,
        routeOffset: Double? = nil
    ) -> TripEvent {
        let c = main(at: offset, north: north)
        var e = TripEvent(
            type: type, location: GeoPoint(latitude: c.latitude, longitude: c.longitude), heading: 90,
            routeOffset: routeOffset ?? offset, authorId: author, carId: car,
            createdAt: now.addingTimeInterval(-age))
        e.id = id
        return e
    }

    static func car(_ id: String, joining: Bool = false, merge: Double? = nil, route: String? = nil) -> Car {
        Car.fixture(id, state: joining ? .joining : .convoy, route: route, mergeOffset: merge)
    }

    static func position(convoy: Double?, own: Double? = nil, age: TimeInterval = 1) -> Position {
        let c = main(at: convoy ?? 0)
        return Position.fixture(
            location: GeoPoint(latitude: c.latitude, longitude: c.longitude), routeOffset: own ?? convoy ?? 0,
            convoyOffset: convoy, updatedAt: now.addingTimeInterval(-age))
    }
}

struct HazardLogicTests {
    private typealias F = Fixture

    private func passed(
        _ event: TripEvent, cars: [Car], positions: [String: Position],
        own: [String: RouteLine] = [:], now: Date = F.now
    ) -> Bool {
        var cache = HazardOffsetCache()
        return HazardLogic.isPassedByAll(
            event: event, cars: cars, positions: positions, mainRoute: F.main, ownRoutes: own, now: now,
            cache: &cache)
    }

    // MARK: Offsets

    @Test func joiningRouteGeometry() {
        #expect(abs(F.merge - 3_336) < 30)
        #expect(abs(F.joiningLeg - 2_224) < 80) // merge is where it stays within 50 m
    }

    @Test func mainOffsetOfEventReportedFromJoiningRoute() throws {
        // Reported on the shared stretch from a joining car: its routeOffset is on the joining route.
        let location = F.main(at: 5_560)
        let ownOffset = try #require(F.joining.project(location)).offset
        let event = F.event(at: 5_560, routeOffset: ownOffset)
        #expect(abs(ownOffset - 4_449) < 40)
        let main = try #require(HazardGeometry.offset(of: event, on: F.main, tolerance: 50))
        #expect(abs(main - 5_560) < 5)
        #expect(abs(main - event.routeOffset) > 1_000)
    }

    @Test func eventOnJoiningLegIsNotOnMainRoute() throws {
        let c = try #require(F.joining.coordinate(atOffset: 1_000))
        var event = F.event(at: 0)
        event.location = GeoPoint(latitude: c.latitude, longitude: c.longitude)
        #expect(HazardGeometry.offset(of: event, on: F.main, tolerance: 50) == nil)
        let own = try #require(HazardGeometry.offset(of: event, on: F.joining, tolerance: 50))
        #expect(abs(own - 1_000) < 5)
    }

    @Test func lateralToleranceBoundary() {
        #expect(HazardGeometry.offset(of: F.event(at: 4_000, north: 40), on: F.main, tolerance: 50) != nil)
        #expect(HazardGeometry.offset(of: F.event(at: 4_000, north: 60), on: F.main, tolerance: 50) == nil)
        #expect(HazardGeometry.offset(of: F.event(at: 4_000), on: nil, tolerance: 50) == nil)
    }

    // MARK: Passed by all

    @Test func passedWhenEveryConvoyCarIsBeyondMargin() {
        let event = F.event(at: 5_000)
        let cars = [F.car("1"), F.car("2")]
        #expect(passed(event, cars: cars, positions: ["1": F.position(convoy: 6_000), "2": F.position(convoy: 5_200)]))
        // Within the 100 m margin does not count.
        #expect(!passed(event, cars: cars, positions: ["1": F.position(convoy: 6_000), "2": F.position(convoy: 5_050)]))
        #expect(!passed(event, cars: cars, positions: ["1": F.position(convoy: 6_000), "2": F.position(convoy: 4_000)]))
    }

    @Test func noCarsOrNoPositionsMeansNotPassed() {
        let event = F.event(at: 5_000)
        #expect(!passed(event, cars: [], positions: [:]))
        #expect(!passed(event, cars: [F.car("1")], positions: [:]))
    }

    @Test func staleCarsAreIgnored() {
        let event = F.event(at: 5_000)
        let cars = [F.car("1"), F.car("2")]
        // Car 2 is behind but its position is 2 minutes old: it does not hold the marker.
        #expect(passed(event, cars: cars, positions: [
            "1": F.position(convoy: 6_000), "2": F.position(convoy: 1_000, age: 120)]))
        // Everyone stale: nothing is known, so nothing has passed.
        #expect(!passed(event, cars: cars, positions: [
            "1": F.position(convoy: 6_000, age: 120), "2": F.position(convoy: 6_000, age: 120)]))
        // Exactly 60 s is still fresh.
        #expect(!passed(event, cars: cars, positions: [
            "1": F.position(convoy: 6_000), "2": F.position(convoy: 1_000, age: 60)]))
    }

    @Test func joiningCarMergingBeforeTheEventHoldsIt() {
        let event = F.event(at: 5_560)
        let cars = [F.car("1"), F.car("2", joining: true, merge: F.merge)]
        let positions = ["1": F.position(convoy: 7_000), "2": F.position(convoy: nil, own: 500)]
        // Without its route: merge (3,336) is before the event, so it still has to pass.
        #expect(!passed(event, cars: cars, positions: positions))
        // With its route: still on the way, 500 m along it.
        #expect(!passed(event, cars: cars, positions: positions, own: ["2": F.joining]))
    }

    @Test func joiningCarMergingAfterTheEventIsIgnored() {
        let event = F.event(at: 2_000)
        let cars = [F.car("1"), F.car("2", joining: true, merge: F.merge)]
        let positions = ["1": F.position(convoy: 4_000), "2": F.position(convoy: nil, own: 500)]
        #expect(passed(event, cars: cars, positions: positions))
        #expect(passed(event, cars: cars, positions: positions, own: ["2": F.joining]))
    }

    @Test func joiningCarWithUnknownMergeCountsAsNotPassed() {
        let event = F.event(at: 2_000)
        let cars = [F.car("1"), F.car("2", joining: true, merge: nil)]
        #expect(!passed(event, cars: cars, positions: ["1": F.position(convoy: 4_000), "2": F.position(convoy: nil, own: 500)]))
    }

    @Test func joiningCarPassesAnEventOnItsOwnRoute() throws {
        let event = F.event(at: 5_560)
        let cars = [F.car("2", joining: true, merge: F.merge)]
        let own = try #require(F.joining.project(F.main(at: 5_560))).offset
        let before = ["2": F.position(convoy: nil, own: own - 300)]
        let after = ["2": F.position(convoy: nil, own: own + 150)]
        #expect(!passed(event, cars: cars, positions: before, own: ["2": F.joining]))
        #expect(passed(event, cars: cars, positions: after, own: ["2": F.joining]))
    }

    @Test func eventOnJoiningLegIsPassedOnlyByTheJoiningCar() throws {
        // Debris on the joining road: the convoy never drives it; the joining car decides.
        let c = try #require(F.joining.coordinate(atOffset: 1_000))
        var event = F.event(at: 0)
        event.location = GeoPoint(latitude: c.latitude, longitude: c.longitude)
        let cars = [F.car("1"), F.car("2", joining: true, merge: F.merge)]
        let convoy = F.position(convoy: 5_000)
        #expect(!passed(event, cars: cars, positions: ["1": convoy, "2": F.position(convoy: nil, own: 500)], own: ["2": F.joining]))
        #expect(passed(event, cars: cars, positions: ["1": convoy, "2": F.position(convoy: nil, own: 1_200)], own: ["2": F.joining]))
        // Nobody on that road: nothing passes it.
        #expect(!passed(event, cars: [F.car("1")], positions: ["1": convoy]))
    }

    @Test func carWithoutConvoyOffsetAndNoRouteIsIgnoredWhenEventIsOffMainRoute() {
        let event = F.event(at: 5_000, north: 500)
        #expect(!passed(event, cars: [F.car("1")], positions: ["1": F.position(convoy: 6_000)]))
    }

    // MARK: Markers

    private func markers(_ events: [TripEvent], cars: [Car] = [], positions: [String: Position] = [:]) -> [HazardMarker] {
        var cache = HazardOffsetCache()
        return HazardLogic.markers(
            events: events, cars: cars, positions: positions, mainRoute: F.main, now: F.now, cache: &cache)
    }

    @Test func markerTextSymbolAndTone() throws {
        let m = try #require(markers([F.event(.debris, at: 4_000, age: 240)]).first)
        #expect(m.chipText == "Debris · 4 min ago")
        #expect(m.label == "Debris")
        #expect(m.symbol == "exclamationmark.triangle.fill")
        #expect(m.tone == .high)
        #expect(abs(try #require(m.mainOffset) - 4_000) < 5)
        #expect(m.accessibilityLabel == "Hazard: Debris · 4 min ago")
        let rain = try #require(markers([F.event(.heavyRain, id: "e2", at: 4_000, age: 10)]).first)
        #expect(rain.chipText == "Heavy rain · just now")
        #expect(rain.tone == .medium)
        #expect(rain.symbol == "cloud.heavyrain.fill")
    }

    @Test func unknownHazardTypeFallsBackToGenericSymbol() {
        let presentation = HazardMarker.presentation(for: .other("sinkhole"))
        #expect(presentation.symbol == HazardMarker.fallbackSymbol)
        #expect(HazardMarker.presentation(for: .animal).label == "Animal")
    }

    @Test func onlyHazardsAndConditionsGetMarkers() {
        let events = [
            F.event(.debris, id: "a", at: 4_000), F.event(.heavyRain, id: "b", at: 4_000),
            F.event(.stopFuel, id: "c", at: 4_000), F.event(.carTrouble, id: "d", at: 4_000),
            F.event(.message, id: "e", at: 4_000),
        ]
        #expect(markers(events).map(\.id) == ["a", "b"])
    }

    @Test func expiredEventsAreHidden() {
        var live = F.event(id: "live", at: 4_000)
        live.expiresAt = F.now.addingTimeInterval(60)
        var gone = F.event(id: "gone", at: 4_000)
        gone.expiresAt = F.now.addingTimeInterval(-1)
        var boundary = F.event(id: "edge", at: 4_000)
        boundary.expiresAt = F.now
        #expect(markers([live, gone, boundary]).map(\.id) == ["live"])
    }

    @Test func passedEventsAreHiddenAndOthersKept() {
        let events = [F.event(id: "behind", at: 2_000), F.event(id: "ahead", at: 8_000)]
        let result = markers(events, cars: [F.car("1"), F.car("2")], positions: [
            "1": F.position(convoy: 6_000), "2": F.position(convoy: 5_000)])
        #expect(result.map(\.id) == ["ahead"])
    }

    @Test func eventOffMainRouteStillShowsWithoutMainOffset() throws {
        let m = try #require(markers([F.event(at: 4_000, north: 800)]).first)
        #expect(m.mainOffset == nil)
    }

    // MARK: Model

    @MainActor @Test func modelUpdatesWithInputs() {
        let model = HazardModel(clock: { F.now })
        model.setMainRoute(F.main)
        model.setCars([F.car("1")])
        model.setEvents([F.event(at: 5_000)])
        #expect(model.markers.map(\.id) == ["e1"])
        model.setPositions(["1": F.position(convoy: 6_000)])
        #expect(model.markers.isEmpty)
        model.setPositions(["1": F.position(convoy: 4_000)])
        #expect(model.markers.count == 1)
        model.refresh(now: F.now.addingTimeInterval(46 * 60)) // debris lasts 45 min from its report
        #expect(model.markers.isEmpty)
    }

    @MainActor @Test func modelDecodesJoiningRoutes() {
        let model = HazardModel(clock: { F.now })
        model.setMainRoute(F.main)
        let encoded = Polyline.encode(F.joining.coordinates)
        model.setCars([F.car("1"), F.car("2", joining: true, merge: F.merge, route: encoded)])
        model.setEvents([F.event(at: 5_560)])
        model.setPositions(["1": F.position(convoy: 7_000), "2": F.position(convoy: nil, own: 500)])
        #expect(model.markers.count == 1) // joining car still has to pass
        model.setPositions(["1": F.position(convoy: 7_000), "2": F.position(convoy: nil, own: 4_800)])
        #expect(model.markers.isEmpty)
    }
}

// MARK: Approach

@MainActor
struct ApproachTests {
    private typealias F = Fixture

    private func monitor(
        _ announcer: FakeAnnouncer, events: [TripEvent], config: ApproachCore.Config = .default
    ) -> ApproachMonitor {
        let m = ApproachMonitor(announcer: announcer, myCarId: "c-me", myUserId: "u-me", config: config)
        m.setMainRoute(F.main)
        m.setEvents(events)
        return m
    }

    private func fix(_ m: ApproachMonitor, _ offset: Double) {
        m.update(position: F.position(convoy: offset), now: F.now)
    }

    @Test func coreFiresOnceWhenCrossing500() {
        var core = ApproachCore()
        let c = [ApproachCore.Candidate(id: "a", offset: 5_000)]
        #expect(core.evaluate(candidates: c, myOffset: 4_000).isEmpty)
        // 501 m ahead: not yet. Exactly 500 m ahead fires ("within 500 m" includes the boundary).
        #expect(core.evaluate(candidates: c, myOffset: 4_499).isEmpty)
        #expect(core.evaluate(candidates: c, myOffset: 4_500).count == 1)
        #expect(core.evaluate(candidates: c, myOffset: 4_501).isEmpty)
        #expect(core.evaluate(candidates: c, myOffset: 4_600).isEmpty)
        #expect(core.evaluate(candidates: c, myOffset: 4_400).isEmpty)
    }

    @Test func coreFirstSightInsideRangeFiresWithRealDistance() {
        var core = ApproachCore()
        let fires = core.evaluate(candidates: [.init(id: "a", offset: 5_000)], myOffset: 4_800)
        #expect(fires == [.init(id: "a", stage: .approach, distance: 200)])
    }

    @Test func coreNeverFiresBehindOrAtTheEvent() {
        var core = ApproachCore()
        #expect(core.evaluate(candidates: [.init(id: "a", offset: 5_000)], myOffset: 5_000).isEmpty)
        #expect(core.evaluate(candidates: [.init(id: "a", offset: 5_000)], myOffset: 5_200).isEmpty)
        // Passed, then jitter back before it: it never fired, so a fix 10 m short does fire once.
        #expect(core.evaluate(candidates: [.init(id: "a", offset: 5_000)], myOffset: 4_990).count == 1)
    }

    @Test func coreNowStageOnlyWhenEnabled() {
        var off = ApproachCore()
        let c = [ApproachCore.Candidate(id: "a", offset: 5_000)]
        #expect(off.evaluate(candidates: c, myOffset: 4_500).count == 1)
        #expect(off.evaluate(candidates: c, myOffset: 4_920).isEmpty)

        var on = ApproachCore(config: .init(nowDistance: 100))
        #expect(on.evaluate(candidates: c, myOffset: 4_500).map(\.stage) == [.approach])
        #expect(on.evaluate(candidates: c, myOffset: 4_950).map(\.stage) == [.now])
        #expect(on.evaluate(candidates: c, myOffset: 4_980).isEmpty)
        // Seen first at 50 m: just the "now" alert, not both.
        var late = ApproachCore(config: .init(nowDistance: 100))
        #expect(late.evaluate(candidates: c, myOffset: 4_950).map(\.stage) == [.now])
        #expect(late.evaluate(candidates: c, myOffset: 4_960).isEmpty)
    }

    @Test func monitorAnnouncesOnceAtCrossingWithJitter() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [F.event(id: "e1", at: 5_000)])
        for offset in [3_000.0, 4_300, 4_480, 4_520, 4_490, 4_530, 4_510, 4_700, 4_900] { fix(m, offset) }
        await m.waitForAnnouncements()
        #expect(announcer.calls.count == 1)
        #expect(announcer.calls.first?.id == "e1")
        let distance = announcer.calls.first?.distance ?? 0
        #expect(abs(distance - 480) < 15) // 4,520 is the first fix inside 500 m
    }

    @Test func monitorSkipsEventsBehind() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [F.event(at: 2_000)])
        for offset in [2_500.0, 3_000, 3_600] { fix(m, offset) }
        await m.waitForAnnouncements()
        #expect(announcer.calls.isEmpty)
    }

    @Test func monitorSkipsEventsOnTheOtherCarriageway() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [
            F.event(id: "far", at: 5_000, north: 80), F.event(id: "near", at: 5_000, north: 20)])
        for offset in [4_000.0, 4_600] { fix(m, offset) }
        await m.waitForAnnouncements()
        #expect(announcer.calls.map(\.id) == ["near"])
    }

    @Test func monitorSkipsMyOwnEvents() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [
            F.event(id: "mine-car", at: 5_000, author: "u-x", car: "c-me"),
            F.event(id: "mine-user", at: 5_000, author: "u-me", car: "c-x"),
            F.event(id: "theirs", at: 5_000),
        ])
        fix(m, 4_700)
        await m.waitForAnnouncements()
        #expect(announcer.calls.map(\.id) == ["theirs"])
    }

    @Test func monitorSkipsNonRoadAndExpiredEvents() async {
        let announcer = FakeAnnouncer()
        var expired = F.event(id: "old", at: 5_000)
        expired.expiresAt = F.now.addingTimeInterval(-1)
        let m = monitor(announcer, events: [expired, F.event(.stopFuel, id: "stop", at: 5_000), F.event(.message, id: "msg", at: 5_000)])
        fix(m, 4_700)
        await m.waitForAnnouncements()
        #expect(announcer.calls.isEmpty)
    }

    @Test func monitorAnnouncesEachEventOnce() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [F.event(id: "a", at: 5_000), F.event(id: "b", at: 6_000)])
        for offset in [4_400.0, 4_600, 5_550, 5_700] { fix(m, offset) }
        // A re-delivered event list changes nothing.
        m.setEvents([F.event(id: "a", at: 5_000), F.event(id: "b", at: 6_000)])
        fix(m, 5_800)
        await m.waitForAnnouncements()
        #expect(announcer.calls.map(\.id) == ["a", "b"])
    }

    @Test func monitorMeasuresOnOwnRouteWhileJoining() async throws {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [F.event(id: "shared", at: 5_560)])
        m.setOwnRoute(F.joining)
        let own = try #require(F.joining.project(F.main(at: 5_560))).offset
        // routeOffset is on the joining route; the main-route offset is unknown (nil convoyOffset).
        m.update(position: F.position(convoy: nil, own: own - 800), now: F.now)
        #expect(announcer.calls.isEmpty)
        m.update(position: F.position(convoy: nil, own: own - 450), now: F.now)
        await m.waitForAnnouncements()
        #expect(announcer.calls.map(\.id) == ["shared"])
        #expect(abs((announcer.calls.first?.distance ?? 0) - 450) < 10)
    }

    @Test func monitorIgnoresMainRouteOnlyEventsWhileJoiningOnTheLeg() async {
        let announcer = FakeAnnouncer()
        let m = monitor(announcer, events: [F.event(id: "main-only", at: 2_000)])
        m.setOwnRoute(F.joining)
        // The event sits on the main route before the merge: not on my route, so no alert.
        m.update(position: F.position(convoy: nil, own: 1_800), now: F.now)
        await m.waitForAnnouncements()
        #expect(announcer.calls.isEmpty)
    }

    @Test func monitorWithoutARouteDoesNothing() async {
        let announcer = FakeAnnouncer()
        let m = ApproachMonitor(announcer: announcer, myCarId: "c-me")
        m.setEvents([F.event(at: 5_000)])
        m.update(position: F.position(convoy: 4_900), now: F.now)
        await m.waitForAnnouncements()
        #expect(announcer.calls.isEmpty)
    }

    @Test func alertCenterConformsToAnnouncing() {
        func requireAnnouncing<T: AlertAnnouncing>(_: T.Type) {}
        requireAnnouncing(AlertCenter.self)
    }
}

// MARK: Regions

@MainActor
private final class FakeRegionBackend: RegionMonitoring {
    var added: [String] = []
    var removed: [String] = []
    var active: Set<String> = []
    func add(_ region: HazardRegion) async { added.append(region.id); active.insert(region.id) }
    func remove(id: String) async { removed.append(id); active.remove(id) }
    func entries() -> AsyncStream<String> { AsyncStream { _ in } }
}

@MainActor
struct HazardRegionTests {
    private typealias F = Fixture

    private func select(
        _ events: [TripEvent], at myOffset: Double = 1_000, exclude: Set<String> = [],
        config: HazardRegionSelector.Config = .default
    ) -> [HazardRegion] {
        HazardRegionSelector.select(
            events: events, route: F.main, myOffset: myOffset, myCarId: "c-me", myUserId: "u-me",
            exclude: exclude, now: F.now, config: config)
    }

    @Test func nearestFirstAndOnlyAhead() {
        let events = [
            F.event(id: "far", at: 9_000), F.event(id: "behind", at: 500),
            F.event(id: "near", at: 2_000), F.event(id: "mid", at: 5_000),
        ]
        let regions = select(events)
        #expect(regions.map(\.id) == ["near", "mid", "far"])
        #expect(regions.allSatisfy { $0.radius == 500 })
        #expect(abs(regions[0].distanceAhead - 1_000) < 5)
        #expect(regions[0].label == "Debris")
    }

    @Test func capsAtFifteenKeepingTheNearest() {
        let events = (0..<30).map { F.event(id: "e\($0)", at: 1_100 + Double($0) * 200) }
        let regions = select(events)
        #expect(regions.count == 15)
        #expect(regions.map(\.id) == (0..<15).map { "e\($0)" })
        #expect(select(events, config: .init(maxRegions: 3)).count == 3)
    }

    @Test func excludesMineExpiredOffRouteAndNonRoadEvents() {
        var expired = F.event(id: "expired", at: 3_000)
        expired.expiresAt = F.now.addingTimeInterval(-5)
        let events = [
            F.event(id: "mine", at: 3_000, author: "u-me"), F.event(id: "mycar", at: 3_000, car: "c-me"),
            expired, F.event(id: "lateral", at: 3_000, north: 90), F.event(.stopFood, id: "stop", at: 3_000),
            F.event(id: "hidden", at: 3_000), F.event(id: "ok", at: 3_000),
        ]
        #expect(select(events, exclude: ["hidden"]).map(\.id) == ["ok"])
    }

    @Test func noRouteMeansNoRegions() {
        #expect(HazardRegionSelector.select(
            events: [F.event(at: 3_000)], route: nil, myOffset: 0, myCarId: "c", now: F.now).isEmpty)
    }

    @Test func diffAddsAndRemovesOnlyTheDifference() {
        let desired = select([F.event(id: "a", at: 3_000), F.event(id: "b", at: 4_000)])
        let plan = HazardRegionSelector.diff(current: ["b", "z"], desired: desired)
        #expect(plan.add.map(\.id) == ["a"])
        #expect(plan.remove == ["z"])
    }

    @Test func monitorRegistersRefreshesAndRemoves() async {
        let backend = FakeRegionBackend()
        let monitor = HazardRegionMonitor(backend: backend) { _ in }
        let a = F.event(id: "a", at: 3_000), b = F.event(id: "b", at: 4_000)
        await monitor.update(events: [a, b], route: F.main, myOffset: 1_000, myCarId: "c-me", now: F.now)
        #expect(backend.active == ["a", "b"])
        // Same events, barely moved: skipped.
        await monitor.update(events: [a, b], route: F.main, myOffset: 1_100, myCarId: "c-me", now: F.now)
        #expect(backend.added == ["a", "b"])
        // A new nearer event arrives and `a` is cleared: only the difference changes.
        let c = F.event(id: "c", at: 2_000)
        await monitor.update(events: [b, c], route: F.main, myOffset: 1_100, myCarId: "c-me", now: F.now)
        #expect(backend.active == ["b", "c"])
        #expect(backend.removed == ["a"])
        #expect(backend.added == ["a", "b", "c"])
        // Driving past `c` removes it once I have moved far enough to refresh.
        await monitor.update(events: [b, c], route: F.main, myOffset: 2_500, myCarId: "c-me", now: F.now)
        #expect(backend.active == ["b"])
        #expect(monitor.monitored.map(\.id) == ["b"])
        await monitor.stop()
        #expect(backend.active.isEmpty)
    }

    @Test func monitorHandlesEachEntryOnce() async {
        let backend = FakeRegionBackend()
        var entered: [String] = []
        let monitor = HazardRegionMonitor(backend: backend) { entered.append($0.id) }
        await monitor.update(events: [F.event(id: "a", at: 3_000)], route: F.main, myOffset: 1_000, myCarId: "c-me", now: F.now)
        monitor.simulateEntry("a")
        monitor.simulateEntry("a")
        monitor.simulateEntry("unknown")
        #expect(entered == ["a"])
    }

    @Test func notificationWording() {
        let region = HazardRegion(id: "a", latitude: 3, longitude: 101, radius: 500, label: "Debris", distanceAhead: 400)
        let content = LocalHazardNotifier.content(for: region, tripId: "t1")
        #expect(content.title == "Debris ahead")
        #expect(content.body == "About 500 m ahead on your route.")
        #expect(content.threadIdentifier == AlertCenter.threadIdentifier(tripId: "t1"))
    }
}

// MARK: Map wiring

@MainActor
struct HazardWiringTests {
    private typealias F = Fixture

    private func trip() -> Trip {
        .fixture(
            route: Polyline.encode(F.main.coordinates),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 3, longitude: 101.1)))
    }

    /// An event that is current in real time (the model reads the real clock).
    private func event(_ id: String, at offset: Double) -> TripEvent {
        var e = F.event(id: id, at: offset)
        e.createdAt = Date().addingTimeInterval(-240)
        e.expiresAt = Date().addingTimeInterval(1_800)
        return e
    }

    private func position(convoy: Double?, own: Double? = nil) -> Position {
        var p = F.position(convoy: convoy, own: own)
        p.updatedAt = Date()
        return p
    }

    private func model(_ announcer: FakeAnnouncer, backend: FakeRegionBackend? = nil) -> TripMapModel {
        let model = TripMapModel(session: nil, hazards: HazardModel())
        if let backend {
            model.regionMonitorFactory = { HazardRegionMonitor(backend: backend) { _ in } }
        }
        model.startHazardAlerts(announcer: announcer, userId: "u-me")
        return model
    }

    @Test func markersShowUntilEveryCarHasPassed() {
        let model = model(FakeAnnouncer())
        let cars = [F.car("1"), F.car("2")]
        model.apply(
            trip: trip(), myCar: cars[0], myCarId: "1",
            positions: ["1": position(convoy: 4_000), "2": position(convoy: 1_000)], isTracker: false)
        model.setCars(cars)
        model.setEvents([event("e1", at: 3_000)])
        #expect(model.hazards.markers.map(\.id) == ["e1"])
        model.apply(
            trip: trip(), myCar: cars[0], myCarId: "1",
            positions: ["1": position(convoy: 4_500), "2": position(convoy: 3_500)], isTracker: false)
        #expect(model.hazards.markers.isEmpty)
    }

    @Test func approachFiresAt500mOnMyRouteAndNotForMyOwnReport() async {
        let announcer = FakeAnnouncer()
        let model = model(announcer)
        let cars = [F.car("1"), F.car("2")]
        var mine = event("mine", at: 3_100)
        mine.carId = "1"
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 1_000)], isTracker: false)
        model.setCars(cars)
        model.setEvents([event("e1", at: 3_000), mine])
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 2_450)], isTracker: false)
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 2_900)], isTracker: false)
        // Let the announcement tasks run.
        for _ in 0..<5 { await Task.yield() }
        #expect(announcer.calls.map { $0.id } == ["e1"])
    }

    @Test func joiningCarIsMeasuredOnItsOwnRoute() async throws {
        let announcer = FakeAnnouncer()
        let model = model(announcer)
        let route = Polyline.encode(F.joining.coordinates)
        let me = F.car("1", joining: true, route: route)
        // The event sits 450 m past 4,000 m along the joining route; no convoyOffset yet.
        let spot = try #require(F.joining.coordinate(atOffset: 4_450))
        var e = event("e1", at: 0)
        e.location = GeoPoint(latitude: spot.latitude, longitude: spot.longitude)
        model.apply(trip: trip(), myCar: me, myCarId: "1", positions: ["1": position(convoy: nil, own: 4_000)], isTracker: false)
        model.setCars([me])
        model.setEvents([e])
        model.apply(trip: trip(), myCar: me, myCarId: "1", positions: ["1": position(convoy: nil, own: 4_000)], isTracker: false)
        for _ in 0..<5 { await Task.yield() }
        #expect(announcer.calls.count == 1)
    }

    @Test func regionMonitorRunsOnlyForTheTracker() async {
        let backend = FakeRegionBackend()
        let model = model(FakeAnnouncer(), backend: backend)
        let cars = [F.car("1")]
        model.setCars(cars)
        model.setEvents([event("e1", at: 3_000)])
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 1_000)], isTracker: false)
        for _ in 0..<5 { await Task.yield() }
        #expect(backend.added.isEmpty)
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 1_000)], isTracker: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(backend.active == ["e1"])
        // Ending the trip stops it and removes the regions.
        model.apply(trip: trip(), myCar: cars[0], myCarId: "1", positions: ["1": position(convoy: 1_000)], isTracker: true, isEnded: true)
        for _ in 0..<5 { await Task.yield() }
        #expect(backend.active.isEmpty)
    }

    @Test func expiredRegionEntryIsIgnored() async {
        let backend = FakeRegionBackend()
        var entered: [String] = []
        let monitor = HazardRegionMonitor(backend: backend) { entered.append($0.id) }
        var e = F.event(id: "a", at: 3_000)
        e.expiresAt = Date().addingTimeInterval(0.05)
        await monitor.update(
            events: [e], route: F.main, myOffset: 1_000, myCarId: "c-me", now: Date().addingTimeInterval(-10))
        #expect(backend.active == ["a"])
        try? await Task.sleep(for: .milliseconds(100))
        monitor.simulateEntry("a")
        #expect(entered.isEmpty)
    }
}

// MARK: Emulator

/// Runs against the local Auth and Firestore emulators:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct HazardEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func reportedEventAppearsInHazardLogic() async throws {
        let ids = try await EmulatorTrip.make(name: "Hazards")
        let uid = ids.uid
        let route = Fixture.main
        let spot = Fixture.main(at: 5_000)
        let eventId = try await EventService.report(
            type: .debris, tripId: ids.tripId, carId: ids.carId, authorId: uid, location: spot,
            heading: 90, route: route, previousOffset: nil)

        var iterator = EventService.listen(tripId: ids.tripId).makeAsyncIterator()
        let events = try #require(await iterator.next())
        var cache = HazardOffsetCache()
        let car = Fixture.car(ids.carId)
        let now = Date()
        let ahead = HazardLogic.markers(
            events: events, cars: [car], positions: [ids.carId: Fixture.position(convoy: 4_000)].mapValues(fresh(now)),
            mainRoute: route, now: now, cache: &cache)
        #expect(ahead.map(\.id) == [eventId])
        #expect(ahead.first?.label == "Debris")
        #expect(abs((ahead.first?.mainOffset ?? 0) - 5_000) < 5)

        // Once the only car is well past it, the marker is hidden client-side.
        let past = HazardLogic.markers(
            events: events, cars: [car], positions: [ids.carId: Fixture.position(convoy: 6_000)].mapValues(fresh(now)),
            mainRoute: route, now: now, cache: &cache)
        #expect(past.isEmpty)
    }

    private func fresh(_ now: Date) -> (Position) -> Position {
        { var p = $0; p.updatedAt = now; return p }
    }
}
