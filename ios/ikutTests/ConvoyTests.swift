import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct ConvoyTests {
    private static let now = Fixtures.t0

    /// 20 km due east.
    private static var main: RouteLine {
        RouteLine(stride(from: 0.0, through: 20_000, by: 1000).map { move(origin, east: $0) })
    }

    private func car(_ id: String, number: Int? = nil, lead: Bool = false, state: CarState = .convoy,
                     route: String? = nil, merge: Double? = nil) -> Car {
        Car(id: id, name: "Car \(id)", color: "#2563EB", trackerUserId: nil, isLead: lead,
            route: route, mergeOffset: merge, state: state, number: number ?? Int(id))
    }

    private func pos(offset: Double?, speed: Double = 25, age: TimeInterval = 1, routeOffset: Double? = nil,
                     at: CLLocationCoordinate2D? = nil) -> Position {
        let c = at ?? move(origin, east: offset ?? 0)
        return Position(
            location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed, heading: 90,
            routeOffset: routeOffset ?? offset ?? 0, convoyOffset: offset, battery: nil,
            updatedAt: Self.now.addingTimeInterval(-age))
    }

    private func order(_ cars: [Car], _ positions: [String: Position], speeds: [String: Double] = [:],
                       main: RouteLine? = nil, merges: [String: Double] = [:], together: Set<CarPair> = [],
                       config: ConvoyOrdering.Config = .default) -> ConvoySnapshot {
        ConvoyOrdering.order(cars: cars, positions: positions, now: Self.now, speeds: speeds,
                             mainRoute: main, ownMergeOffsets: merges, together: together, config: config)
    }

    // MARK: Ordering

    @Test func sortsFrontFirstByConvoyOffset() {
        let s = order([car("1", lead: true), car("2"), car("3")],
                      ["1": pos(offset: 5000), "2": pos(offset: 9000), "3": pos(offset: 7000)])
        #expect(s.convoy.map(\.id) == ["2", "3", "1"])
        #expect(s.front?.id == "2")
        #expect(s.convoy.map(\.isFront) == [true, false, false])
    }

    @Test func leadIsDesignatedNotNecessarilyFront() {
        let s = order([car("1", lead: true), car("2")], ["1": pos(offset: 5000), "2": pos(offset: 9000)])
        #expect(s.front?.id == "2")
        #expect(s.lead?.id == "1")
        #expect(s.convoy.filter(\.isLead).map(\.id) == ["1"])
    }

    @Test func tiesBreakByNumberThenId() {
        let s = order([car("b", number: 3), car("a", number: 3), car("c", number: 1)],
                      ["a": pos(offset: 100), "b": pos(offset: 100), "c": pos(offset: 100)])
        #expect(s.convoy.map(\.id) == ["c", "a", "b"])
    }

    @Test func emptyAndSingle() {
        #expect(order([], [:]) == .empty)
        let s = order([car("1")], ["1": pos(offset: 100)])
        #expect(s.convoy.count == 1)
        #expect(s.convoy[0].gap == nil)
        #expect(s.spread == nil)
    }

    // MARK: Gaps

    @Test func gapDistanceAndTimeUseFollowersSpeed() throws {
        let s = order([car("1"), car("2")],
                      ["1": pos(offset: 10_000, speed: 30), "2": pos(offset: 8000, speed: 20)])
        let gap = try #require(s.convoy[1].gap)
        #expect(gap.distance == 2000)
        #expect(gap.time == 100)
        #expect(!gap.isSeparated)
        #expect(s.spread == 2000)
    }

    @Test func smoothedSpeedOverridesRawAndFloorApplies() throws {
        let cars = [car("1"), car("2")]
        let ps = ["1": pos(offset: 10_000), "2": pos(offset: 9000, speed: 30)]
        #expect(try #require(order(cars, ps, speeds: ["2": 10]).convoy[1].gap).time == 100)
        // Stopped at lights: 0 m/s would be infinite; the floor is 5 m/s.
        let stopped = try #require(order(cars, ["1": ps["1"]!, "2": pos(offset: 9000, speed: 0)]).convoy[1].gap)
        #expect(stopped.time == 200)
        #expect(order(cars, ps, speeds: ["2": 1]).convoy[1].speed == 5)
    }

    @Test func separationFlagsDistanceOrTime() throws {
        // 6 km at 25 m/s = 240 s: distance only.
        var s = order([car("1"), car("2")], ["1": pos(offset: 10_000), "2": pos(offset: 4000)])
        #expect(s.convoy[1].gap?.isSeparated == true)
        // 3 km at 5 m/s = 600 s: time only.
        s = order([car("1"), car("2")], ["1": pos(offset: 10_000), "2": pos(offset: 7000, speed: 5)])
        #expect(s.convoy[1].gap?.isSeparated == true)
        // Exactly at both thresholds: not flagged.
        s = order([car("1"), car("2")], ["1": pos(offset: 10_000), "2": pos(offset: 5000, speed: 5000.0 / 300)],
                  config: .init(minSpeed: 1))
        #expect(s.convoy[1].gap?.isSeparated == false)
        #expect(s.driftedGaps.isEmpty)
        // Custom thresholds; the two were together earlier, so the gap counts as drifted.
        s = order([car("1"), car("2")], ["1": pos(offset: 10_000), "2": pos(offset: 9000)],
                  together: [CarPair("1", "2")], config: .init(separationDistance: 500))
        #expect(s.driftedGaps.map(\.id) == ["2"])
    }

    @Test func timeBehindReferenceAccumulates() {
        let s = order([car("1", lead: true), car("2"), car("3")],
                      ["1": pos(offset: 10_000), "2": pos(offset: 8000, speed: 20), "3": pos(offset: 7000, speed: 10)])
        #expect(s.convoy.map(\.timeBehindReference) == [0, 100, 200])
    }

    // MARK: Staleness

    @Test func staleAfterSixtySecondsButStillOrdered() {
        let s = order([car("1"), car("2"), car("3")],
                      ["1": pos(offset: 9000, age: 59), "2": pos(offset: 8000, age: 61), "3": pos(offset: 7000, age: 120)])
        #expect(s.convoy.map(\.id) == ["1", "2", "3"])
        #expect(s.convoy.map(\.isStale) == [false, true, true])
        #expect(s.convoy[2].age == 120)
    }

    @Test func missingTimestampIsFresh() {
        var p = pos(offset: 100)
        p.updatedAt = nil
        let s = order([car("1")], ["1": p])
        #expect(!s.convoy[0].isStale)
        #expect(s.convoy[0].age == nil)
    }

    @Test func staleFrontDoesNotAnchorETA() {
        // The lead's position is old: the reference is the fresh car with the most cars around it,
        // the one further back on a tie (D26).
        let s = order([car("1", lead: true), car("2"), car("3")],
                      ["1": pos(offset: 9000, age: 300), "2": pos(offset: 8000, speed: 20), "3": pos(offset: 7000, speed: 10)])
        #expect(s.front?.id == "1")
        #expect(s.etaReference?.id == "3")
        #expect(s.convoy.map(\.timeBehindReference) == [nil, nil, 0])
        // With the lead fresh, it is the reference wherever it is.
        let fresh = order([car("1"), car("2", lead: true), car("3")],
                          ["1": pos(offset: 9000, age: 300), "2": pos(offset: 8000, speed: 20), "3": pos(offset: 7000, speed: 10)])
        #expect(fresh.etaReference?.id == "2")
        #expect(fresh.convoy.map(\.timeBehindReference) == [nil, 0, 100])
    }

    @Test func agoText() {
        #expect(ConvoyFormat.ago(0) == "just now")
        #expect(ConvoyFormat.ago(59) == "just now")
        #expect(ConvoyFormat.ago(60) == "1 min ago")
        #expect(ConvoyFormat.ago(3 * 3600) == "3 h ago")
        #expect(ConvoyFormat.ago(3 * 86_400) == "3 d ago")
        #expect(ConvoyFormat.ago(3 * 3600, hourUnit: "hr") == "3 hr ago")
        #expect(ConvoyFormat.ago(30 * 3600, hourUnit: "hr", days: false) == "30 hr ago")
    }

    @Test func lastSeenText() {
        #expect(ConvoyFormat.lastSeen(age: 30) == "Last seen just now")
        #expect(ConvoyFormat.lastSeen(age: 61) == "Last seen 1 min ago")
        #expect(ConvoyFormat.lastSeen(age: 125) == "Last seen 2 min ago")
        #expect(ConvoyFormat.lastSeen(age: 7300) == "Last seen 2 h ago")
        #expect(ConvoyFormat.lastSeen(age: 200_000) == "Last seen 2 d ago")
    }

    @Test func placeShortNames() {
        #expect(ConvoyFormat.placeShortName("Kuala Lumpur") == "KL")
        #expect(ConvoyFormat.placeShortName(" kuala lumpur ") == "KL")
        #expect(ConvoyFormat.placeShortName("Petaling Jaya") == "PJ")
        #expect(ConvoyFormat.placeShortName("Johor Bahru") == "JB")
        #expect(ConvoyFormat.placeShortName("Kota Kinabalu") == "KK")
        #expect(ConvoyFormat.placeShortName("Kota Bharu") == "KB")
        #expect(ConvoyFormat.placeShortName("San Francisco") == "SF")
        #expect(ConvoyFormat.placeShortName("Ipoh") == "Ipoh")
        #expect(ConvoyFormat.placeShortName("Seremban") == "Seremban")
        #expect(ConvoyFormat.placeShortName("") == "")
    }

    @Test func convoySummaryText() {
        let full = ConvoyFormat.convoySummary(driving: 3, joinerName: "Hafiz\u{2019}s Hilux", joinIn: 18 * 60, spread: 6400)
        #expect(full.driving == "3 cars driving")
        #expect(full.joining == "Hafiz joins in 18 min")
        #expect(full.spread == "6.4 km spread")
        let one = ConvoyFormat.convoySummary(driving: 1, joinerName: nil, joinIn: nil, spread: nil)
        #expect(one.driving == "1 car driving")
        #expect(one.joining == nil && one.spread == nil)
        #expect(ConvoyFormat.convoySummary(driving: 2, joinerName: "Wyna's X70", joinIn: nil, spread: nil).joining == "Wyna joining")
    }

    @Test func convoySummaryNamesMyJoiningCarYou() {
        let mine = ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Daniel\u{2019}s Myvi", joinIn: 18 * 60, spread: nil, joinerIsMe: true)
        #expect(mine.joining == "You join in 18 min")
        #expect(ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Daniel\u{2019}s Myvi", joinIn: 75 * 60, spread: nil, joinerIsMe: true).joining
            == "You join in 1 h 15 min")
        #expect(ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Daniel\u{2019}s Myvi", joinIn: nil, spread: nil, joinerIsMe: true).joining
            == "You\u{2019}re joining")
        // Someone else's car keeps its name.
        #expect(ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Daniel\u{2019}s Myvi", joinIn: 18 * 60, spread: nil, joinerIsMe: false).joining
            == "Daniel joins in 18 min")
    }

    @Test func convoyMotion() {
        #expect(ConvoyFormat.motion(mineArrived: false, everyoneArrived: true, frontSpeed: 0) == .everyoneArrived)
        #expect(ConvoyFormat.motion(mineArrived: true, everyoneArrived: false, frontSpeed: 20) == .arrived)
        #expect(ConvoyFormat.motion(mineArrived: false, everyoneArrived: false, frontSpeed: 20) == .moving)
        #expect(ConvoyFormat.motion(mineArrived: false, everyoneArrived: false, frontSpeed: 3) == .stopped)
        #expect(ConvoyFormat.motion(mineArrived: false, everyoneArrived: false, frontSpeed: nil) == .waiting)
        #expect(ConvoyFormat.Motion.everyoneArrived.text == "Everyone\u{2019}s arrived")
        #expect(ConvoyFormat.Motion.arrived.text == "Arrived")
        #expect(ConvoyFormat.Motion.moving.text == "On the move")
        #expect(ConvoyFormat.Motion.stopped.text == "Stopped")
        #expect(ConvoyFormat.Motion.waiting.text == "Waiting")
        #expect(ConvoyFormat.Motion.moving.isPositive && !ConvoyFormat.Motion.stopped.isPositive)
    }

    @Test func tripPillSubtitle() {
        func line(_ motion: ConvoyFormat.Motion?, ended: Bool = false, paused: Bool = false, sharing: Bool = true,
                  code: String = "K7M 2QX", withCode: Bool = true) -> String {
            ConvoyFormat.tripPillParts(
                motion: motion, ended: ended, paused: paused, sharing: sharing, code: code, withCode: withCode)
            .joined(separator: " · ")
        }
        #expect(line(.moving) == "On the move · Sharing location · Code K7M 2QX")
        #expect(line(.moving, withCode: false) == "On the move · Sharing location")
        #expect(line(.arrived, sharing: false) == "Arrived · Not sharing location · Code K7M 2QX")
        #expect(line(.stopped, paused: true) == "Stopped · Sharing paused · Code K7M 2QX")
        #expect(line(.everyoneArrived, code: "") == "Everyone\u{2019}s arrived · Sharing location")
        #expect(line(.everyoneArrived, ended: true) == "Trip ended · Code K7M 2QX")
        #expect(line(nil) == "Sharing location · Code K7M 2QX")
    }

    // MARK: Joining

    private func joiningFixture() -> (cars: [Car], merges: [String: Double], main: RouteLine) {
        // Own route: 3 km north-to-south approach joining the main route at x = 6 km, then along it.
        let start = move(origin, north: -3000, east: 6000)
        var pts = stride(from: 0.0, through: 3000, by: 500).map { move(start, north: $0) }
        pts += stride(from: 7000.0, through: 20_000, by: 1000).map { move(origin, east: $0) }
        let encoded = Polyline.encode(pts)
        let cars = [car("1"), car("4", state: .joining, route: encoded, merge: 6000)]
        let main = Self.main
        return (cars, ConvoyOrdering.mergeOffsets(cars: cars, main: main), main)
    }

    @Test func mergeOffsetsComeFromOwnRoute() throws {
        let f = joiningFixture()
        let m = try #require(f.merges["4"])
        #expect(abs(m - 3000) < 100)
        #expect(f.merges["1"] == nil)
    }

    @Test func joiningDistanceIsRemainingOwnRoute() throws {
        let f = joiningFixture()
        let p = pos(offset: nil, speed: 20, routeOffset: 1000, at: move(origin, north: -2000, east: 6000))
        let s = order(f.cars, ["1": pos(offset: 8000), "4": p], main: f.main, merges: f.merges)
        #expect(s.convoy.map(\.id) == ["1"])
        let j = try #require(s.joining.first)
        #expect(j.id == "4")
        #expect(abs(try #require(j.distanceToMerge) - 2000) < 100)
        #expect(abs(try #require(j.timeToMerge) - 100) < 5)
    }

    @Test func joiningDistanceClampsAtZeroPastMergePoint() throws {
        let s = order([car("4", state: .joining)], ["4": pos(offset: nil, routeOffset: 5000)], merges: ["4": 3000])
        #expect(s.joining[0].distanceToMerge == 0)
    }

    @Test func joiningFallsBackToStraightLine() throws {
        // No own route offset: 4 km due west of the main-route point at 6 km.
        let c = car("4", state: .joining, merge: 6000)
        let p = pos(offset: nil, at: move(origin, east: 2000))
        let s = order([c], ["4": p], main: Self.main)
        #expect(abs(try #require(s.joining[0].distanceToMerge) - 4000) < 5)
    }

    @Test func joiningWithUnknownDistanceOrNoPosition() {
        let s = order([car("4", state: .joining), car("5", state: .joining), car("6", state: .convoy)],
                      ["4": pos(offset: nil)])
        #expect(s.joining.map(\.id) == ["4", "5"])
        #expect(s.joining.allSatisfy { $0.distanceToMerge == nil && $0.timeToMerge == nil })
        #expect(s.joining[1].position == nil)
        #expect(s.convoy.isEmpty) // car 6 has no position: nothing to place it by
    }

    @Test func joiningSortedNearestFirstUnknownLast() {
        let cars = [car("4", state: .joining), car("5", state: .joining), car("6", state: .joining)]
        let s = order(cars, ["4": pos(offset: nil, routeOffset: 100), "5": pos(offset: nil, routeOffset: 2000), "6": pos(offset: nil)],
                      merges: ["4": 3000, "5": 3000])
        #expect(s.joining.map(\.id) == ["5", "4", "6"])
    }

    @Test func carWithConvoyOffsetIsInConvoyWhateverItsState() {
        let s = order([car("1", state: .joining)], ["1": pos(offset: 100)])
        #expect(s.convoy.count == 1 && s.joining.isEmpty)
    }

    // MARK: Smoothing

    @Test func smootherFirstSampleThenEMA() {
        var sm = SpeedSmoother()
        var p = pos(offset: 0, speed: 20, age: 10)
        sm.ingest(carId: "1", position: p)
        #expect(sm.speed(for: "1") == 20)
        p = pos(offset: 0, speed: 30, age: 9)
        sm.ingest(carId: "1", position: p)
        #expect(abs(sm.speed(for: "1")! - 23) < 1e-9)
    }

    @Test func smootherIgnoresRedeliveredFixAndDampsSpike() {
        var sm = SpeedSmoother()
        sm.ingest(carId: "1", position: pos(offset: 0, speed: 20, age: 10))
        let spike = pos(offset: 0, speed: 40, age: 9)
        sm.ingest(carId: "1", position: spike)
        let once = sm.speed(for: "1")!
        sm.ingest(carId: "1", position: spike)
        #expect(sm.speed(for: "1") == once)
        #expect(once < 30)
    }

    @Test func smootherConvergesAndPrunes() {
        var sm = SpeedSmoother()
        for i in 0..<40 { sm.ingest(carId: "1", position: pos(offset: 0, speed: i == 0 ? 0 : 25, age: Double(100 - i))) }
        #expect(abs(sm.speed(for: "1")! - 25) < 0.1)
        sm.ingest(["2": pos(offset: 0)])
        #expect(sm.speed(for: "1") == nil)
        #expect(sm.speed(for: "2") != nil)
    }

    @Test func smootherSanitisesBadSpeeds() {
        var sm = SpeedSmoother()
        sm.ingest(carId: "1", position: pos(offset: 0, speed: -1))
        #expect(sm.speed(for: "1") == 0)
        sm.ingest(carId: "2", position: pos(offset: 0, speed: .nan))
        #expect(sm.speed(for: "2") == 0)
    }

    // MARK: Formatting

    @Test func distanceText() {
        #expect(ConvoyFormat.distance(0) == "0 m")
        #expect(ConvoyFormat.distance(847) == "850 m")
        #expect(ConvoyFormat.distance(1800) == "1.8 km")
        #expect(ConvoyFormat.distance(4600) == "4.6 km")
        #expect(ConvoyFormat.distance(6400) == "6.4 km")
        #expect(ConvoyFormat.distance(84_000) == "84 km")
        #expect(ConvoyFormat.distance(-5) == "0 m")
    }

    @Test func durationText() {
        #expect(ConvoyFormat.duration(10) == "1 min")
        #expect(ConvoyFormat.duration(180) == "3 min")
        #expect(ConvoyFormat.duration(1080) == "18 min")
        #expect(ConvoyFormat.duration(3900) == "1 h 5 min")
        #expect(ConvoyFormat.duration(7200) == "2 h")
        #expect(ConvoyFormat.behind(60) == "1 min behind")
        #expect(ConvoyFormat.speed(metersPerSecond: 26.7) == "96 km/h")
    }

    @Test func clockText() {
        let d = Fixtures.t0 // 2027-01-15 08:00 UTC
        #expect(ConvoyFormat.clock(d.addingTimeInterval(52 * 60 + 6 * 3600), locale: Fixtures.gb, timeZone: Fixtures.utc) == "14:52")
        #expect(ConvoyFormat.eta(d, destination: "Ipoh", locale: Fixtures.gb, timeZone: Fixtures.utc) == "ETA Ipoh 08:00")
        #expect(ConvoyFormat.eta(d, locale: Fixtures.gb, timeZone: Fixtures.utc) == "ETA 08:00")
    }

    // MARK: ETA schedule

    @Test func scheduleRules() {
        let s = ETARefreshSchedule.default
        let t0 = Self.now
        func ask(_ elapsed: TimeInterval, moved: Double = 0, failures: Int = 0) -> Bool {
            s.shouldRequest(lastRequest: t0, movedSince: moved, now: t0.addingTimeInterval(elapsed), consecutiveFailures: failures)
        }
        #expect(s.shouldRequest(lastRequest: nil, movedSince: 0, now: t0))
        #expect(!ask(10, moved: 5000))        // too soon, however far
        #expect(!ask(29.9, moved: .infinity))
        #expect(!ask(45, moved: 100))         // in the window, barely moved
        #expect(ask(45, moved: 500))          // in the window, moved enough
        #expect(ask(30, moved: .infinity))    // reference car changed
        #expect(!ask(59.9))
        #expect(ask(60))                      // max interval
        #expect(ask(600))
        #expect(s.shouldRequest(lastRequest: t0, movedSince: 0, now: t0.addingTimeInterval(-5)))
    }

    @Test func scheduleBacksOffAfterFailures() {
        let s = ETARefreshSchedule.default
        func ask(_ elapsed: TimeInterval, _ failures: Int, moved: Double = 10_000) -> Bool {
            s.shouldRequest(lastRequest: Self.now, movedSince: moved, now: Self.now.addingTimeInterval(elapsed), consecutiveFailures: failures)
        }
        #expect(!ask(59, 1))          // movement doesn't shortcut a backoff
        #expect(ask(60, 1))
        #expect(!ask(119, 2))
        #expect(ask(120, 2))
        #expect(ask(240, 3))
        #expect(!ask(299, 10))
        #expect(ask(300, 10))         // capped
    }

    // MARK: Model

    private final class MockETA: ETAProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        var result: Result<TimeInterval, Error> = .success(1800)
        var calls: Int { lock.withLock { _calls.count } }
        func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval {
            lock.withLock { _calls.append((from, to)) }
            return try result.get()
        }
    }

    private struct Boom: Error {}

    @MainActor private final class Clock {
        var now = ConvoyTests.now
    }

    @MainActor
    private func makeModel(_ provider: MockETA, _ clock: Clock) -> ConvoyModel {
        ConvoyModel.fixture(provider: provider, route: Self.main, clock: { clock.now })
    }

    @MainActor @Test func modelOneRequestForWholeConvoyAndGapsGiveOtherETAs() async throws {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        m.destinationName = "Ipoh"
        m.update(cars: [car("1", lead: true), car("2"), car("3")],
                 positions: ["1": pos(offset: 10_000), "2": pos(offset: 8000, speed: 20), "3": pos(offset: 7000, speed: 10)])
        await m.waitForETA()
        #expect(provider.calls == 1)
        let arrival = Self.now.addingTimeInterval(1800)
        #expect(m.frontETA?.arrival == arrival)
        #expect(m.arrival(forCar: "1") == arrival)
        #expect(m.arrival(forCar: "2") == arrival.addingTimeInterval(100))
        #expect(m.arrival(forCar: "3") == arrival.addingTimeInterval(200))
        // More fixes inside the window: no new request.
        clock.now = Self.now.addingTimeInterval(10)
        m.setPositions(["1": pos(offset: 10_200), "2": pos(offset: 8200, speed: 20), "3": pos(offset: 7200, speed: 10)])
        await m.waitForETA()
        #expect(provider.calls == 1)
        // Destination is the main route's end.
        #expect(m.title == "3 in Convoy")
        #expect(m.subtitle.hasPrefix("Spread 3.0 km · ETA Ipoh "))
    }

    @MainActor @Test func modelRefreshesAfterMaxInterval() async {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        m.update(cars: [car("1")], positions: ["1": pos(offset: 1000)])
        await m.waitForETA()
        clock.now = Self.now.addingTimeInterval(61)
        m.setPositions(["1": pos(offset: 1100, age: -61)])
        await m.waitForETA()
        #expect(provider.calls == 2)
    }

    @MainActor @Test func modelRefreshesOnMovementInsideWindow() async {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        m.update(cars: [car("1")], positions: ["1": pos(offset: 1000)])
        await m.waitForETA()
        clock.now = Self.now.addingTimeInterval(40)
        m.setPositions(["1": pos(offset: 1100)])
        await m.waitForETA()
        #expect(provider.calls == 1)
        m.setPositions(["1": pos(offset: 1600)])
        await m.waitForETA()
        #expect(provider.calls == 2)
    }

    @MainActor @Test func modelKeepsLastETAWhenRefreshFails() async {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        m.update(cars: [car("1")], positions: ["1": pos(offset: 1000)])
        await m.waitForETA()
        provider.result = .failure(Boom())
        clock.now = Self.now.addingTimeInterval(70)
        m.setPositions(["1": pos(offset: 2000, age: -70)])
        await m.waitForETA()
        #expect(provider.calls == 2)
        #expect(m.frontETA?.requestedAt == Self.now)
        // One failure means a 60 s backoff from the failed request (at +70 s); +100 s is too soon, despite 7 km of movement.
        clock.now = Self.now.addingTimeInterval(100)
        m.setPositions(["1": pos(offset: 9000, age: -100)])
        await m.waitForETA()
        #expect(provider.calls == 2)
    }

    @MainActor @Test func modelUsesFreshCarWhenFrontIsStale() async {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        m.update(cars: [car("1"), car("2")], positions: ["1": pos(offset: 9000, age: 200), "2": pos(offset: 8000)])
        await m.waitForETA()
        #expect(m.frontETA?.carId == "2")
        #expect(m.arrival(forCar: "1") == nil)
        #expect(m.arrival(forCar: "2") != nil)
        let rows = m.convoyRows
        #expect(rows[0].subtitle == "Last seen 3 min ago")
        #expect(rows[0].subtitleIsWarning)
    }

    @MainActor @Test func modelRowsFollowTheMock() async throws {
        let provider = MockETA()
        let clock = Clock()
        let m = makeModel(provider, clock)
        let other = CLLocationCoordinate2D(latitude: 3, longitude: 101)
        _ = other
        m.update(
            cars: [car("1", lead: true), car("2"), car("4"), car("3", state: .joining)],
            positions: [
                "1": pos(offset: 10_000, speed: 26.7), "2": pos(offset: 8200, speed: 25.6),
                "4": pos(offset: 3600, speed: 20, age: 125),
                "3": pos(offset: nil, speed: 23.3, routeOffset: 0),
            ])
        await m.waitForETA()
        let rows = m.convoyRows
        #expect(rows.map(\.id) == ["1", "2", "4"])
        #expect(rows[0].subtitle == "Lead · 96 km/h")
        #expect(rows[0].trailingPrimary == "Lead")
        #expect(rows[0].trailingSecondary.hasPrefix("ETA "))
        #expect(rows[1].subtitle == "92 km/h")
        #expect(rows[1].trailingPrimary == "1.8 km")
        #expect(rows[1].trailingSecondary == "1 min behind")
        #expect(rows[2].subtitle == "Last seen 2 min ago")
        #expect(rows[2].trailingPrimary == "4.6 km")
        #expect(rows[2].isSeparated == false)
        let join = m.joiningRows
        #expect(join.count == 1)
        #expect(join[0].trailingPrimary == "--")
        #expect(join[0].trailingSecondary == "to merge")
    }

    @MainActor @Test func modelFrontThatIsNotLeadSaysFront() async {
        let m = makeModel(MockETA(), Clock())
        m.update(cars: [car("1", lead: true), car("2")], positions: ["1": pos(offset: 1000), "2": pos(offset: 2000)])
        #expect(m.convoyRows.map(\.trailingPrimary).first == "Front")
        #expect(m.convoyRows[1].subtitle.hasPrefix("Lead · "))
    }

    @MainActor @Test func modelJoiningMergeETA() throws {
        let f = joiningFixture()
        let clock = Clock()
        let m = makeModel(MockETA(), clock)
        m.update(cars: f.cars, positions: [
            "1": pos(offset: 8000),
            "4": pos(offset: nil, speed: 20, routeOffset: 1000, at: move(origin, north: -2000, east: 6000)),
        ])
        let joiner = try #require(m.joining.first)
        #expect(abs((joiner.timeToMerge ?? 0) - 100) < 5)
        #expect(m.joiningRows[0].trailingPrimary == "2 min")
    }

    @MainActor @Test func modelWithoutRouteOrCarsMakesNoRequest() async {
        let provider = MockETA()
        let m = ConvoyModel(provider: provider, clock: { Self.now })
        m.update(cars: [car("1")], positions: ["1": pos(offset: 100)])
        await m.waitForETA()
        #expect(provider.calls == 0)
        #expect(m.subtitle == "")
        #expect(m.convoyRows[0].trailingSecondary == "Calculating ETA")
    }

    // MARK: Paused cars

    private func pausedCar(_ id: String, ago: TimeInterval, lead: Bool = false) -> Car {
        var c = car(id, lead: lead)
        c.pausedAt = Self.now.addingTimeInterval(-ago)
        return c
    }

    @Test func pausedCarIsNotStaleAndShowsPaused() {
        let s = order([car("1"), pausedCar("2", ago: 120)],
                      ["1": pos(offset: 9000), "2": pos(offset: 5000, age: 300)])
        let paused = s.convoy.first { $0.id == "2" }
        #expect(paused?.isPaused == true)
        #expect(paused?.isStale == false)
    }

    @MainActor @Test func pausedRowSubtitleIsPausedNotLastSeen() {
        let m = ConvoyModel(clock: { Self.now })
        m.update(cars: [car("1"), pausedCar("2", ago: 120)],
                 positions: ["1": pos(offset: 9000), "2": pos(offset: 5000, age: 300)])
        let row = m.convoyRows.first { $0.id == "2" }
        #expect(row?.subtitle == "Paused")
        #expect(row?.subtitleIsWarning == false)
        #expect(row?.isStale == false)
    }

    @Test func expiredPauseFallsBackToLastSeen() {
        let expired = pausedCar("2", ago: TripSessionLogic.pauseExpiry + 1)
        let s = order([car("1"), expired], ["1": pos(offset: 9000), "2": pos(offset: 5000, age: 300)])
        let entry = s.convoy.first { $0.id == "2" }
        #expect(entry?.isPaused == false)
        #expect(entry?.isStale == true)
    }

    @Test func pausedFrontIsNotTheETAReference() {
        let s = order([pausedCar("1", ago: 60), car("2")], ["1": pos(offset: 9000, age: 200), "2": pos(offset: 5000)])
        #expect(s.front?.id == "1")
        #expect(s.etaReference?.id == "2")
    }

    @Test func pausedJoiningCarIsNotStale() {
        var c = car("3", state: .joining)
        c.pausedAt = Self.now.addingTimeInterval(-10)
        let s = order([car("1"), c], ["1": pos(offset: 9000), "3": pos(offset: nil, age: 300, routeOffset: 100)])
        #expect(s.joining.first?.isPaused == true)
        #expect(s.joining.first?.isStale == false)
    }

    @Test func pausedBannerCountsDownInWholeMinutes() {
        #expect(PausedBannerText.message(remaining: 28 * 60 - 20) == "Sharing paused · resumes automatically in 28 min")
        #expect(PausedBannerText.message(remaining: 5) == "Sharing paused · resumes automatically in 1 min")
        #expect(PausedBannerText.message(remaining: -3) == "Sharing paused · resumes automatically in 1 min")
    }
}

// MARK: - Me and arrival

extension ConvoyTests {
    @Test func arrivalRuleIsWithin150mOfRouteEnd() {
        #expect(!ConvoyArrival.hasArrived(offset: 19_849, routeLength: 20_000))
        #expect(ConvoyArrival.hasArrived(offset: 19_850, routeLength: 20_000))
        #expect(ConvoyArrival.hasArrived(offset: 20_100, routeLength: 20_000))
        #expect(!ConvoyArrival.hasArrived(offset: 20_000, routeLength: nil))
        #expect(!ConvoyArrival.hasArrived(offset: 0, routeLength: 0))
    }

    @Test func snapshotMarksArrivedCarsAndEveryone() {
        let s = order([car("1"), car("2")], ["1": pos(offset: 19_950), "2": pos(offset: 12_000)], main: Self.main)
        #expect(s.convoy.map(\.hasArrived) == [true, false])
        #expect(s.hasArrived("1"))
        #expect(!s.hasArrived("2"))
        #expect(!s.hasArrived(nil))
        #expect(!s.everyoneArrived)
        let all = order([car("1"), car("2")], ["1": pos(offset: 19_990), "2": pos(offset: 19_900)], main: Self.main)
        #expect(all.everyoneArrived)
        #expect(!ConvoySnapshot.empty.everyoneArrived)
        // Without a route nobody has arrived.
        #expect(!order([car("1")], ["1": pos(offset: 19_990)]).everyoneArrived)
    }

    @Test func arrivalStatusAndToGoText() {
        #expect(ConvoyFormat.toGo(remaining: 0, travelTime: 10, arrived: true) == "Arrived")
        #expect(ConvoyFormat.toGo(remaining: 63_000, travelTime: 41 * 60, arrived: false) == "63 km · 41 min to go")
        #expect(ConvoyFormat.toGo(remaining: 850, travelTime: nil, arrived: false) == "850 m to go")
    }

    @MainActor @Test func rowsKeepMyCarsNameAndShowArrived() {
        let m = makeModel(MockETA(), Clock())
        m.setMainRoute(Self.main)
        m.update(cars: [car("1"), car("2")], positions: ["1": pos(offset: 19_950), "2": pos(offset: 15_000)])
        let rows = m.convoyRows(myCarId: "2")
        #expect(rows.map(\.name) == ["Car 1", "Car 2"])
        #expect(rows.map(\.isMine) == [false, true])
        #expect(rows[0].hasArrived)
        #expect(rows[0].trailingPrimary == "Arrived")
        #expect(!rows[1].hasArrived)
        #expect(m.convoyRows.map(\.name) == ["Car 1", "Car 2"])
    }

    @Test func myMarkerKeepsItsNameAndArrivedMarkerIsFlagged() {
        let s = order([car("1"), car("2")], ["1": pos(offset: 19_950), "2": pos(offset: 15_000)], main: Self.main)
        let markers = MapMarkerBuilder.markers(from: s, myCarId: "1", now: Self.now)
        #expect(markers[0].label == "Car 1")
        #expect(markers[0].hasArrived)
        #expect(markers[1].label == "Car 2")
        #expect(!markers[1].hasArrived)
    }
}
