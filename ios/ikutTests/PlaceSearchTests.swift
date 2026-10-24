import CoreLocation
import MapKit
import Testing

@testable import ikut

@MainActor
private final class FakePlaceSearch: PlaceSearching {
    var searches: [(String, MKCoordinateRegion)] = []
    var found: [DestinationResult] = []
    /// Answers for a query, instead of `found`.
    var foundFor: [String: [DestinationResult]] = [:]
    /// Queries (or "resolve") that wait until `release` is called for them.
    var held: Set<String> = []
    var resolved: DestinationResult?
    var resolveFails = false

    func release(_ key: String) { held.remove(key) }

    private func wait(_ key: String) async {
        while held.contains(key) { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func search(query: String, region: MKCoordinateRegion) async throws -> [DestinationResult] {
        searches.append((query, region))
        await wait(query)
        return foundFor[query] ?? found
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> DestinationResult? {
        await wait("resolve")
        if resolveFails { throw URLError(.notConnectedToInternet) }
        return resolved
    }
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
        let query = SearchSuggestion(title: "petrol station", subtitle: "Search nearby", highlights: [NSRange(location: 0, length: 4)])
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
        await waitUntil(.seconds(1)) { !model.isSearching }
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
        await waitUntil(.seconds(1)) { !model.isSearching }
        #expect(model.results.map(\.name) == ["Early", "Mid", "Late", "Far east"])
        // The region for a search with no fix is the route's.
        #expect(abs(places.searches[0].1.center.latitude - 3.589) < 0.01)
    }

    @Test func twoCompletionsWithTheSameNameAreTwoRows() {
        let petronas = SearchSuggestion(title: "Petronas", subtitle: "Jalan Ipoh", highlights: [])
        let rows = SearchSuggestion.rows([petronas, petronas], for: "petr")
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
    }

    @Test func oneTypedCharacterShowsNoList() {
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: FakePlaceSearch())
        model.query = "p"
        model.queryChanged()
        #expect(!model.showsList)
        model.query = "pe"
        model.queryChanged()
        #expect(model.showsList)
    }

    @Test func tappingAPlaceSuggestionPicksTheResolvedPlace() async throws {
        let places = FakePlaceSearch()
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: places)
        let row = SearchSuggestion(title: "Petronas", subtitle: "Ipoh", highlights: [])
        places.resolved = place("Petronas Ipoh", 4.6, 101.1)
        places.held = ["resolve"]
        let task = Task { await model.resolve(row) }
        await waitUntil(.milliseconds(500)) { model.resolving != nil }
        #expect(model.resolving == row.id)
        // A second tap while one is resolving does nothing.
        #expect(await model.resolve(row) == nil)
        places.release("resolve")
        let picked = await task.value
        #expect(picked?.name == "Petronas Ipoh")
        #expect(model.resolving == nil && model.errorMessage == nil)
    }

    @Test func aSuggestionThatCannotBeFoundSaysSoAndClearsTheSpinner() async {
        let places = FakePlaceSearch()
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: places)
        let row = SearchSuggestion(title: "Petronas", subtitle: "Ipoh", highlights: [])
        #expect(await model.resolve(row) == nil)
        #expect(model.errorMessage == "Couldn’t find that place. Try another.")
        #expect(model.resolving == nil)
        places.resolveFails = true
        #expect(await model.resolve(row) == nil)
        #expect(model.errorMessage == CreateTripModel.searchMessage)
        #expect(model.resolving == nil)
    }

    @Test func anOlderRegionSearchFinishingLastKeepsTheNewerResults() async throws {
        let places = FakePlaceSearch()
        places.foundFor = ["a": [place("From a", 3, 101)], "b": [place("From b", 4, 101)]]
        places.held = ["a", "b"]
        let model = CreateTripModel(suggestions: { FakeSuggestions() }, places: places)
        model.runSearch("a")
        model.runSearch("b")
        places.release("b")
        await waitUntil(.milliseconds(500)) { !model.isSearching }
        #expect(model.results.map(\.name) == ["From b"])
        places.release("a")
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.results.map(\.name) == ["From b"])
        #expect(model.query == "b")
    }
}
