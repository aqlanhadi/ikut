import CoreLocation
import MapKit
import Testing

@testable import ikut

@MainActor
private final class FakeGeocoder: ReverseGeocoding {
    var answers: [String: GeocodedName?] = [:]
    var held: Set<String> = []
    var asked: [String] = []

    func release(_ key: String) { held.remove(key) }

    func lookup(_ c: CLLocationCoordinate2D) async -> GeocodedName? {
        let key = PinName.coordinates(c)
        asked.append(key)
        while held.contains(key) { try? await Task.sleep(for: .milliseconds(5)) }
        return answers[key] ?? nil
    }
}

@MainActor
private final class QuietSuggestions: SuggestionSource {
    var onUpdate: ((String, Result<[SearchSuggestion], Error>) -> Void)?
    var asked: [String] = []
    func update(query: String, region: MKCoordinateRegion) { asked.append(query) }
    func stop() {}
}

private struct QuietPlaces: PlaceSearching {
    func search(query: String, region: MKCoordinateRegion) async throws -> [DestinationResult] { [] }
    func resolve(_ suggestion: SearchSuggestion) async throws -> DestinationResult? { nil }
}

private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }

@MainActor
struct PlacePinTests {
    private func expectSpot(_ text: String, _ lat: Double, _ lon: Double, sourceLocation: SourceLocation = #_sourceLocation) {
        let found = CoordinateParser.parse(text)
        #expect(found != nil, "\(text)", sourceLocation: sourceLocation)
        #expect(abs((found?.latitude ?? 99) - lat) < 1e-4 && abs((found?.longitude ?? 999) - lon) < 1e-4,
                "\(text) gave \(String(describing: found))", sourceLocation: sourceLocation)
    }

    @Test func decimalCoordinatesWithCommaSpaceAndSigns() {
        expectSpot("3.139, 101.687", 3.139, 101.687)
        expectSpot("3.139,101.687", 3.139, 101.687)
        expectSpot("3.139 101.687", 3.139, 101.687)
        expectSpot("  +3.139 , -101.687 ", 3.139, -101.687)
        expectSpot("-33.8, 151.2", -33.8, 151.2)
        expectSpot("3, 101", 3, 101)
    }

    @Test func degreesMinutesSecondsWithHemispheres() {
        expectSpot("3°08'20\"N 101°41'13\"E", 3 + 8.0 / 60 + 20.0 / 3600, 101 + 41.0 / 60 + 13.0 / 3600)
        expectSpot("3°08′20″N, 101°41′13″E", 3 + 8.0 / 60 + 20.0 / 3600, 101 + 41.0 / 60 + 13.0 / 3600)
        expectSpot("33°52'S 151°12'E", -(33 + 52.0 / 60), 151 + 12.0 / 60)
        expectSpot("101°41'E 3°08'N", 3 + 8.0 / 60, 101 + 41.0 / 60)
        expectSpot("3.139°N 101.687°E", 3.139, 101.687)
        expectSpot("3 N 101 W", 3, -101)
    }

    @Test func googleAndAppleMapsLinks() {
        expectSpot("https://www.google.com/maps/@3.139,101.687,15z", 3.139, 101.687)
        expectSpot("https://www.google.com/maps/place/Tapah/@4.19,101.26,12z/data=!3m1", 4.19, 101.26)
        expectSpot("https://www.google.com/maps?q=3.139,101.687", 3.139, 101.687)
        expectSpot("https://www.google.com/maps/place/X/data=!3d4.2!4d101.25", 4.2, 101.25)
        expectSpot("https://maps.google.com/?ll=3.139,101.687&z=10", 3.139, 101.687)
        expectSpot("https://maps.apple.com/?ll=3.139,101.687&q=Dropped%20Pin", 3.139, 101.687)
        expectSpot("https://maps.apple.com/?q=3.139,101.687", 3.139, 101.687)
    }

    @Test func outOfRangeAndNotCoordinatesAreNotMatches() {
        #expect(CoordinateParser.parse("91.0, 101.687") == nil)
        #expect(CoordinateParser.parse("3.139, 181.0") == nil)
        #expect(CoordinateParser.parse("95°00'N 101°E") == nil)
        #expect(CoordinateParser.parse("3°70'N 101°E") == nil)
        #expect(CoordinateParser.parse("3°N 101°N") == nil)
        #expect(CoordinateParser.parse("https://maps.apple.com/?address=Jalan%20Ampang") == nil)
        #expect(CoordinateParser.parse("https://www.google.com/maps/place/Tapah") == nil)
        #expect(CoordinateParser.parse("https://maps.apple.com/?q=Petronas") == nil)
        for text in ["Jalan 2/3", "Jalan 2", "12 34", "7", "Ipoh", "2 3", "Lot 3, 101", ""] {
            #expect(CoordinateParser.parse(text) == nil, "\(text)")
        }
    }

    @Test func aPastedPinReplacesSuggestionsAndIsNamedByTheGeocode() async throws {
        let geocoder = FakeGeocoder()
        geocoder.answers[PinName.coordinates(c(3.139, 101.687))] = GeocodedName(name: nil, locality: "Tapah")
        geocoder.held = [PinName.coordinates(c(3.139, 101.687))]
        let source = QuietSuggestions()
        let model = CreateTripModel(suggestions: { source }, places: QuietPlaces(), geocoder: geocoder)
        model.query = "3.139, 101.687"
        model.queryChanged()
        #expect(source.asked.isEmpty && model.suggestions.isEmpty && model.showsList)
        // Before the geocode answers the pin is named by its coordinates, never blank.
        #expect(model.droppedPin?.name == "3.139, 101.687" && model.droppedPin?.subtitle == "3.139, 101.687")
        geocoder.release("3.139, 101.687")
        for _ in 0..<100 where model.pinNamer.isNaming { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.droppedPin?.name == "Near Tapah" && model.droppedPin?.subtitle == "3.139, 101.687")
        // Late MapKit suggestions do not bring the list back; text brings suggestions back.
        source.onUpdate?("3.139, 101.687", .success([SearchSuggestion(title: "X", subtitle: "Y", highlights: [])]))
        #expect(model.suggestions.isEmpty)
        model.query = "Tapah"
        model.queryChanged()
        #expect(model.droppedPin == nil && source.asked == ["Tapah"])
    }

    @Test func aPinIsNamedByNameThenNearLocalityThenCoordinates() {
        let spot = c(4.123456, 101.5)
        #expect(PinName.title(GeocodedName(name: "R&R Tapah", locality: "Tapah"), at: spot) == "R&R Tapah")
        #expect(PinName.title(GeocodedName(name: nil, locality: "Tapah"), at: spot) == "Near Tapah")
        #expect(PinName.title(GeocodedName(name: " ", locality: "Tapah"), at: spot) == "Near Tapah")
        #expect(PinName.title(GeocodedName(name: nil, locality: nil), at: spot) == "4.123, 101.500")
        #expect(PinName.title(nil, at: spot) == "4.123, 101.500")
        #expect(PinName.place(nil, at: spot).subtitle == "4.123, 101.500")
    }

    @Test func aStaleReverseGeocodeIsDropped() async throws {
        let geocoder = FakeGeocoder()
        let a = c(3.1, 101.1), b = c(4.2, 102.2)
        geocoder.answers[PinName.coordinates(a)] = GeocodedName(name: "Old place", locality: nil)
        geocoder.answers[PinName.coordinates(b)] = GeocodedName(name: "New place", locality: nil)
        geocoder.held = [PinName.coordinates(a)]
        let namer = PinNamer(geocoder: geocoder)
        let first = Task { await namer.lookup(a) }
        try await Task.sleep(for: .milliseconds(30))
        await namer.lookup(b)
        #expect(namer.place?.name == "New place")
        geocoder.release(PinName.coordinates(a))
        await first.value
        #expect(namer.place?.name == "New place" && namer.place?.coordinate.latitude == 4.2)
    }

    @Test func offlineTheLabelReadsTheCoordinatesAndThePinStillPicks() async {
        let namer = PinNamer(geocoder: FakeGeocoder())
        await namer.lookup(c(3.139, 101.687))
        #expect(namer.place?.name == "3.139, 101.687" && !namer.isNaming)
        #expect(MapPickView.label(namer.place!, along: nil) == "3.139, 101.687")
    }

    @Test func theMapLabelSaysHowFarAlongTheRouteForAStop() {
        let route = (0...100).map { c(3.139 + Double($0) * 0.009, 101.687) }
        let along = AlongRoute(coordinates: route, seconds: 3600)
        let on = PinName.place(GeocodedName(name: nil, locality: "Tapah"), at: c(3.139 + 0.45, 101.687))
        let label = MapPickView.label(on, along: along)
        #expect(label.hasPrefix("Near Tapah · ") && label.hasSuffix(" km along"), "\(label)")
        #expect(label.contains(along.rowText(for: on.coordinate)!.distance))
        let off = PinName.place(GeocodedName(name: nil, locality: "Kuantan"), at: c(3.6, 103.3))
        #expect(MapPickView.label(off, along: along) == "Near Kuantan · Off the route")
        #expect(MapPickView.label(on, along: nil) == "Near Tapah")
    }

    @Test func theMapStartsAtThePhoneThenTheRoute() {
        let here = c(3.1, 101.6)
        #expect(MapPickView.startRegion(origin: here, route: []).center.latitude == 3.1)
        let route = [c(3, 101), c(5, 102)]
        #expect(abs(MapPickView.startRegion(origin: here, route: route).center.latitude - 4) < 1e-9)
        #expect(MapPickView.startRegion(origin: nil, route: []).center.latitude == SearchRegion.malaysia.center.latitude)
    }
}
