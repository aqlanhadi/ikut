import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// D26: the convoy panel's header and joining rows show the viewer's own trip; a slow car says how far, not how long.
@MainActor
struct ConvoyHeaderTests {
    private static let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)
    private static let now = Fixtures.t0
    private static var main: RouteLine {
        RouteLine(MapDemo.densify([origin, .init(latitude: 3.0, longitude: 101.2)]))
    }
    private static let floor = ConvoyOrdering.Config.default.parkedSpeed

    private func car(route: String? = nil, merge: Double? = nil, state: CarState = .joining) -> Car {
        Car(id: "4", name: "Hafiz’s Hilux", color: "#0F766E", trackerUserId: nil, isLead: false,
            route: route, mergeOffset: merge, state: state, number: 4)
    }

    private func entry(speed: Double, time: Double? = 1800, distance: Double? = 14_000) -> JoiningEntry {
        JoiningEntry(id: "4", car: car(), position: nil, distanceToMerge: distance, timeToMerge: time, speed: speed, isStale: false)
    }

    // MARK: From

    @Test func fromIsTheOwnStartTownWhenTheCarHasARoute() {
        #expect(ConvoyHeader.from(car: car(route: "abc", merge: 5000), ownStartTown: "Shah Alam", mainStartTown: "Cyberjaya") == "Shah Alam")
        // Route known but the town hasn't come back yet.
        #expect(ConvoyHeader.from(car: car(route: "abc"), ownStartTown: nil, mainStartTown: "Cyberjaya") == "Your start")
    }

    @Test func fromIsTheMainStartWhenTheCarIsOnTheMainRoute() {
        let onMain = car(route: nil, merge: 400, state: .convoy)
        #expect(ConvoyHeader.from(car: onMain, ownStartTown: nil, mainStartTown: "Cyberjaya") == "Cyberjaya")
    }

    @Test func fromIsYourStartWhenNothingIsKnownYet() {
        #expect(ConvoyHeader.from(car: car(route: nil, merge: nil), ownStartTown: nil, mainStartTown: "Cyberjaya") == "Your start")
    }

    // MARK: Joining line for each kind

    @Test func joiningLineWhenMovingSaysTime() throws {
        let line = try #require(ConvoyHeader.joining(
            .merges(offset: 35_000), place: "Rawang", destination: "Ipoh", amount: .time(20 * 60)))
        #expect(line.line == "Joining near Rawang · 20 min")
        #expect(line.spoken == "joining near Rawang, 20 minutes away")
    }

    @Test func joiningLineWhenSlowSaysDistance() throws {
        let line = try #require(ConvoyHeader.joining(
            .merges(offset: 35_000), place: "Rawang", destination: "Ipoh", amount: .distance(14_000)))
        #expect(line.line == "Joining near Rawang · 14 km")
        #expect(line.spoken == "joining near Rawang, 14 km away")
    }

    @Test func joiningLineWithoutPlaceOrEstimate() throws {
        #expect(ConvoyHeader.joining(.merges(offset: 1), place: nil, destination: "Ipoh", amount: nil)?.line == "Joining the convoy")
        #expect(ConvoyHeader.joining(.merges(offset: 1), place: "Rawang", destination: "Ipoh", amount: nil)?.line == "Joining near Rawang")
    }

    @Test func joiningLineForACarThatNeverMerges() throws {
        let line = try #require(ConvoyHeader.joining(
            .meetsAtDestination, place: nil, destination: "Ipoh", amount: .distance(160_000)))
        #expect(line.line == "Meets the convoy in Ipoh · 160 km")
        #expect(line.spoken == "meets the convoy in Ipoh, 160 km away")
    }

    @Test func noJoiningLineOnTheMainRouteOrBeforeTheRouteIsKnown() {
        #expect(ConvoyHeader.joining(.startsWithConvoy, place: nil, destination: "Ipoh", amount: nil) == nil)
        #expect(ConvoyHeader.joining(.onRoute(offset: 38_000), place: nil, destination: "Ipoh", amount: .time(60)) == nil)
        #expect(ConvoyHeader.joining(nil, place: nil, destination: "Ipoh", amount: nil) == nil)
    }

    @Test func onceInTheConvoyTheJoiningLineGoesAndLeftComesBack() {
        let joining = ConvoyHeader.text(
            car: car(route: "abc", merge: 35_000), joinEntry: entry(speed: 25), join: .merges(offset: 35_000),
            ownStartTown: "Shah Alam", mainStartTown: "Cyberjaya", joinPlace: "Rawang", destination: "Ipoh", amount: .time(1200))
        #expect(joining.joinLine == "Joining near Rawang · 20 min")
        let merged = ConvoyHeader.text(
            car: car(route: "abc", merge: 35_000, state: .convoy), joinEntry: nil, join: .merges(offset: 35_000),
            ownStartTown: "Shah Alam", mainStartTown: "Cyberjaya", joinPlace: "Rawang", destination: "Ipoh", amount: nil)
        #expect(merged.joinLine == nil)
        #expect(merged.from == "Shah Alam")
    }

    // MARK: Moving vs under the floor

    @Test func timeAboveTheFloorDistanceBelow() {
        func amount(_ speed: Double) -> ConvoyFormat.JoinAmount? {
            ConvoyFormat.joinAmount(timeToMerge: 1200, distanceToMerge: 14_000, speed: speed, parkedSpeed: Self.floor)
        }
        #expect(amount(20.1 / 3.6) == .time(1200))
        #expect(amount(19.9 / 3.6) == .distance(14_000))
        #expect(amount(0) == .distance(14_000))
        #expect(ConvoyFormat.joinAmount(timeToMerge: nil, distanceToMerge: nil, speed: 0, parkedSpeed: Self.floor) == nil)
    }

    // MARK: Rows and summary

    private struct StubETA: ETAProviding {
        func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval { 1800 }
    }

    private func model(speed: Double) -> ConvoyModel {
        let m = ConvoyModel(provider: StubETA(), locale: Locale(identifier: "en_GB"),
                            timeZone: TimeZone(identifier: "UTC")!, clock: { Self.now })
        m.setMainRoute(Self.main)
        func pos(_ c: CLLocationCoordinate2D, speed: Double, offset: Double?) -> Position {
            Position(location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed, heading: 90,
                     routeOffset: offset ?? 0, convoyOffset: offset, battery: nil, updatedAt: Self.now.addingTimeInterval(-1))
        }
        // Hafiz is 14 km due south of the main-route point at 20 km.
        let target = Self.main.coordinate(atOffset: 20_000)!
        let south = CLLocationCoordinate2D(latitude: target.latitude - 14_000 / 111_195, longitude: target.longitude)
        let lead = Car(id: "1", name: "Car 1", color: "#2563EB", trackerUserId: nil, isLead: true, route: nil, mergeOffset: nil, state: .convoy, number: 1)
        m.update(cars: [lead, car(merge: 20_000)], positions: [
            "1": pos(Self.main.coordinate(atOffset: 8000)!, speed: 25, offset: 8000),
            "4": pos(south, speed: speed, offset: nil),
        ])
        return m
    }

    @Test func rowSaysTimeWhileMovingAndDistanceUnderTheFloor() {
        let moving = model(speed: 25).joiningRows
        #expect(moving.first?.trailingPrimary.hasSuffix("min") == true || moving.first?.trailingPrimary.hasSuffix("h") == true)
        #expect(moving.first?.trailingSecondary == "to merge")
        let slow = model(speed: 0).joiningRows
        #expect(slow.first?.trailingPrimary.hasSuffix("km") == true)
        #expect(slow.first?.trailingSecondary == "to merge")
        let justUnder = model(speed: 5.55).joiningRows
        #expect(justUnder.first?.trailingPrimary.hasSuffix("km") == true)
        let justOver = model(speed: 5.56).joiningRows
        #expect(justOver.first?.trailingPrimary.hasSuffix("km") == false)
    }

    @Test func summaryNamesDistanceNotTimeUnderTheFloor() {
        let mine = ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Car 4", joinIn: 7200, spread: nil, joinerIsMe: true, joinAmount: .distance(14_000))
        #expect(mine.joining == "You join in 14 km")
        let other = ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Hafiz\u{2019}s Hilux", joinIn: 7200, spread: nil, joinAmount: .distance(14_000))
        #expect(other.joining == "Hafiz joins in 14 km")
        let moving = ConvoyFormat.convoySummary(
            driving: 3, joinerName: "Hafiz\u{2019}s Hilux", joinIn: 18 * 60, spread: nil, joinAmount: .time(18 * 60))
        #expect(moving.joining == "Hafiz joins in 18 min")
    }

    // MARK: VoiceOver

    @Test func labelForAJoiningCarAndAConvoyCar() {
        let joining = ConvoyHeader.Text(from: "Shah Alam", joinLine: "x", spokenJoin: "joining near Rawang, 14 km away")
        #expect(ConvoyHeader.label(title: "3 in Convoy", text: joining, destination: "Ipoh", arrive: "3:40 PM")
            == "3 in Convoy, from Shah Alam, joining near Rawang, 14 km away, to Ipoh, arrive 3:40 PM")
        let inConvoy = ConvoyHeader.Text(from: "Shah Alam", joinLine: nil, spokenJoin: nil)
        #expect(ConvoyHeader.label(title: "3 in Convoy", text: inConvoy, destination: "Ipoh", arrive: "3:40 PM")
            == "3 in Convoy, from Shah Alam to Ipoh, arrive 3:40 PM")
        #expect(ConvoyHeader.label(title: "3 in Convoy", text: inConvoy, destination: "Ipoh", arrive: nil)
            == "3 in Convoy, from Shah Alam to Ipoh")
        let never = ConvoyHeader.Text(from: "George Town", joinLine: "x", spokenJoin: "meets the convoy in Ipoh, 160 km away")
        #expect(ConvoyHeader.label(title: "3 in Convoy", text: never, destination: "Ipoh", arrive: "3:40 PM")
            == "3 in Convoy, from George Town, meets the convoy in Ipoh, 160 km away, arrive 3:40 PM")
    }

    // MARK: Never merges, by road

    @Test func neverMergingCarDistanceIsTheRestOfItsOwnRoute() throws {
        let m = ConvoyModel(provider: StubETA(), locale: Locale(identifier: "en_GB"),
                            timeZone: TimeZone(identifier: "UTC")!, clock: { Self.now })
        m.setMainRoute(Self.main)
        // A dog-leg west of the main route: about 110 km by road, about 95 km straight to the main route's end.
        let own = RouteLine(MapDemo.densify([
            .init(latitude: 3.5, longitude: 100.5), .init(latitude: 3.5, longitude: 100.0), .init(latitude: 3.0, longitude: 100.0)]))
        let c = own.coordinates[0]
        let p = Position(location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: 0, heading: 180,
                         routeOffset: 10_000, convoyOffset: nil, battery: nil, updatedAt: Self.now.addingTimeInterval(-1))
        let hafiz = car(route: Polyline.encode(own.coordinates), merge: Self.main.length)
        m.update(cars: [hafiz], positions: ["4": p])
        let entry = try #require(m.joining.first)
        #expect(abs(try #require(entry.distanceToMerge) - (own.length - 10_000)) < 200)
        #expect(m.joiningRows.first?.trailingPrimary == ConvoyFormat.distance(own.length - 10_000))
    }

    // MARK: Panel wiring

    @Test func summaryAndHeaderUseTheJoinAmountOfMyJoiningCar() {
        let m = model(speed: 0)
        m.myCarId = "4"
        let summary = m.summaryParts(myCarId: "4")
        #expect(summary.joining?.hasPrefix("You join in ") == true)
        #expect(summary.joining?.hasSuffix("km") == true)
        let header = m.headerText(
            car: car(route: "abc", merge: 20_000), join: .merges(offset: 20_000), ownStartTown: "Shah Alam",
            mainStartTown: "Cyberjaya", joinPlace: "Rawang", destination: "Ipoh")
        #expect(header.joinLine?.hasPrefix("Joining near Rawang · ") == true)
        #expect(header.joinLine?.hasSuffix("km") == true)
        // Not my car: no joining line.
        m.myCarId = "1"
        let other = m.headerText(
            car: car(route: "abc", merge: 20_000, state: .convoy), join: .merges(offset: 20_000), ownStartTown: "Shah Alam",
            mainStartTown: "Cyberjaya", joinPlace: "Rawang", destination: "Ipoh")
        #expect(other.joinLine == nil)
    }
}
