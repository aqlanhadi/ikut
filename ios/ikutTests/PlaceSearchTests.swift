import CoreLocation
import MapKit
import Testing

@testable import ikut

@MainActor
private final class FakeSuggestions: SuggestionSource {
    var onUpdate: ((String, Result<[SearchSuggestion], Error>) -> Void)?
    var asked: [(String, MKCoordinateRegion)] = []
    func update(query: String, region: MKCoordinateRegion) { asked.append((query, region)) }
    func stop() {}
}

@MainActor
private final class FakePlaceSearch: PlaceSearching {
    var searches: [(String, MKCoordinateRegion)] = []
    var found: [DestinationResult] = []
    func search(query: String, region: MKCoordinateRegion) async throws -> [DestinationResult] {
        searches.append((query, region))
        return found
    }
    func resolve(_ suggestion: SearchSuggestion) async throws -> DestinationResult? { nil }
}

private func place(_ name: String, _ lat: Double, _ lon: Double) -> DestinationResult {
    DestinationResult(name: name, subtitle: "", coordinate: .init(latitude: lat, longitude: lon))
}

@MainActor
struct PlaceSearchTests {
    @Test func regionIsThePhoneThenTheRouteThenMalaysia() {
        let here = CLLocationCoordinate2D(latitude: 3.1, longitude: 101.6)
        let route = [CLLocationCoordinate2D(latitude: 3, longitude: 101), CLLocationCoordinate2D(latitude: 5, longitude: 102)]
        let near = SearchRegion.choose(location: here, route: route)
        #expect(near.center.latitude == 3.1 && near.span.latitudeDelta == SearchRegion.nearYouSpan)
        let along = SearchRegion.choose(location: nil, route: route)
        #expect(abs(along.center.latitude - 4) < 1e-9 && abs(along.center.longitude - 101.5) < 1e-9)
        #expect(along.span.latitudeDelta > 2)
        let any = SearchRegion.choose(location: nil, route: [])
        #expect(any.center.latitude == SearchRegion.malaysia.center.latitude && any.span.longitudeDelta == 12)
    }

    @Test func aStaleCompleterAnswerIsDropped() {
        let source = FakeSuggestions()
        let model = CreateTripModel(suggestions: { source }, places: FakePlaceSearch())
        model.query = "pet"
        model.queryChanged()
        model.query = "petr"
        model.queryChanged()
        let old = SearchSuggestion(title: "Petaling", subtitle: "Selangor", highlights: [])
        let new = SearchSuggestion(title: "Petronas", subtitle: "Selangor", highlights: [])
        source.onUpdate?("pet", .success([old]))
        #expect(model.suggestions.isEmpty)
        source.onUpdate?("petr", .success([new]))
        #expect(model.suggestions.first == new)
        source.onUpdate?("pet", .success([old]))
        #expect(model.suggestions.first == new)
        #expect(source.asked.map(\.0) == ["pet", "petr"])
    }

    @Test func completionsBecomeRowsWithBoldMatchesAndAQueryRow() {
        let place = SearchSuggestion(title: "Petronas KLCC", subtitle: "Kuala Lumpur", highlights: [NSRange(location: 0, length: 4)])
        let query = SearchSuggestion(title: "petrol station", subtitle: "Search Nearby", highlights: [NSRange(location: 0, length: 4)])
        #expect(!place.isQuery && query.isQuery)
        #expect(query.shownTitle == "Search petrol station")
        #expect(query.shownHighlights == [NSRange(location: 7, length: 4)])
        #expect(query.shownSubtitle == "")
        let bold = HighlightedText.attributed(place.shownTitle, place.shownHighlights)
        let boldText = bold.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(bold[$0.range].characters) }
        #expect(boldText == ["Petr"])
        // Without a query row of MapKit's own, one is added for the typed text.
        let rows = SearchSuggestion.rows([place], for: "petr")
        #expect(rows.count == 2 && rows[1].isQuery && rows[1].shownTitle == "Search petr")
        #expect(SearchSuggestion.rows([place, query], for: "petr").count == 2)
    }

    @Test func theSearchKeyListsEveryMatchInTheRegion() async throws {
        let places = FakePlaceSearch()
        places.found = [place("A", 3.1, 101.6), place("B", 3.2, 101.7), place("C", 3.3, 101.8)]
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: places)
        model.query = "petrol station"
        model.queryChanged()
        model.submit()
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(places.searches.count == 1 && places.searches[0].0 == "petrol station")
        #expect(places.searches[0].1.center.latitude == SearchRegion.malaysia.center.latitude)
        #expect(model.showingResults && model.results.map(\.name) == ["A", "B", "C"])
        // The field holds the same text: still the results, not back to suggestions.
        model.queryChanged()
        #expect(model.showingResults)
        // Typing more goes back to suggestions.
        model.query = "petrol stations"
        model.queryChanged()
        #expect(!model.showingResults && model.results.isEmpty)
    }

    @Test func resultsShowDistanceFromThePhoneAndAlongTheRoute() {
        let model = CreateTripModel()
        let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
        model.showForDemo(query: "x", results: [], origin: kl, originName: "KL")
        let ipoh = place("Ipoh", 4.5975, 101.0901)
        #expect(model.distanceText(ipoh)?.hasPrefix("≈") == true)
        // A route 100 km north from KL: a place on it is "≈ km along", one far east is off the route.
        let route = (0...100).map { CLLocationCoordinate2D(latitude: 3.139 + Double($0) * 0.009, longitude: 101.687) }
        model.along = AlongRoute(coordinates: route, seconds: 3600)
        let on = place("On", 3.139 + 0.45, 101.687)
        let off = place("Off", 3.139 + 0.45, 102.4)
        #expect(model.alongRowText(on)?.distance.contains("km") == true)
        #expect(model.alongRowText(on)?.distance != "Off the route")
        #expect(model.alongRowText(off)?.distance == "Off the route")
        #expect(model.alongRowText(off)?.time?.hasSuffix(" off") == true)
    }

    @Test func addAStopOrdersResultsAlongTheRouteAndOffRouteLast() async throws {
        let places = FakePlaceSearch()
        let route = (0...100).map { CLLocationCoordinate2D(latitude: 3.139 + Double($0) * 0.009, longitude: 101.687) }
        places.found = [
            place("Far east", 3.5, 102.4), place("Late", 3.139 + 0.8, 101.687),
            place("Early", 3.139 + 0.1, 101.687), place("Mid", 3.139 + 0.4, 101.687),
        ]
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: places)
        model.along = AlongRoute(coordinates: route, seconds: 3600)
        model.query = "petrol"
        model.runSearch("petrol")
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.results.map(\.name) == ["Early", "Mid", "Late", "Far east"])
        // The region for a search with no fix is the route's.
        #expect(abs(places.searches[0].1.center.latitude - 3.589) < 0.01)
    }
}
