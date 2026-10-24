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

    static let searchMessage = "Couldn't search. Check your signal and try again."
    static let spinnerDelay: Duration = .milliseconds(300)

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var spinnerTask: Task<Void, Never>?
    @ObservationIgnored private var source: SuggestionSource?
    @ObservationIgnored private let makeSource: @MainActor () -> SuggestionSource
    @ObservationIgnored private let places: PlaceSearching
    /// The text a query search ran for, so setting the field to it does not go back to suggestions.
    @ObservationIgnored private var searchedText = ""

    /// Names the spot when the field holds coordinates or a maps link.
    @ObservationIgnored let pinNamer: PinNamer
    @ObservationIgnored let geocoder: ReverseGeocoding

    init(
        suggestions: (@MainActor () -> SuggestionSource)? = nil, places: PlaceSearching = MapKitPlaceSearch(),
        geocoder: ReverseGeocoding = CLReverseGeocoder()
    ) {
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
                pinNamer.start(spot)
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
            errorMessage = "Couldn't find that place. Try another."
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

    /// Builds the route to `result`, then runs `finish` with it. Returns false (with a message) on failure.
    func use(_ result: DestinationResult, finish: (BuiltRoute) async throws -> Void) async -> Bool {
        guard working == nil else { return false }
        working = result.id
        errorMessage = nil
        defer { working = nil }
        do {
            let route = try await RouteBuilder.buildRoute(to: result.coordinate)
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
            let built = try await StopPlanner.build(items: stops, destination: result.coordinate, fallbackStart: nil)
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

    static let rebuildFallback = "Couldn't change the route. Check your signal and try again."

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

    /// Shows `suggestions` for `query`, as while typing.
    /// Shows the "Dropped pin" row for `query`, named `found`.
    func showPinForDemo(query: String, found: GeocodedName?, origin: CLLocationCoordinate2D, originName: String) {
        self.query = query
        pastedPin = true
        pinNamer.setForDemo(CoordinateParser.parse(query), found)
        self.origin = origin
        self.originName = originName
    }

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

/// Where to? (LocationSearch.dc.html): FROM your location, TO a search field, then results.
/// Picking a result creates the trip and goes to its lobby. With `changingTripId` it instead
/// re-points that trip and calls `onDone` with the same id.
struct CreateTripView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model = CreateTripModel()
    @FocusState private var searchFocused: Bool
    var changingTripId: String?
    /// The trip's planned stops when changing its destination: the new route goes through them.
    var keepingStops: [StopDraft]
    /// Once the trip has started: the route is rebuilt from where the organizer is (D25 4d) instead.
    var midTrip: ((DestinationResult) async throws -> Void)?
    var onDone: (String) -> Void

    init(
        changingTripId: String? = nil, keepingStops: [StopDraft] = [],
        midTrip: ((DestinationResult) async throws -> Void)? = nil, onDone: @escaping (String) -> Void
    ) {
        self.changingTripId = changingTripId
        self.keepingStops = keepingStops
        self.midTrip = midTrip
        self.onDone = onDone
    }

    init(model: CreateTripModel, changingTripId: String? = nil, onDone: @escaping (String) -> Void) {
        _model = State(initialValue: model)
        self.changingTripId = changingTripId
        keepingStops = []
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Where to?")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, Spacing.xs)
                    .padding(.top, Spacing.xs)
                    .accessibilityAddTraits(.isHeader)

                fromToCard.padding(.top, Spacing.m)

                if let message = model.errorMessage {
                    InlineNote(message, tone: .alert)
                        .padding(.top, Spacing.m)
                        .accessibilityLabel("Error: \(message)")
                }

                if model.showsList || searchFocused {
                    PlaceSearchResults(
                        model: model, distance: .fromYou,
                        workingLabel: changingTripId == nil ? "Creating trip" : "Updating trip", onPick: pick)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.ikutScreen)
        .navigationTitle(changingTripId == nil ? "New Trip" : "Change Destination")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            searchFocused = true
            await model.locate()
        }
    }

    private var fromToCard: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 12, height: 12)
                    .background(Circle().fill(Color.blue.opacity(0.25)).padding(-3))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    StatCaption("From")
                    Text(model.originName.map { "Current location · \($0)" } ?? "Current location")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 50)
            .accessibilityElement(children: .combine)

            Divider().padding(.leading, 48)

            HStack(spacing: Spacing.m) {
                Image(systemName: "mappin")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.red)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    StatCaption("To")
                    TextField("Search a town, place or address", text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .disabled(model.isWorking)
                        .accessibilityLabel("Destination")
                        .onChange(of: model.query) { model.queryChanged() }
                        .onSubmit { model.submit() }
                }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, Spacing.l)
            .padding(.trailing, Spacing.gap)
            .frame(minHeight: 54)
        }
        .ikutCard()
    }

    private func pick(_ result: DestinationResult) {
        searchFocused = false
        Task {
            if let tripId = changingTripId, let midTrip {
                if await model.use(result, rebuild: midTrip) { onDone(tripId) }
                return
            }
            if let tripId = changingTripId, !keepingStops.isEmpty {
                let ok = await model.use(result, through: keepingStops) { route, stops in
                    try await TripService.changeDestination(
                        tripId: tripId, to: result, route: route,
                        stops: stops.enumerated().map { $1.planned(order: $0) })
                }
                if ok { onDone(tripId) }
                return
            }
            if let tripId = changingTripId {
                let ok = await model.use(result) { route in
                    try await TripService.changeDestination(tripId: tripId, to: result, route: route)
                }
                if ok { onDone(tripId) }
                return
            }
            guard let uid = auth.userID else { return }
            let organizer = TripOrganizer(id: uid, displayName: auth.displayName ?? "Organizer")
            var created: String?
            _ = await model.use(result) { route in
                created = try await TripService.createTrip(
                    name: TripService.defaultTripName(destination: result.name), destination: result,
                    route: route, organizer: organizer
                ).tripId
            }
            if let created { onDone(created) }
        }
    }
}

/// One search line: its kind's icon, name (the typed part in bold for a suggestion) and subtitle, then whatever
/// `trailing` says (a distance, a spinner). Shared by Where to?, Change destination and Add a stop.
struct PlaceResultRow<Trailing: View>: View {
    var title: AttributedString
    var subtitle: String
    var symbol: String
    var color: Color
    var label: String
    var disabled = false
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    init(result: DestinationResult, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        let kind = PlaceKind(result)
        title = AttributedString(result.name)
        subtitle = result.subtitle
        (symbol, color) = (kind.symbol, kind.color)
        label = [result.name, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A pasted pin: a pin icon, its name, "Dropped pin" and the coordinates under it.
    init(pin: DestinationResult, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        title = AttributedString(pin.name)
        subtitle = "Dropped pin · \(pin.subtitle)"
        (symbol, color) = ("mappin", .red)
        label = "Dropped pin, \(pin.name), \(pin.subtitle)"
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A plain action row, like "Choose on map".
    init(action title: String, symbol: String, color: Color, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = AttributedString(title)
        subtitle = ""
        (self.symbol, self.color) = (symbol, color)
        label = title
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    /// A suggestion has no category: a pin for a place, a magnifying glass for "Search petrol station".
    init(suggestion: SearchSuggestion, disabled: Bool = false, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        title = HighlightedText.attributed(suggestion.shownTitle, suggestion.shownHighlights)
        subtitle = suggestion.shownSubtitle
        (symbol, color) = suggestion.isQuery ? ("magnifyingglass", .gray) : ("mappin", .orange)
        label = [suggestion.shownTitle, suggestion.shownSubtitle].filter { !$0.isEmpty }.joined(separator: ", ")
        self.disabled = disabled
        self.action = action
        self.trailing = trailing()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(color, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// Icon and tile color for a search result, after LocationSearch.dc.html: towns red, transit
/// purple, nature green, everything else an orange pin.
struct PlaceKind {
    var symbol: String
    var color: Color

    init(_ result: DestinationResult) {
        let category = result.category.map(MKPointOfInterestCategory.init(rawValue:))
        switch category {
        case nil:
            (symbol, color) = ("building.2.fill", .red)
        case .publicTransport?, .airport?:
            (symbol, color) = ("tram.fill", .indigo)
        case .park?, .nationalPark?, .beach?, .campground?:
            (symbol, color) = ("leaf.fill", .green)
        case .gasStation?, .evCharger?:
            (symbol, color) = ("fuelpump.fill", .orange)
        case .restaurant?, .cafe?, .bakery?, .foodMarket?:
            (symbol, color) = ("fork.knife", .orange)
        case .hotel?:
            (symbol, color) = ("bed.double.fill", .purple)
        default:
            (symbol, color) = ("mappin", .orange)
        }
    }
}

#Preview {
    Backend.configure()
    return NavigationStack {
        CreateTripView { _ in }
    }
    .environment(AuthModel())
}

#if DEBUG
#Preview("Results") {
    Backend.configure()
    let model = CreateTripModel()
    model.showForDemo(
        query: "Ipoh",
        results: [
            DestinationResult(name: "Ipoh", subtitle: "Perak, Malaysia", coordinate: .init(latitude: 4.5975, longitude: 101.0901)),
            DestinationResult(
                name: "Petronas Jalan Gopeng", subtitle: "Jalan Gopeng, Ipoh",
                coordinate: .init(latitude: 4.5600, longitude: 101.1100), category: MKPointOfInterestCategory.gasStation.rawValue),
            DestinationResult(
                name: "Restoran Nam Heong", subtitle: "Jalan Bandar Timah, Ipoh",
                coordinate: .init(latitude: 4.5960, longitude: 101.0790), category: MKPointOfInterestCategory.restaurant.rawValue),
            DestinationResult(
                name: "Sultan Azlan Shah Airport", subtitle: "Ipoh",
                coordinate: .init(latitude: 4.5680, longitude: 101.0920), category: MKPointOfInterestCategory.airport.rawValue),
            DestinationResult(
                name: "Kinta Riverfront Hotel", subtitle: "Jalan Lim Bo Seng, Ipoh",
                coordinate: .init(latitude: 4.5940, longitude: 101.0830), category: MKPointOfInterestCategory.hotel.rawValue),
        ],
        origin: .init(latitude: 3.1390, longitude: 101.6869), originName: "Kuala Lumpur")
    return NavigationStack {
        CreateTripView(model: model) { _ in }
    }
    .environment(AuthModel())
}
#endif
