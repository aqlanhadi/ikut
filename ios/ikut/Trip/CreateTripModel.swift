import CoreLocation
import MapKit
import Observation
import SwiftUI

/// State for Where to?: destination search from the current location, then create the trip (or,
/// from the lobby, change its destination) with the picked place.
@Observable @MainActor
final class CreateTripModel {
    var query = ""
    /// Suggestions for what is typed, until a query is searched.
    private(set) var suggestions: [SearchSuggestion] = []
    /// A query's matches, once searched (`showingResults`).
    private(set) var results: [DestinationResult] = []
    private(set) var showingResults = false
    private(set) var isSearching = false
    /// True once a search has taken over 0.3 s, so a quick answer never flashes a spinner.
    private(set) var spinnerVisible = false
    /// The suggestion being turned into a place; its row shows a spinner.
    private(set) var resolving: SearchSuggestion.ID?
    /// The result being turned into a trip; its row shows a spinner.
    private(set) var working: DestinationResult.ID?
    var errorMessage: String?
    /// Last known fix, for the FROM line and straight-line distances.
    private(set) var origin: CLLocationCoordinate2D?
    private(set) var originName: String?

    /// The route a stop would be added to: results then read how far along it they are ("62 km", "40 min along").
    var along: AlongRoute?

    static let searchMessage = "Couldn’t search. Check your signal and try again."
    static let spinnerDelay: Duration = .milliseconds(300)

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var source: SuggestionSource?
    @ObservationIgnored private let makeSource: @MainActor () -> SuggestionSource
    @ObservationIgnored private let places: PlaceSearching
    /// Builds the route from the phone to a place (MapKit); a test swaps it.
    @ObservationIgnored private let buildRoute: @MainActor (CLLocationCoordinate2D) async throws -> BuiltRoute
    /// The text a query search ran for, so setting the field to it does not go back to suggestions.
    @ObservationIgnored private var searchedText = ""

    /// Names the spot when the field holds coordinates or a maps link.
    @ObservationIgnored let pinNamer: PinNamer
    @ObservationIgnored let geocoder: ReverseGeocoding
    /// How long the field is quiet before a typed coordinate is looked up.
    @ObservationIgnored var pinDelay: Duration = .milliseconds(400)

    init(
        suggestions: (@MainActor () -> SuggestionSource)? = nil, places: PlaceSearching = MapKitPlaceSearch(),
        geocoder: ReverseGeocoding = CLReverseGeocoder(),
        route: @escaping @MainActor (CLLocationCoordinate2D) async throws -> BuiltRoute = { try await RouteBuilder.buildRoute(to: $0) }
    ) {
        buildRoute = route
        makeSource = suggestions ?? { MapKitSuggestionSource() }
        self.places = places
        self.geocoder = geocoder
        pinNamer = PinNamer(geocoder: geocoder)
    }

    /// The "Dropped pin" row: set while the field holds coordinates or a maps link, in place of suggestions.
    var droppedPin: DestinationResult? { pastedPin ? pinNamer.place : nil }
    private(set) var pastedPin = false

    /// Whether the list under the field has anything to show: a search under way, suggestions or a query's results.
    /// One typed character shows none.
    var showsList: Bool { pastedPin || showingResults || isSearching || !suggestions.isEmpty }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isWorking: Bool { working != nil }

    /// Near the phone, else around the trip's route, else Malaysia.
    var searchRegion: MKCoordinateRegion {
        SearchRegion.choose(location: origin, route: along?.line.coordinates ?? [])
    }

    func locate() async {
        guard origin == nil, let here = CLLocationManager().location?.coordinate else { return }
        origin = here
        originName = await RouteBuilder.placeName(at: here)
    }

    /// The field changed: suggestions for the new text, or back to nothing when it is short.
    func queryChanged() {
        let text = trimmedQuery
        if showingResults, text == searchedText { return }
        cancelSearch()
        errorMessage = nil
        showingResults = false
        results = []
        let source = source ?? makeSource()
        self.source = source
        source.onUpdate = { [weak self] query, outcome in self?.receive(query: query, outcome) }
        if let spot = CoordinateParser.parse(text) {
            pastedPin = true
            suggestions = []
            isSearching = false
            source.stop()
            if pinNamer.coordinate?.latitude != spot.latitude || pinNamer.coordinate?.longitude != spot.longitude {
                pinNamer.start(spot, after: pinDelay)
            }
            return
        }
        if pastedPin {
            pastedPin = false
            pinNamer.clear()
        }
        guard text.count >= 2 else {
            suggestions = []
            isSearching = false
            source.stop()
            return
        }
        beginSearching()
        source.update(query: text, region: searchRegion)
    }

    /// MapKit's answer for `query`; one for an older query than the field now holds is dropped.
    func receive(query answered: String, _ outcome: Result<[SearchSuggestion], Error>) {
        guard !pastedPin, !showingResults, answered.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuery,
              trimmedQuery.count >= 2 else { return }
        switch outcome {
        case .success(let found):
            suggestions = SearchSuggestion.rows(found, for: trimmedQuery)
        case .failure:
            suggestions = SearchSuggestion.rows([], for: trimmedQuery)
            errorMessage = Self.searchMessage
        }
        endSearching()
    }

    /// The keyboard's Search key: every match for the text.
    func submit() {
        guard trimmedQuery.count >= 2, !pastedPin else { return }
        runSearch(trimmedQuery)
    }

    /// Lists every match for `text` near the search region (a "Search petrol station" row, or the Search key).
    func runSearch(_ text: String) {
        cancelSearch()
        source?.stop()
        errorMessage = nil
        searchedText = text
        if query != text { query = text }
        showingResults = true
        suggestions = []
        results = []
        beginSearching()
        let region = searchRegion
        searchTask = Task {
            do {
                let found = try await places.search(query: text, region: region)
                guard !Task.isCancelled else { return }
                results = along?.sorted(found) ?? found
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = Self.searchMessage
            }
            endSearching()
        }
    }

    /// A tapped place suggestion as a place; nil (with a message) when it cannot be found.
    func resolve(_ suggestion: SearchSuggestion) async -> DestinationResult? {
        guard resolving == nil else { return nil }
        resolving = suggestion.id
        errorMessage = nil
        defer { resolving = nil }
        do {
            if let place = try await places.resolve(suggestion) { return place }
            errorMessage = "Couldn’t find that place. Try another."
        } catch {
            errorMessage = Self.searchMessage
        }
        return nil
    }

    private func cancelSearch() {
        searchTask?.cancel()
        spinnerTask?.cancel()
        spinnerVisible = false
    }

    private func beginSearching() {
        isSearching = true
        spinnerTask = Task {
            try? await Task.sleep(for: Self.spinnerDelay)
            guard !Task.isCancelled else { return }
            spinnerVisible = true
        }
    }

    private func endSearching() {
        isSearching = false
        spinnerTask?.cancel()
        spinnerVisible = false
    }

    /// "≈205 km" as the crow flies from here; nil without a fix.
    func distanceText(_ result: DestinationResult) -> String? {
        guard let origin else { return nil }
        let meters = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: result.coordinate.latitude, longitude: result.coordinate.longitude))
        return "≈\(RouteFormat.distance(meters))"
    }

    /// How far along the route a result is, from where it falls on the line: "62 km" when it is on the route,
    /// "≈65 km" when the road only passes near it, and "40 min along" of the drive.
    func alongText(_ result: DestinationResult) -> (distance: String, time: String?)? {
        along?.text(for: result.coordinate)
    }

    /// `alongText`, with "Off the route" for a place far from the line.
    func alongRowText(_ result: DestinationResult) -> (distance: String, time: String?)? {
        along?.rowText(for: result.coordinate)
    }

    /// Builds the route to `result` and nothing else: the preview before a trip is made. Nil (with a message) on failure.
    func preview(_ result: DestinationResult) async -> BuiltRoute? {
        guard working == nil else { return nil }
        working = result.id
        errorMessage = nil
        defer { working = nil }
        do {
            return try await buildRoute(result.coordinate)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Builds the route to `result`, then runs `finish` with it. Returns false (with a message) on failure.
    func use(_ result: DestinationResult, finish: (BuiltRoute) async throws -> Void) async -> Bool {
        guard let route = await preview(result) else { return false }
        working = result.id
        defer { working = nil }
        do {
            try await finish(route)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Like `use`, for a trip that has planned stops: the route goes through them to the new destination.
    func use(
        _ result: DestinationResult, through stops: [StopDraft],
        finish: (BuiltRoute, [StopDraft]) async throws -> Void
    ) async -> Bool {
        guard working == nil else { return false }
        working = result.id
        errorMessage = nil
        defer { working = nil }
        do {
            let built = try await StopPlanner.build(items: stops, destination: result.coordinate, fallbackStart: nil,
                snapOnDirectRoute: true)
            try await finish(built.route, built.items)
            return true
        } catch let failure as LegFailure {
            errorMessage = failure.reason.localizedDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Mid-trip (D25 4d): `rebuild` builds the route from where the organizer is now and writes it.
    func use(_ result: DestinationResult, rebuild: (DestinationResult) async throws -> Void) async -> Bool {
        guard working == nil else { return false }
        working = result.id
        errorMessage = nil
        defer { working = nil }
        do {
            try await rebuild(result)
            return true
        } catch {
            errorMessage = Self.rebuildMessage(error)
            return false
        }
    }

    static let rebuildFallback = "Couldn’t change the route. Check your signal and try again."

    /// What the search says when a mid-trip rebuild did not work: Maps' own reasons in plain words, anything else
    /// (MapKit's or Firestore's text, a refusal) one plain line.
    static func rebuildMessage(_ error: Error) -> String {
        switch (error as? LegFailure)?.reason ?? (error as? RouteError) {
        case .failed, nil: rebuildFallback
        case let reason?: reason.localizedDescription
        }
    }

    #if DEBUG
    /// Shows `results` for `query`, searched from `originName`, without searching or locating.
    func showForDemo(query: String, results: [DestinationResult], origin: CLLocationCoordinate2D, originName: String) {
        self.query = query
        self.results = results
        showingResults = true
        self.origin = origin
        self.originName = originName
    }

    /// Shows the "Dropped pin" row for `query`, named `found`.
    func showPinForDemo(query: String, found: GeocodedName?, origin: CLLocationCoordinate2D, originName: String) {
        self.query = query
        pastedPin = true
        pinNamer.setForDemo(CoordinateParser.parse(query), found)
        self.origin = origin
        self.originName = originName
    }

    /// Shows `suggestions` for `query`, as while typing.
    func showSuggestionsForDemo(query: String, suggestions: [SearchSuggestion], origin: CLLocationCoordinate2D, originName: String) {
        self.query = query
        self.suggestions = SearchSuggestion.rows(suggestions, for: query)
        self.origin = origin
        self.originName = originName
    }
    #endif
}

/// The trip's route as a search sees it when adding a stop: the line and how long it takes to drive.
struct AlongRoute {
    var line: RouteLine
    /// Seconds for the whole route; nil until MapKit answered.
    var seconds: Double?

    /// A result closer than this to the route counts as on it.
    static let onRouteDistance: CLLocationDistance = 300

    init(coordinates: [CLLocationCoordinate2D], seconds: Double?) {
        line = RouteLine(coordinates)
        self.seconds = seconds
    }

    func text(for coordinate: CLLocationCoordinate2D) -> (distance: String, time: String?)? {
        guard line.segmentCount > 0, let p = line.project(coordinate) else { return nil }
        let km = StopFormat.along(meters: p.offset)
        let distance = p.distance <= Self.onRouteDistance ? km : "≈\(km)"
        guard let seconds, line.length > 0 else { return (distance, nil) }
        return (distance, "\(StopFormat.length(minutes: max(1, Int((seconds * p.offset / line.length / 60).rounded())))) along")
    }

    /// "62 km along your route"; "near your start" for the first few kilometers.
    func place(for coordinate: CLLocationCoordinate2D) -> String? {
        guard line.segmentCount > 0, let p = line.project(coordinate) else { return nil }
        return p.offset < 3_000 ? "near your start" : "\(StopFormat.along(meters: p.offset)) along your route"
    }
}
