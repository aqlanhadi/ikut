import CoreLocation
import Foundation
import Testing
@testable import ikut

private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

/// The ported node tests (`tools/osm/places.test.mjs`): a synthetic dual carriageway running due north.
@Suite("Places along the route")
struct PlacesAlongTests {
    static let northLon = 101.5 // northbound carriageway (drive on the left: the western one)
    static let southLon = 101.5004 // southbound, about 44 m east
    static let lats = (0...200).map { 3 + Double($0) * 0.005 }
    static let northbound = RouteLine(lats.map { c($0, northLon) })
    static let southbound = RouteLine(lats.reversed().map { c($0, southLon) })

    static func box(_ s: Double, _ w: Double, _ n: Double, _ e: Double) -> [CLLocationCoordinate2D] {
        [c(s, w), c(s, e), c(n, e), c(n, w), c(s, w)]
    }

    /// The slip roads as the places file holds them: the west R&R is entered off the northbound carriageway at
    /// 3.495 and rejoins it at 3.505; the east one is entered off the southbound carriageway at 3.505.
    static let west = PlaceSite(
        id: "way/1", kind: .services, name: "Test Rest Area North Bound", coordinate: c(3.5, 101.499),
        ring: box(3.499, 101.4985, 3.501, 101.4995), facilities: [.fuel, .toilets, .food, .ev], brands: ["Petronas"],
        entries: [.init(junction: c(3.495, northLon), bearing: 0, gate: c(3.4992, 101.4995), meters: 480)],
        exits: [.init(junction: c(3.505, northLon), bearing: 0, gate: c(3.5008, 101.4995), meters: 480)])
    static let east = PlaceSite(
        id: "way/2", kind: .services, name: "Test Rest Area South Bound", coordinate: c(3.5, 101.5014),
        ring: box(3.499, 101.5009, 3.501, 101.5019), facilities: [.fuel, .food], brands: ["Shell"],
        entries: [.init(junction: c(3.505, southLon), bearing: 180, gate: c(3.5008, 101.5009), meters: 480)])
    static let layby = PlaceSite(
        id: "way/3", kind: .restArea, name: "Test Layby", coordinate: c(3.6995, 101.4992),
        ring: box(3.699, 101.4990, 3.700, 101.4995), facilities: [.toilets])
    static let townPump = FuelStation(id: "n4", coordinate: c(3.6, 101.45), name: "BHPetrol")

    @Test func westSideIsLeftGoingNorthAndRightGoingSouth() throws {
        #expect(try #require(PlaceSide.sideOf(c(3.5, 101.499), Self.northbound)).side == .left)
        #expect(try #require(PlaceSide.sideOf(c(3.5, 101.499), Self.southbound)).side == .right)
        #expect(try #require(PlaceSide.sideOf(c(3.5, 101.5014), Self.northbound)).side == .right)
    }

    @Test func slipRoadsTellWhichCarriageway() {
        func cw(_ s: PlaceSite, _ line: RouteLine) -> PlaceAlong.Carriageway? {
            PlaceSide.carriageway(entries: s.entries, exits: s.exits, line)
        }
        #expect(cw(Self.west, Self.northbound) == .ours)
        #expect(cw(Self.east, Self.northbound) == .opposite)
        #expect(cw(Self.east, Self.southbound) == .ours)
        #expect(cw(Self.layby, Self.northbound) == nil)
    }

    @Test func alongTheRouteOurSideTheEntranceAndWhereItLeavesTheRoad() throws {
        let rows = PlaceSide.along(
            sites: [Self.east, Self.layby, Self.west], fuel: [Self.townPump], line: Self.northbound)
        let west = try #require(rows.first { $0.name == "Test Rest Area North Bound" })
        let east = try #require(rows.first { $0.name == "Test Rest Area South Bound" })
        #expect(west.ours)
        #expect(!east.ours)
        #expect(west.slipEntrance)
        // The gate, not the middle of the R&R.
        #expect(west.entrance.latitude == 3.4992 && west.entrance.longitude == 101.4995)
        let leaves = try #require(Self.northbound.project(c(3.495, Self.northLon))).offset
        #expect(abs(west.routeOffset - leaves) < 1)
        // No slip road mapped: route to the lay-by itself, at its projected offset.
        let layby = try #require(rows.first { $0.name == "Test Layby" })
        #expect(layby.ours && !layby.slipEntrance)
        #expect(layby.routeOffset == layby.offset)
        // The town pump 5 km away is out of reach.
        #expect(!rows.contains { $0.name == "BHPetrol" })
        // In route order.
        #expect(rows.map(\.routeOffset) == rows.map(\.routeOffset).sorted())
    }

    @Test func anOverheadRnRSpanningTheRoadServesBothDirections() throws {
        let ring = Self.box(3.3, 101.4997, 3.3005, 101.5007)
        #expect(PlaceSide.straddles(ring, Self.northbound))
        #expect(!PlaceSide.straddles(Self.box(3.499, 101.4985, 3.501, 101.4995), Self.northbound))
        let bridge = PlaceSite(id: "way/999", kind: .services, name: "Jejantas", coordinate: c(3.30025, 101.5002),
                               ring: ring, facilities: [.fuel])
        let up = try #require(PlaceSide.along(sites: [bridge], fuel: [], line: Self.northbound).first)
        #expect(up.side == .both && up.ours)
        #expect(try #require(PlaceSide.along(sites: [bridge], fuel: [], line: Self.southbound).first).ours)
    }

    @Test func aLonePumpIsAFuelPlaceWithNothingElse() throws {
        let pump = FuelStation(id: "n5", coordinate: c(3.6, 101.4985), name: "Shell")
        let row = try #require(PlaceSide.along(sites: [], fuel: [pump], line: Self.northbound).first)
        #expect(row.kind == .fuel && row.facilities == [.fuel] && row.brands == ["Shell"] && row.ours)
        #expect(!SuggestStops.isRnR(row))
        #expect(SuggestStops.stopKind(row) == .fuel)
    }

    @Test func bearingsAreComparedAroundTheCompass() {
        #expect(PlaceSide.angleBetween(350, 10) == 20)
        #expect(PlaceSide.angleBetween(0, 180) == 180)
        #expect(abs(PlaceSide.bearing(c(3, 101.5), c(4, 101.5))) < 0.001)
    }
}

/// Candidates as `along` returns them, on a 300 km route driven at 75 km/h (4 h).
@Suite("Suggest stops")
struct SuggestStopsTests {
    static let full: Set<PlaceFacility> = [.fuel, .food, .toilets]

    static func place(_ name: String, _ km: Double, kind: PlaceAlong.Kind = .services, ours: Bool = true,
                      facilities: Set<PlaceFacility> = full) -> PlaceAlong {
        PlaceAlong(id: name, kind: kind, name: name, coordinate: c(3, 101), ring: nil, facilities: facilities, brands: [],
                   offset: km * 1000, distance: 50, side: ours ? .left : .right, carriageway: nil, ours: ours,
                   entrance: c(3, 101), slipEntrance: false, routeOffset: km * 1000)
    }

    static func suggest(_ places: [PlaceAlong], length: Double = 300_000, seconds: Double = 14_400,
                        existing: [Double] = []) -> [StopSuggestion] {
        SuggestStops.suggest(candidates: places, routeLength: length, routeSeconds: seconds, existing: existing)
    }

    /// Minutes along -> km at 75 km/h.
    static func km(_ minutes: Double) -> Double { minutes / 60 * 75 }

    @Test func rnrIsServicesWithFuelNotALaybyHoweverOsmTagsIt() {
        #expect(SuggestStops.isRnR(Self.place("Tapah Rest Area", 1)))
        #expect(!SuggestStops.isRnR(Self.place("Tanjung Malim Layby", 1)))
        #expect(!SuggestStops.isRnR(Self.place("Hentian Sebelah Behrang", 1)))
        #expect(!SuggestStops.isRnR(Self.place("X", 1, kind: .restArea)))
        #expect(!SuggestStops.isRnR(Self.place("X", 1, facilities: [.food, .toilets])))
    }

    @Test func stopKindsAreTheAppsExistingWords() {
        #expect(SuggestStops.stopKind(Self.place("a", 1)) == .fuel)
        #expect(SuggestStops.stopKind(Self.place("a", 1, facilities: [.food, .toilets])) == .food)
        #expect(SuggestStops.stopKind(Self.place("a", 1, facilities: [.toilets])) == .toilet)
        #expect(SuggestStops.stopKind(Self.place("a", 1, facilities: [])) == .rest)
    }

    @Test func theRnROnOurSideNearestEachTwoHours() {
        let picks = Self.suggest([
            Self.place("Early", Self.km(110)), Self.place("Late", Self.km(140)),
            Self.place("Other side", Self.km(120), ours: false), Self.place("Some Layby", Self.km(120)),
        ])
        #expect(picks.map(\.place.name) == ["Early"])
        #expect(picks[0].why == "110 min along · fuel, food, toilets")
    }

    @Test func aNearTieGoesToTheOneWithEVCharging() {
        let picks = Self.suggest([
            Self.place("Plain", Self.km(118)), Self.place("Charger", Self.km(122), facilities: Self.full.union([.ev])),
        ])
        #expect(picks.first?.place.name == "Charger")
    }

    @Test func aStopTheOrganizerAlreadyHasNearTwoHoursCountsAsTheBreak() {
        #expect(Self.suggest([Self.place("R&R", Self.km(120))], existing: [Self.km(125) * 1000]).isEmpty)
    }

    @Test func noneInTheLastHalfHourNoneWhenNothingIsNearTheMark() {
        #expect(Self.suggest([Self.place("Far", Self.km(160))]).isEmpty)
        #expect(Self.suggest([Self.place("Near the end", Self.km(225))]).isEmpty)
    }

    @Test func a2h24TripGetsOneStopNearHalfwayAndA1hTripNone() {
        func at(_ minutes: Double) -> Double { minutes * 60 / 8_640 * 180_000 / 1000 }
        let picks = Self.suggest([Self.place("Quarter", at(30)), Self.place("Middle", at(80)), Self.place("End", at(130))],
                                 length: 180_000, seconds: 8_640)
        #expect(picks.map(\.place.name) == ["Middle"])
        #expect(Self.suggest([Self.place("Middle", 40)], length: 80_000, seconds: 3_600).isEmpty)
    }

    @Test func facilityWordsListWhatThePlaceHas() {
        #expect(SuggestStops.facilityWords(Self.place("a", 1, facilities: [.ev, .toilets, .fuel])) == "fuel, toilets, EV charging")
    }
}
