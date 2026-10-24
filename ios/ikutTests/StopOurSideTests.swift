import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

/// Straight roads that record where each leg ends.
private final class Recording: LegRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _ends: [CLLocationCoordinate2D] = []
    /// The road for the one leg that reaches the end of this line, when it is given (the direct route to a destination).
    private let direct: [CLLocationCoordinate2D]?
    init(direct: [CLLocationCoordinate2D]? = nil) { self.direct = direct }
    var ends: [CLLocationCoordinate2D] { lock.withLock { _ends } }
    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        lock.withLock { _ends.append(to) }
        var points = [from, to]
        if let direct, to.latitude == direct.last?.latitude, from.latitude == direct.first?.latitude { points = direct }
        let length = RouteLine.haversine(from, to)
        return RouteLeg(coordinates: points, distance: length, travelTime: length / 25, name: "E1")
    }
}

/// D4 piece 4: a rest-area stop lands on the carriageway we drive, on the real KL to Ipoh drives.
@Suite("Stops land on our side of the highway")
struct StopOurSideTests {
    static let north = PlacesKLIpohTests.drive("kl-ipoh-north").line
    static let south = PlacesKLIpohTests.drive("kl-ipoh-south").line
    static let sites = PlacesKLIpohTests.file.sites

    /// The Tapah R&R on `line`'s side, and the other one.
    static func tapah(_ line: RouteLine) -> (ours: PlaceSite, other: PlaceSite) {
        let rows = PlacesKLIpohTests.along(line).filter { $0.name == "Tapah Rest Area" && $0.kind == .services }
        let ours = sites.first { $0.id == rows.first { $0.ours }!.id }!
        let other = sites.first { $0.name == "Tapah Rest Area" && $0.id != ours.id }!
        return (ours, other)
    }

    static func stop(_ at: CLLocationCoordinate2D, kind: PlannedStopKind = .fuel, name: String = "R&R Tapah") -> StopDraft {
        StopDraft(name: name, coordinate: at, kind: kind)
    }

    @Test func aStopAtTheSouthboundTapahMovesToTheNorthboundOneGoingNorthAndBack() {
        let (northOurs, southOurs) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        #expect(northOurs.id != southOurs.id)
        let a = OurSide.snap([Self.stop(southOurs.coordinate)], on: Self.north, sites: Self.sites)[0]
        #expect(a.coordinate.latitude == northOurs.coordinate.latitude && a.coordinate.longitude == northOurs.coordinate.longitude)
        #expect(a.name == "R&R Tapah")
        let b = OurSide.snap([Self.stop(northOurs.coordinate)], on: Self.south, sites: Self.sites)[0]
        #expect(b.coordinate.latitude == southOurs.coordinate.latitude && b.coordinate.longitude == southOurs.coordinate.longitude)
    }

    @Test func aStopAlreadyOnOurSideStaysWhereItIs() {
        let ours = Self.tapah(Self.north).ours
        let near = c(ours.coordinate.latitude + 0.0003, ours.coordinate.longitude)
        let out = OurSide.snap([Self.stop(near)], on: Self.north, sites: Self.sites)[0]
        #expect(out.coordinate.latitude == near.latitude && out.coordinate.longitude == near.longitude)
    }

    @Test func simpangPulaiTwinsAreMatchedByNameWithoutTheDirection() {
        let utara = Self.sites.first { $0.id == "way/339101034" }!
        let selatan = Self.sites.first { $0.id == "way/339101035" }!
        #expect(OurSide.baseName(utara.name) == OurSide.baseName(selatan.name))
        #expect(OurSide.baseName("Pagoh Rest Area South Bound") == OurSide.baseName("Pagoh Rest Area (Northbound)"))
        #expect(OurSide.baseName(nil) == nil)
        let goingNorth = OurSide.snap([Self.stop(selatan.coordinate, name: "Simpang Pulai")], on: Self.north, sites: Self.sites)[0]
        let goingSouth = OurSide.snap([Self.stop(utara.coordinate, name: "Simpang Pulai")], on: Self.south, sites: Self.sites)[0]
        #expect(goingNorth.latitude == utara.coordinate.latitude)
        #expect(goingSouth.latitude == selatan.coordinate.latitude)
    }

    @Test func theOverheadBridgeServesBothWaysSoItIsNotMoved() {
        let north = PlacesKLIpohTests.drive("sungai-buloh-north").line
        let south = RouteLine(north.coordinates.reversed())
        let bridge = Self.sites.first { $0.id == "relation/11949586" }!
        for line in [north, south] {
            let out = OurSide.snap([Self.stop(bridge.coordinate, name: "Sungai Buloh")], on: line, sites: Self.sites)[0]
            #expect(out.latitude == bridge.coordinate.latitude && out.longitude == bridge.coordinate.longitude)
        }
    }

    @Test func aMealNearAnRnRAStopFarFromAnySiteAndNoRouteAreLeftAlone() {
        let other = Self.tapah(Self.north).other
        let meal = Self.stop(other.coordinate, kind: .food, name: "Lunch")
        #expect(OurSide.snap([meal], on: Self.north, sites: Self.sites)[0] == meal)
        let sight = Self.stop(other.coordinate, kind: .sight, name: "View")
        #expect(OurSide.snap([sight], on: Self.north, sites: Self.sites)[0] == sight)
        // Mid-way across the Selangor hills, no site within 300 m.
        let mid = Self.north.coordinate(atOffset: Self.north.length * 0.3)!
        let nowhere = Self.stop(mid)
        #expect(OurSide.snap([nowhere], on: Self.north, sites: Self.sites)[0] == nowhere)
        let wrong = Self.stop(other.coordinate)
        #expect(OurSide.snap([wrong], on: nil, sites: Self.sites)[0] == wrong)
        // A site with no twin of the same name: left where it is.
        let lone = Self.sites.filter { $0.id == other.id }
        #expect(OurSide.snap([wrong], on: Self.north, sites: lone)[0] == wrong)
    }

    @Test func theMeetingPointIsNeverMoved() {
        let other = Self.tapah(Self.north).other
        let meet = StopDraft(name: "Meet", coordinate: other.coordinate, kind: .meet)
        #expect(OurSide.snap([meet], on: Self.north, sites: Self.sites)[0] == meet)
    }

    @Test func theLegsEndAtTheTwinsPoint() async throws {
        let (ours, other) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        #expect(ours.id != other.id)
        let roads = Recording()
        let end = Self.north.coordinates.last!
        let built = try await StopPlanner.build(
            items: [Self.stop(other.coordinate)], destination: end, origin: { Self.north.coordinates.first },
            fallbackStart: nil, router: roads, ourSide: Self.north, sites: Self.sites)
        #expect(roads.ends.count == 2)
        #expect(roads.ends[0].latitude == ours.coordinate.latitude && roads.ends[0].longitude == ours.coordinate.longitude)
        #expect(built.items[0].latitude == ours.coordinate.latitude)
        // Without the route there is nothing to snap by: the leg ends where the organizer put the stop.
        let plain = Recording()
        _ = try await StopPlanner.build(
            items: [Self.stop(other.coordinate)], destination: end, origin: { Self.north.coordinates.first },
            fallbackStart: nil, router: plain)
        #expect(plain.ends[0].latitude == other.coordinate.latitude)
    }

    @Test func theBundledFileLoadsAndTheDefaultSitesMoveAStop() async throws {
        #expect(OurSide.bundledSites.count > 300)
        #expect(OurSide.bundledSites.contains { $0.name == "Tapah Rest Area" })
        let (ours, other) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        let built = try await StopPlanner.build(
            items: [Self.stop(other.coordinate)], destination: Self.north.coordinates.last!,
            origin: { Self.north.coordinates.first }, fallbackStart: nil, router: Recording(), ourSide: Self.north)
        #expect(built.items[0].latitude == ours.coordinate.latitude && built.items[0].longitude == ours.coordinate.longitude)
    }

    @Test func aStopAbout250mFromTheOutlineMovesAndAbout350mDoesNot() {
        let (ours, other) = (Self.tapah(Self.north).ours, Self.tapah(Self.north).other)
        // Walk away from our twin, past the other one, until the outline is the given distance off.
        let dLat = other.coordinate.latitude - ours.coordinate.latitude
        let dLon = other.coordinate.longitude - ours.coordinate.longitude
        let norm = (dLat * dLat + dLon * dLon).squareRoot()
        func away(_ meters: Double) -> CLLocationCoordinate2D {
            var k = 0.0
            while true {
                let p = c(other.coordinate.latitude + dLat / norm * k * 0.00001, other.coordinate.longitude + dLon / norm * k * 0.00001)
                if OurSide.distance(from: p, to: other) >= meters { return p }
                k += 1
            }
        }
        let near = Self.stop(away(250)), far = Self.stop(away(350))
        let nearAt = OurSide.distance(from: near.coordinate, to: other)
        #expect(nearAt >= 250 && nearAt < 270)
        #expect(OurSide.snap([near], on: Self.north, sites: Self.sites)[0].coordinate.latitude == ours.coordinate.latitude)
        #expect(OurSide.snap([far], on: Self.north, sites: Self.sites)[0] == far)
    }

    @Test func aSnapChangesOnlyTheCoordinate() {
        let (ours, other) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        let meetAt = Date(timeIntervalSince1970: 5_000)
        var stop = StopDraft(id: "keep-me", name: "R&R Tapah", coordinate: other.coordinate, kind: .toilet, minutes: 25, meetAt: meetAt, routeOffset: 12_345)
        stop.meetAt = meetAt
        let out = OurSide.snap([stop], on: Self.north, sites: Self.sites)[0]
        #expect(out.latitude == ours.coordinate.latitude)
        #expect(out.id == "keep-me" && out.kind == .toilet && out.minutes == 25 && out.name == "R&R Tapah")
        #expect(out.meetAt == stop.meetAt && out.routeOffset == 12_345)
        var restored = out
        restored.latitude = stop.latitude; restored.longitude = stop.longitude
        #expect(restored == stop)
    }

    /// Going north the stop is at the southbound Tapah; a new destination back in KL reverses the trip, and the
    /// direct route to it decides the side again.
    @Test func aNewDestinationThatReversesTheTripMovesTheStopToTheOtherTwin() async throws {
        let (northOurs, southOurs) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        let ipoh = Self.north.coordinates.last!, kl = Self.north.coordinates.first!
        let roads = Recording(direct: Self.south.coordinates)
        let meet = StopDraft(name: "Meet", coordinate: ipoh, kind: .meet)
        let built = try await StopPlanner.build(
            items: [meet, Self.stop(northOurs.coordinate)], destination: kl, fallbackStart: nil, router: roads,
            snapOnDirectRoute: true, sites: Self.sites)
        #expect(built.items[1].latitude == southOurs.coordinate.latitude)
        // The direct route, then the two legs through the stop.
        #expect(roads.ends.count == 3)
        #expect(roads.ends[1].latitude == southOurs.coordinate.latitude)
        // No stop at a site: no direct route asked for.
        let plain = Recording(direct: Self.south.coordinates)
        _ = try await StopPlanner.build(
            items: [meet, Self.stop(Self.north.coordinate(atOffset: Self.north.length * 0.3)!)], destination: kl,
            fallbackStart: nil, router: plain, snapOnDirectRoute: true, sites: Self.sites)
        #expect(plain.ends.count == 2)
    }

    @MainActor
    @Test func theLobbyPlannerSnapsOnItsRouteAndASecondRunLeavesTheStopWhereItIs() async throws {
        let (ours, other) = (Self.tapah(Self.north).ours, Self.tapah(Self.south).ours)
        let end = Self.north.coordinates.last!
        let roads = Recording()
        final class Saved { var plans: [StopPlanSave] = [] }
        let saved = Saved()
        let planner = StopPlanner(
            router: roads, delay: .zero, origin: { Self.north.coordinates.first }, save: { saved.plans.append($0) })
        let trip = Trip.fixture(
            organizerId: "u", route: Polyline.encode(Self.north.coordinates),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: end.latitude, longitude: end.longitude)))
        planner.sync(trip: trip, stops: [])
        planner.add(Self.stop(other.coordinate))
        await waitUntil(.seconds(5)) { planner.status == .saved }
        #expect(planner.status == .saved)
        let first = try #require(saved.plans.last)
        #expect(first.stops[0].coordinate.latitude == ours.coordinate.latitude)
        #expect(roads.ends[0].latitude == ours.coordinate.latitude)
        // A second edit builds again with the stop already on our side: it stays, and the leg still ends there.
        let before = roads.ends.count
        planner.add(Self.stop(Self.north.coordinate(atOffset: Self.north.length * 0.3)!, kind: .food, name: "Lunch"))
        await waitUntil(.seconds(5)) { planner.status == .saved }
        await waitUntil(.seconds(5)) { saved.plans.count >= 2 }
        let second = try #require(saved.plans.last)
        #expect(second.stops.count == 2)
        let tapah = try #require(second.stops.first { $0.name == "R&R Tapah" })
        #expect(tapah.coordinate.latitude == ours.coordinate.latitude && tapah.coordinate.longitude == ours.coordinate.longitude)
        #expect(roads.ends.count > before)
        #expect(roads.ends[before...].contains { $0.latitude == ours.coordinate.latitude })
    }

    @Test func howOftenOurTwinHasAMappedGate() {
        var withGate = 0, total = 0
        for line in [Self.north, Self.south] {
            for row in PlacesKLIpohTests.along(line) where row.ours && row.kind != .fuel {
                total += 1
                if row.slipEntrance { withGate += 1 }
            }
        }
        print("D4 our-side twins with a mapped gate on KL-Ipoh both ways: \(withGate) of \(total)")
        #expect(total > 0)
    }
}

/// Piece 2 review follow-ups: the edges of the slip-road and prefilter rules.
@Suite("Side of the road edges")
struct PlaceSideEdgeTests {
    static let line = PlacesAlongTests.northbound

    @Test func aSlipRoadAtASlantIsNeitherSide() {
        let junction = c(3.5, PlacesAlongTests.northLon)
        for bearing: Double in [61, 90, 119] {
            let s = PlaceSlipRoad(junction: junction, bearing: bearing, gate: junction, meters: 100)
            #expect(PlaceSide.junctionSide(s, Self.line) == nil, "\(bearing)")
        }
        #expect(PlaceSide.junctionSide(.init(junction: junction, bearing: 60, gate: junction, meters: 1), Self.line) == .ours)
        #expect(PlaceSide.junctionSide(.init(junction: junction, bearing: 120, gate: junction, meters: 1), Self.line) == .opposite)
    }

    @Test func aJunctionFarFromTheLineIsNotOnTheRoad() {
        // About 0.0012 degrees of longitude is 133 m; 0.001 is 111 m.
        let far = PlaceSlipRoad(junction: c(3.5, PlacesAlongTests.northLon + 0.0012), bearing: 0, gate: c(3.5, 101.51), meters: 1)
        let near = PlaceSlipRoad(junction: c(3.5, PlacesAlongTests.northLon + 0.001), bearing: 0, gate: c(3.5, 101.51), meters: 1)
        #expect(PlaceSide.junctionSide(far, Self.line) == nil)
        #expect(PlaceSide.junctionSide(near, Self.line) == .ours)
    }

    @Test func theCarriagewayFallsBackToExitsWhenThereIsNoEntry() {
        let exit = PlaceSlipRoad(junction: c(3.505, PlacesAlongTests.northLon), bearing: 0, gate: c(3.5008, 101.4995), meters: 480)
        #expect(PlaceSide.carriageway(entries: [], exits: [exit], Self.line) == .ours)
        // An entry that reaches no road is passed over for an exit that does.
        let stray = PlaceSlipRoad(junction: c(3.5, 101.6), bearing: 0, gate: c(3.5, 101.6), meters: 10)
        #expect(PlaceSide.carriageway(entries: [stray], exits: [exit], Self.line) == .ours)
    }

    @Test func aPlace500mPastTheEndOfTheRouteIsKeptAndOne700mPastIsDropped() {
        func past(_ meters: Double, _ id: String) -> PlaceSite {
            let end = Self.line.coordinates.last!
            let lat = end.latitude + meters / RouteLine.earthRadius * 180 / .pi
            return PlaceSite(id: id, kind: .services, name: id, coordinate: c(lat, end.longitude - 0.0005), facilities: [.fuel])
        }
        let rows = PlaceSide.along(sites: [past(500, "near"), past(700, "far")], fuel: [], line: Self.line)
        #expect(rows.map(\.id) == ["near"])
    }
}
