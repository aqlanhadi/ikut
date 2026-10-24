import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// D26 piece 2: everyone on the route is in the convoy, however far ahead; distance changes the words.
/// Aisha (lead) leaves Cyberjaya at km 0 with Wyna, Daniel is parked at R&R Rawang (km 38), Hafiz is
/// already in Ipoh, the end of the route (km 120).
struct FarAheadTests {
    private static let r = RouteLine.earthRadius
    private static let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)
    private static let now = Fixtures.t0
    private static let gb = Locale(identifier: "en_GB")
    private static let utc = TimeZone(identifier: "UTC")!

    private static func move(_ c: CLLocationCoordinate2D, east: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: c.latitude,
            longitude: c.longitude + east / (r * cos(c.latitude * .pi / 180)) * 180 / .pi)
    }

    /// 120 km due east.
    private static let main = RouteLine(stride(from: 0.0, through: 120_000, by: 1000).map { move(origin, east: $0) })

    private func car(_ id: String, _ name: String, lead: Bool = false) -> Car {
        Car(id: id, name: name, color: "#2563EB", trackerUserId: nil, isLead: lead,
            route: nil, mergeOffset: nil, state: .convoy, number: Int(id))
    }

    private func pos(_ offset: Double, speed: Double = 25, age: TimeInterval = 1) -> Position {
        let c = Self.move(Self.origin, east: offset)
        return Position(
            location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed, heading: 90,
            routeOffset: offset, convoyOffset: offset, battery: nil, updatedAt: Self.now.addingTimeInterval(-age))
    }

    private var aisha: Car { car("1", "Aisha’s Myvi", lead: true) }
    private var wyna: Car { car("2", "Wyna’s X70") }
    private var daniel: Car { car("3", "Daniel’s City") }
    private var hafiz: Car { car("4", "Hafiz’s Hilux") }
    private var sam: Car { car("5", "Sam’s Vios") }

    private func order(_ cars: [Car], _ positions: [String: Position], together: Set<CarPair> = []) -> ConvoySnapshot {
        ConvoyOrdering.order(cars: cars, positions: positions, now: Self.now, mainRoute: Self.main, together: together)
    }

    /// Orders `steps` in turn, carrying who has been together, as `ConvoyModel` does.
    private func run(_ cars: [Car], _ steps: [[String: Position]]) -> [ConvoySnapshot] {
        var together: Set<CarPair> = []
        return steps.map { positions in
            let s = order(cars, positions, together: together)
            together = s.together
            return s
        }
    }

    // MARK: Arrival time and the separation warning

    @Test func parkedAheadIsInTheConvoyButNotTheReference() {
        let steps = run([aisha, wyna, daniel], [
            ["1": pos(100, speed: 0), "2": pos(0, speed: 0), "3": pos(38_000, speed: 0)],
            ["1": pos(20_000), "2": pos(19_800), "3": pos(38_000, speed: 0)],
        ])
        for s in steps {
            #expect(s.convoy.map(\.id) == ["3", "1", "2"])
            #expect(s.front?.id == "3")
            #expect(s.etaReference?.id == "1")
            #expect(s.convoy[0].timeBehindReference == nil)
            #expect(s.convoy[0].isParked)
            // 18 km to Daniel is a gap, but Aisha and Daniel were never together.
            #expect(s.convoy[1].gap?.isSeparated == true)
            #expect(s.driftedGaps.isEmpty)
            #expect(SeparationWarning.text(s.driftedGaps) == nil)
        }
        #expect(steps[1].together == [CarPair("1", "2")])
    }

    /// Found by run-ui: two cars parked 4 km apart, and the lead coming up within 5 km of the first.
    /// Aisha and Daniel are "together" now, but nobody has drifted: no warning about the gap between
    /// the two parked cars.
    @Test func approachingTheParkedCarsWarnsAboutNoGapBetweenThem() {
        let steps = run([aisha, wyna, daniel, sam], [
            ["1": pos(10_000), "2": pos(9_200), "3": pos(28_000, speed: 0), "5": pos(24_000, speed: 0)],
            ["1": pos(23_000), "2": pos(22_200), "3": pos(28_000, speed: 0), "5": pos(24_000, speed: 0)],
        ])
        #expect(steps[1].together.contains(CarPair("3", "1")))
        #expect(steps[1].convoy[1].gap?.isSeparated == true) // 4 km at the parked car's floored speed
        #expect(steps.allSatisfy { $0.driftedGaps.isEmpty })
    }

    @Test func leadNotTrackingTheReferenceIsTheCarWithMostAround() {
        // Aisha's phone is off (stale), Wyna and Sam left together, Daniel parked ahead.
        let s = order([aisha, wyna, daniel, sam], [
            "1": pos(0, age: 600), "2": pos(20_000), "5": pos(19_500), "3": pos(38_000, speed: 0),
        ])
        #expect(s.etaReference?.id == "5")       // a tie with Wyna: the one further back
        let alone = order([aisha, wyna, daniel], ["2": pos(20_000), "3": pos(38_000, speed: 0)])
        #expect(alone.etaReference?.id == "2")   // a tie of nobody around: further back again
        #expect(order([wyna, daniel], ["2": pos(20_000), "3": pos(38_000, speed: 0)]).etaReference?.id == "2")
    }

    @Test func carsThatLeftTogetherDriftApartAsToday() {
        let steps = run([aisha, wyna], [
            ["1": pos(0), "2": pos(-100)],
            ["1": pos(10_000), "2": pos(4_000)],
        ])
        #expect(steps[0].driftedGaps.isEmpty)
        #expect(steps[1].driftedGaps.map(\.id) == ["2"])
        #expect(SeparationWarning.text(steps[1].driftedGaps) == "Wyna is 6.0 km behind the car ahead.")
    }

    @Test func everyoneFarApartStaysQuietUntilCarsThatWereTogetherPart() {
        let steps = run([aisha, wyna, daniel], [
            // Three towns, all on the route.
            ["1": pos(0), "2": pos(30_000), "3": pos(60_000, speed: 0)],
            // Wyna reaches Daniel.
            ["1": pos(20_000), "2": pos(59_900), "3": pos(60_000, speed: 0)],
            // Wyna drives on and Daniel stays.
            ["1": pos(40_000), "2": pos(70_000), "3": pos(60_000, speed: 0)],
        ])
        #expect(steps.map { $0.etaReference?.id } == ["1", "1", "1"])
        #expect(steps[0].driftedGaps.isEmpty)
        #expect(steps[1].driftedGaps.isEmpty)
        #expect(steps[2].driftedGaps.map(\.id) == ["3"])
    }

    @Test func carAlreadyAtTheDestinationHasArrivedAndIsNeverTheReference() {
        let s = order([aisha, wyna, hafiz], ["2": pos(10_000), "4": pos(120_000, speed: 0)])
        #expect(s.hasArrived("4"))
        #expect(s.etaReference?.id == "2")
        let lead = order([aisha, hafiz], ["1": pos(10_000), "4": pos(120_000, speed: 0)])
        #expect(lead.etaReference?.id == "1")
        // Alone, at the destination: no reference.
        #expect(order([hafiz], ["4": pos(120_000, speed: 0)]).etaReference == nil)
    }

    @Test func noFreshCarNothingFiresAndNoReference() {
        let s = order([aisha, daniel], ["1": pos(0, age: 600), "3": pos(38_000, speed: 0, age: 600)])
        #expect(s.etaReference == nil)
        #expect(s.together.isEmpty)
        #expect(s.driftedGaps.isEmpty)
        #expect(CatchUpHeadsUp.nearestBehind(s, myCarId: "3") == nil)
    }

    @Test func distanceAlongTheRouteBetweenCars() {
        let s = order([aisha, daniel], ["1": pos(0), "3": pos(38_000, speed: 0)])
        #expect(s.distance(from: "1", to: "3") == 38_000)
        #expect(s.distance(from: "3", to: "1") == -38_000)
        #expect(s.distance(from: nil, to: "3") == nil)
        #expect(s.distance(from: "1", to: "9") == nil)
    }

    @Test func relativeDistanceOnlyBeyondTwoKilometres() {
        #expect(ConvoyFormat.relativeDistance(38_000) == "38 km ahead")
        #expect(ConvoyFormat.relativeDistance(-40_200) == "40 km behind")
        #expect(ConvoyFormat.relativeDistance(-2_500) == "2.5 km behind")
        #expect(ConvoyFormat.relativeDistance(2_000) == nil)
        #expect(ConvoyFormat.relativeDistance(-1_500) == nil)
        #expect(ConvoyFormat.relativeDistance(.nan) == nil)
    }

    // MARK: The convoy list

    private final class FixedETA: ETAProviding, @unchecked Sendable {
        let calls = Calls()
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var _from: [CLLocationCoordinate2D] = []
            func add(_ c: CLLocationCoordinate2D) { lock.withLock { _from.append(c) } }
            var from: [CLLocationCoordinate2D] { lock.withLock { _from } }
        }
        func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval {
            calls.add(from)
            return 3600
        }
    }

    @MainActor
    private func model(_ cars: [Car], _ positions: [String: Position], me: String?,
                       eta: FixedETA = FixedETA(), place: String? = "Rawang") async -> ConvoyModel {
        let m = ConvoyModel(
            provider: eta, locale: Self.gb, timeZone: Self.utc, clock: { Self.now }, placeNamer: { _ in place })
        m.setMainRoute(Self.main)
        m.destinationName = "Ipoh"
        m.myCarId = me
        m.update(cars: cars, positions: positions)
        await m.waitForPlaceNames()
        await m.waitForETA()
        return m
    }

    @MainActor @Test func farParkedCarsRowSaysHowFarAndWhere() async throws {
        let eta = FixedETA()
        let m = await model([aisha, wyna, daniel],
                            ["1": pos(0), "2": pos(-100), "3": pos(38_000, speed: 0)], me: "1", eta: eta)
        let rows = m.convoyRows
        #expect(rows.map(\.id) == ["3", "1", "2"])
        #expect(rows[0].subtitle == "38 km ahead · parked near Rawang")
        #expect(rows[0].trailingPrimary == "Front")
        #expect(rows[0].trailingSecondary == "")         // no arrival time of its own
        #expect(!rows[0].isSeparated)
        #expect(rows[1].subtitle == "Lead · 90 km/h")
        #expect(rows[2].subtitle == "90 km/h")           // 100 m away: as today
        // The arrival time comes from Aisha, one request.
        #expect(m.arrival(forCar: "1") != nil)
        #expect(eta.calls.from.count == 1)
        #expect(abs((eta.calls.from.first?.longitude ?? 0) - Self.origin.longitude) < 0.001)
    }

    /// The town lookup for a parked far car: once over many refreshes, again after a move of more than
    /// 2 km, and a lookup that found nothing is tried again after 60 s.
    @MainActor @Test func townLookupOnceAgainAfterAMoveAndRetriedAfterAMinute() async {
        final class Namer {
            var answers: [String?]
            var calls: [CLLocationCoordinate2D] = []
            init(_ answers: [String?]) { self.answers = answers }
            func name(_ c: CLLocationCoordinate2D) -> String? {
                calls.append(c)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
        var clock = Self.now
        let namer = Namer([nil, "Rawang", "Rasa"])
        let m = ConvoyModel(
            provider: FixedETA(), locale: Self.gb, timeZone: Self.utc, clock: { clock }, placeNamer: { namer.name($0) })
        m.setMainRoute(Self.main)
        m.myCarId = "1"
        let cars = [aisha, daniel]
        func at(_ danielAt: Double, after seconds: TimeInterval) async {
            clock = Self.now.addingTimeInterval(seconds)
            m.update(cars: cars, positions: ["1": pos(0, age: -seconds), "3": pos(danielAt, speed: 0, age: -seconds)])
            await m.waitForPlaceNames()
        }
        await at(38_000, after: 0)
        #expect(namer.calls.count == 1)                 // found nothing
        await at(38_000, after: 30)
        #expect(namer.calls.count == 1)                 // not before a minute
        await at(38_000, after: 61)
        #expect(namer.calls.count == 2)                 // retried: Rawang
        #expect(m.convoyRows.first?.subtitle == "38 km ahead · parked near Rawang")
        for s in [70.0, 80, 90, 100] { await at(38_300, after: s) } // 300 m of wander
        #expect(namer.calls.count == 2)
        await at(41_000, after: 110)                    // moved 3 km and parked again
        #expect(namer.calls.count == 3)
        #expect(m.convoyRows.first?.subtitle == "41 km ahead · parked near Rasa")
    }

    @MainActor @Test func farMovingCarsRowSaysOnlyHowFar() async {
        let m = await model([aisha, daniel], ["1": pos(0), "3": pos(38_000, speed: 25)], me: "1")
        #expect(m.convoyRows.first?.subtitle == "38 km ahead")
    }

    @MainActor @Test func placeNotFoundYetSaysParked() async {
        let m = await model([aisha, daniel], ["1": pos(0), "3": pos(38_000, speed: 0)], me: "1", place: nil)
        #expect(m.convoyRows.first?.subtitle == "38 km ahead · parked")
    }

    @MainActor @Test func theParkedCarsOwnPhoneSeesTheLeadBehind() async {
        let m = await model([aisha, daniel], ["1": pos(0), "3": pos(38_000, speed: 0)], me: "3")
        let rows = m.convoyRows
        #expect(rows[0].name == "Aisha’s car" || rows[0].isMine)
        #expect(rows[1].subtitle == "Lead · 38 km behind")
    }

    @MainActor @Test func modelRemembersWhoWasTogetherAcrossRefreshes() async {
        let m = await model([aisha, wyna], ["1": pos(0), "2": pos(-100)], me: "1")
        #expect(m.snapshot.driftedGaps.isEmpty)
        m.setPositions(["1": pos(10_000), "2": pos(4_000)])
        #expect(m.snapshot.driftedGaps.map(\.id) == ["2"])
        // A fresh model (a relaunch) with the gap already wide stays quiet.
        let relaunched = await model([aisha, wyna], ["1": pos(10_000), "2": pos(4_000)], me: "1")
        #expect(relaunched.snapshot.driftedGaps.isEmpty)
    }

    // MARK: The heads-up on the parked car's phone

    @Test func headsUpAboutTwoMinutesBeforeTheCarBehindArrives() {
        var watch = CatchUpHeadsUp()
        let cars = [aisha, wyna, daniel]
        func check(_ aishaAt: Double, me: String = "3") -> CatchUpHeadsUp.Due? {
            watch.check(order(cars, ["1": pos(aishaAt), "2": pos(aishaAt - 200), "3": pos(38_000, speed: 0)]),
                        tripId: "t", myCarId: me)
        }
        #expect(check(0) == nil)             // 38 km: 25 min
        #expect(check(30_000) == nil)        // 8 km: 5 min
        let due = check(35_100)              // 2.9 km at 90 km/h: 116 s
        #expect(due?.carId == "1")
        #expect(due?.carPhrase == "Aisha’s car")
        #expect(due?.distance == 2_900)
        #expect(check(36_000) == nil)        // once
        #expect(check(37_000, me: "1") == nil) // Aisha's phone hears nothing
    }

    /// Once per stop (owner, #180): Daniel waits at R&R Rawang (km 38) and hears it; he drives on with
    /// the convoy, waits again at the Tapah toll (km 90), and hears it again. Never twice at one stop.
    @Test func headsUpOncePerStopAndAgainAfterDrivingOn() {
        var watch = CatchUpHeadsUp()
        let cars = [aisha, wyna, daniel]
        func check(aisha: Double, daniel: Double, danielSpeed: Double = 0) -> CatchUpHeadsUp.Due? {
            watch.check(order(cars, ["1": pos(aisha), "2": pos(aisha - 200), "3": pos(daniel, speed: danielSpeed)]),
                        tripId: "t", myCarId: "3")
        }
        // Stop 1.
        #expect(check(aisha: 20_000, daniel: 38_000) == nil)
        #expect(check(aisha: 35_100, daniel: 38_000)?.carId == "1")
        #expect(check(aisha: 36_000, daniel: 38_000) == nil)
        // Still parked as the convoy pulls in (GPS wander of 300 m is not driving on): quiet.
        #expect(check(aisha: 37_800, daniel: 38_300) == nil)
        #expect(check(aisha: 37_900, daniel: 38_000) == nil)
        // Daniel drives on with the convoy, more than 1 km: re-armed, but nobody is far behind.
        #expect(check(aisha: 40_000, daniel: 40_200, danielSpeed: 25) == nil)
        #expect(check(aisha: 60_000, daniel: 60_200, danielSpeed: 25) == nil)
        // Stop 2: he parks at km 90; the convoy, 15 km back, comes up.
        #expect(check(aisha: 75_000, daniel: 90_000) == nil)
        let second = check(aisha: 87_100, daniel: 90_000)
        #expect(second?.carId == "1")
        #expect(second?.stop == 2)
        #expect(check(aisha: 88_000, daniel: 90_000) == nil)
        // Its own alert id, so the alert center announces it although it announced stop 1.
        let first = CatchUpHeadsUp.Due(carId: "1", carPhrase: "Aisha’s car", distance: 2_900, seconds: 116)
        #expect(AlertWording.catchUp(tripId: "t", myCarId: "3", due: first).id
            != AlertWording.catchUp(tripId: "t", myCarId: "3", due: second ?? first).id)
    }

    @Test func headsUpNeverForCarsThatStartTogether() {
        var watch = CatchUpHeadsUp()
        let cars = [aisha, wyna]
        // Wyna parked at the start, Aisha pulls up behind her: first seen already close.
        #expect(watch.check(order(cars, ["2": pos(0, speed: 0), "1": pos(-300, speed: 10)]), tripId: "t", myCarId: "2") == nil)
        #expect(watch.check(order(cars, ["2": pos(0, speed: 0), "1": pos(-100, speed: 10)]), tripId: "t", myCarId: "2") == nil)
    }

    @Test func headsUpTimesTheCarBehindFromItsRealSpeed() {
        let cars = [aisha, daniel]
        // Aisha crawls in a jam at 10 km/h, 300 m back: too slow to be the car coming.
        let jam = order(cars, ["1": pos(37_700, speed: 10 / 3.6), "3": pos(38_000, speed: 0)])
        #expect(CatchUpHeadsUp.nearestBehind(jam, myCarId: "3") == nil)
        // Daniel moving: no heads-up for him.
        let moving = order(cars, ["1": pos(30_000), "3": pos(38_000, speed: 20)])
        #expect(CatchUpHeadsUp.nearestBehind(moving, myCarId: "3") == nil)
        // A car parked just behind Daniel is skipped; the one driving is timed.
        let parkedPair = order([aisha, daniel, wyna],
                               ["1": pos(34_000, speed: 20), "2": pos(37_950, speed: 0), "3": pos(38_000, speed: 0)])
        let due = CatchUpHeadsUp.nearestBehind(parkedPair, myCarId: "3")
        #expect(due?.carId == "1")
        #expect(due?.seconds == 200)
    }

    @Test func headsUpWords() {
        let due = CatchUpHeadsUp.Due(carId: "1", carPhrase: "Aisha’s car", distance: 2_900, seconds: 116)
        let a = AlertWording.catchUp(tripId: "t", myCarId: "3", due: due)
        #expect(a.title == "Aisha’s car is behind you")
        #expect(a.body == "2.9 km · about 2 min away")
        #expect(a.spoken == "Aisha’s car is 2.9 km behind you.")
        #expect(a.kind == .catchUp)
        #expect(a.id == "3@catchup")
        #expect(a.eventId == "1")
        #expect(CatchUpHeadsUp.phrase("Red Myvi") == "Red Myvi")
    }

    @MainActor @Test func headsUpGoesOffOnceOnTheParkedCarsPhone() {
        let announcer = RecordingAnnouncer()
        let mine = TripMapModel(
            session: nil, convoy: ConvoyModel(provider: FixedETA(), clock: { Self.now }, placeNamer: { _ in nil }))
        mine.convoy.setMainRoute(Self.main)
        mine.startHazardAlerts(announcer: announcer, userId: "u3", tripId: "t")
        let cars = [aisha, wyna, daniel]
        mine.setCars(cars)
        func drive(_ at: Double, me: String = "3", model: TripMapModel? = nil) {
            (model ?? mine).apply(trip: nil, myCar: nil, myCarId: me,
                                  positions: ["1": pos(at), "2": pos(at - 200), "3": pos(38_000, speed: 0)], isTracker: true)
        }
        drive(30_000)
        #expect(announcer.alerts.isEmpty)
        #expect(mine.catchUp == nil)
        drive(35_100)
        #expect(announcer.alerts.map(\.spoken) == ["Aisha’s car is 2.9 km behind you."])
        #expect(mine.catchUp?.title == "Aisha’s car is behind you")
        #expect(mine.catchUpDistance(mine.catchUp!, now: Self.now.addingTimeInterval(-1)) == 2_900)
        drive(36_000)
        #expect(announcer.alerts.count == 1)
        #expect(mine.catchUp != nil)
        drive(37_900)                        // 100 m: the pill goes
        #expect(mine.catchUp == nil)

        // Aisha's phone hears nothing.
        let hers = RecordingAnnouncer()
        let lead = TripMapModel(
            session: nil, convoy: ConvoyModel(provider: FixedETA(), clock: { Self.now }, placeNamer: { _ in nil }))
        lead.convoy.setMainRoute(Self.main)
        lead.startHazardAlerts(announcer: hers, userId: "u1", tripId: "t")
        lead.setCars(cars)
        drive(30_000, me: "1", model: lead)
        drive(35_100, me: "1", model: lead)
        #expect(hers.alerts.isEmpty)
    }

    @MainActor private final class RecordingAnnouncer: AlertAnnouncing {
        var alerts: [TripAlert] = []
        func announce(event: TripEvent, distance: Double?) async -> Bool { false }
        func announce(alert: TripAlert) -> Bool {
            alerts.append(alert)
            return true
        }
    }

    // MARK: Stop requests from far away

    private func stopEvent(car: String = "2") -> TripEvent {
        var e = TripEvent(
            type: .stopFuel, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: "u2", carId: car, createdAt: Self.now)
        e.id = "s1"
        return e
    }

    @Test func farStopRequestSaysHowFarInEveryLine() {
        let a = AlertWording.alert(for: stopEvent(), tripId: "t", authorName: "Wyna", far: "40 km behind", now: Self.now)
        #expect(a.spoken == "Wyna needs fuel, 40 km behind. Tap OK.")
        #expect(a.body == "Wyna’s car wants to stop for fuel · 40 km behind · just now")
        #expect(a.title == "Stop request")
        let near = AlertWording.alert(for: stopEvent(), tripId: "t", authorName: "Wyna", now: Self.now)
        #expect(near.spoken == "Wyna needs fuel. Tap OK.")
        #expect(near.body == "Wyna’s car wants to stop for fuel · just now")
    }
}
