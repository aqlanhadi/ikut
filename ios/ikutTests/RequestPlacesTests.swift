import CoreLocation
import Foundation
import Testing
@testable import ikut

/// Places on a stop request: the port of `rankForRequest`, `requestWhere` and `requestWhy` (the same cases as
/// `tools/osm/places.test.mjs`), then the real KL to Ipoh drive and the card's model.
@Suite("Request places")
struct RequestPlacesTests {
    static let full: Set<PlaceFacility> = [.fuel, .food, .toilets]
    static let speed = 25.0 // m/s, 90 km/h

    /// A candidate as `PlaceSide.along` returns it.
    static func place(
        _ name: String, _ km: Double, ours: Bool = true, facilities: Set<PlaceFacility>? = nil,
        kind: PlaceAlong.Kind = .services
    ) -> PlaceAlong {
        PlaceAlong(
            id: name, kind: kind, name: name, coordinate: .init(latitude: 3, longitude: 101), ring: nil,
            facilities: facilities ?? full, brands: [], offset: km * 1000, distance: 40, side: ours ? .left : .right,
            carriageway: nil, ours: ours, entrance: .init(latitude: 3, longitude: 101), slipEntrance: false,
            routeOffset: km * 1000)
    }

    static func names(_ rows: [(place: PlaceAlong, minutes: Int, whereText: String, why: String)]) -> [String?] {
        rows.map(\.place.name)
    }

    @Test func aheadOfTheLeadOnOurSideWithinTheMostUrgentReason() {
        let rows = RequestPlaces.rank([
            Self.place("Behind", 50), Self.place("Just ahead", 60.3), Self.place("Opposite", 70, ours: false),
            Self.place("Toilet in 15 min", 60 + 22.5), Self.place("In 25 min", 60 + 37.5),
        ], frontOffset: 60_000, reasons: [.toilet], speed: Self.speed)
        #expect(Self.names(rows) == ["Toilet in 15 min"])
        #expect(rows[0].whereText == "23 km ahead · about 15 min")
        #expect(rows[0].why == "toilets")
    }

    @Test func coveringEveryReasonFirstThenNearestWithLaybysFurther() {
        let noFuel: Set<PlaceFacility> = [.toilets]
        let rows = RequestPlaces.rank([
            Self.place("Toilets only", 70, facilities: noFuel),
            Self.place("A Layby", 66),
            Self.place("R&R", 75),
            Self.place("R&R further", 110),
        ], frontOffset: 60_000, reasons: [.toilet, .fuel], speed: Self.speed)
        // "A Layby" is tagged services with a pump: the name rule makes it a lay-by, 15 min further.
        #expect(Self.names(rows) == ["R&R", "A Layby", "Toilets only"])
        #expect(rows[2].why == "toilets, no fuel")
    }

    @Test func aFuelRequestUsesTheAskersRangeWhenGiven() {
        let candidates = [Self.place("R&R", 55)]
        #expect(RequestPlaces.rank(candidates, frontOffset: 0, reasons: [.fuel], speed: Self.speed).count == 1)
        #expect(RequestPlaces.rank(candidates, frontOffset: 0, reasons: [.fuel], speed: Self.speed, fuelRange: 30_000).isEmpty)
    }

    @Test func whereAndWhyUseTheCanvasWordsAndNeverZero() {
        #expect(RequestPlaces.requestWhere(18_000, 720) == "18 km ahead · about 12 min")
        #expect(RequestPlaces.requestWhere(300, 10) == "1 km ahead · about 1 min")
        #expect(RequestPlaces.requestWhy(Self.place("A", 1), [.rest]) == "parking")
        let noFood = Self.place("B", 1, facilities: [.fuel, .toilets])
        #expect(RequestPlaces.requestWhy(noFood, [.food, .toilet]) == "toilets, no food")
    }

    @Test func aPlaceLessThan500mAheadOfTheFrontIsLeftOut() {
        let rows = RequestPlaces.rank(
            [Self.place("Too close", 60.4), Self.place("Fine", 60.6)], frontOffset: 60_000, reasons: [.toilet], speed: Self.speed)
        #expect(Self.names(rows) == ["Fine"])
    }

    @Test func noCandidatesOrNoReasonsGiveAnEmptyList() {
        #expect(RequestPlaces.rank([], frontOffset: 0, reasons: [.fuel], speed: Self.speed).isEmpty)
        #expect(RequestPlaces.rank([Self.place("R&R", 10)], frontOffset: 0, reasons: [], speed: Self.speed).isEmpty)
    }

    @Test func atMostThreeAreListed() {
        let many = (1...6).map { Self.place("R&R \($0)", Double($0) * 3) }
        #expect(RequestPlaces.rank(many, frontOffset: 0, reasons: [.fuel], speed: Self.speed).count == 3)
    }

    @Test func requestTypesMapToNeeds() {
        #expect(RequestNeed(.stopFuel) == .fuel && RequestNeed(.stopToilet) == .toilet)
        #expect(RequestNeed(.stopFood) == .food && RequestNeed(.stopRest) == .rest)
        #expect(RequestNeed(.pothole) == nil)
    }

    @Test func rowsReadAsTheCardShowsThem() {
        #expect(RequestPlaces.display("toilets, no fuel") == "Toilets, no fuel")
        #expect(RequestPlaces.display("parking") == "Parking")
        let unnamed = PlaceAlong(
            id: "n1", kind: .fuel, name: nil, coordinate: .init(latitude: 3, longitude: 101), ring: nil,
            facilities: [.fuel], brands: [], offset: 0, distance: 0, side: .left, carriageway: nil, ours: true,
            entrance: .init(latitude: 3, longitude: 101), slipEntrance: false, routeOffset: 0)
        #expect(RequestPlaces.name(unnamed) == "Petrol station")
        #expect(RequestPlaces.name(Self.place("", 1, kind: .restArea)) == "Lay-by")
        #expect(RequestPlaces.name(Self.place("", 1)) == "R&R")
    }

    @Test func paceIsTheFrontsSpeedWhileMovingElseThePlanOrNinetyKmh() {
        #expect(RequestFront(offset: 0, speed: 30, plannedSpeed: 20).pace == 30)
        #expect(RequestFront(offset: 0, speed: 0, plannedSpeed: 20).pace == 20)
        #expect(RequestFront(offset: 0, speed: nil, plannedSpeed: nil).pace == 25)
    }

    // MARK: The real drive

    @Test func northboundJustSouthOfTapahAToiletRequestListsTapahFirstAndNothingFromTheOtherSide() throws {
        let (line, _) = PlacesKLIpohTests.drive("kl-ipoh-north")
        let rows = PlacesKLIpohTests.along(line)
        let tapah = try #require(rows.first { $0.ours && $0.kind == .services && $0.name?.contains("Tapah") == true })
        let opposite = Set(rows.filter { !$0.ours }.map(\.id))
        let list = RequestPlaces.list(
            reasons: [.toilet], front: RequestFront(offset: tapah.routeOffset - 5_000, speed: 25, plannedSpeed: nil), route: line)
        #expect(list.first?.id == tapah.id)
        #expect(list.first?.whereText.hasPrefix("5 km ahead") == true)
        #expect(list.allSatisfy { !opposite.contains($0.id) })
        #expect(list.count <= 3)
    }

    @Test func twoReasonsCoverBothBeforeNearness() throws {
        let near = Self.place("Toilets only near", 10, facilities: [.toilets])
        let list = RequestPlaces.rank(
            [near, Self.place("R&R further", 15)], frontOffset: 0, reasons: [.toilet, .fuel], speed: Self.speed)
        #expect(Self.names(list) == ["R&R further", "Toilets only near"])
    }

    @Test func alongOverTheWholeRouteTakesFractionsOfASecond() {
        let (line, _) = PlacesKLIpohTests.drive("kl-ipoh-north")
        let start = ContinuousClock.now
        let list = RequestPlaces.list(reasons: [.fuel], front: RequestFront(offset: 20_000, speed: 25, plannedSpeed: nil), route: line)
        let took = ContinuousClock.now - start
        print("D4 request list KL-Ipoh: \(list.count) rows in \(took)")
        #expect(took < .seconds(2))
    }

    // MARK: The model behind the card

    @MainActor @Test func theModelListsPlacesFromTheContextAndNothingWithoutAFront() async throws {
        let (line, _) = PlacesKLIpohTests.drive("kl-ipoh-north")
        let model = StopPlacesModel()
        let withFront = StopContext(
            tripId: "t", userId: "u", carId: "c", isOrganizer: false, snapshot: { nil }, mainRoute: line,
            front: { RequestFront(offset: 20_000, speed: 25, plannedSpeed: nil) })
        await model.refresh(reasons: [.fuel], context: withFront)
        #expect(!model.places.isEmpty)
        let without = StopContext(tripId: "t", userId: "u", carId: "c", isOrganizer: false, snapshot: { nil }, mainRoute: line)
        await model.refresh(reasons: [.fuel], context: without)
        #expect(model.places.isEmpty)
    }

    @MainActor @Test func aDemoListStaysPut() async {
        let model = StopPlacesModel()
        model.showForDemo(StopPlacesDemo.three)
        let context = StopContext(tripId: "t", userId: "u", carId: "c", isOrganizer: false, snapshot: { nil }, mainRoute: nil)
        await model.refresh(reasons: [.fuel], context: context)
        #expect(model.places.count == 3)
    }
}
