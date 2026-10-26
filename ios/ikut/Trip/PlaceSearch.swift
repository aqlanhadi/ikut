import CoreLocation
import MapKit
import SwiftUI

/// Where a search looks first. Apple Maps style: near the phone, else along the trip's route, else Malaysia.
enum SearchRegion {
    /// Malaysia, peninsula and Borneo.
    static let malaysia = MKCoordinateRegion(
        center: .init(latitude: 4.2, longitude: 102.2), span: .init(latitudeDelta: 8, longitudeDelta: 12))
    /// About 110 km each way around the phone.
    static let nearYouSpan = 2.0

    static func choose(location: CLLocationCoordinate2D?, route: [CLLocationCoordinate2D] = []) -> MKCoordinateRegion {
        if let location {
            return MKCoordinateRegion(
                center: location, span: .init(latitudeDelta: nearYouSpan, longitudeDelta: nearYouSpan))
        }
        guard let first = route.first else { return malaysia }
        var south = first.latitude, north = first.latitude, west = first.longitude, east = first.longitude
        for point in route {
            south = min(south, point.latitude)
            north = max(north, point.latitude)
            west = min(west, point.longitude)
            east = max(east, point.longitude)
        }
        return MKCoordinateRegion(
            center: .init(latitude: (south + north) / 2, longitude: (west + east) / 2),
            span: .init(latitudeDelta: max(0.3, (north - south) * 1.3), longitudeDelta: max(0.3, (east - west) * 1.3)))
    }
}

/// One line of "as you type": a place (name, area) or a query ("Search petrol station").
struct SearchSuggestion: Identifiable, Equatable {
    /// Apple's own subtitle on a query completion, matched as MapKit writes it (not our words, so not sentence case).
    static let queryMarker = "Search Nearby"
    static let queryPrefix = "Search "

    var title: String
    var subtitle: String
    /// Where the typed text falls in `title` (UTF-16 ranges, as MapKit gives them).
    var highlights: [NSRange]
    var isQuery: Bool
    /// What a tap resolves; nil for the "Search …" row made here and in tests.
    var completion: MKLocalSearchCompletion?

    /// Where the row sits in its list, so two completions with the same name and area (two "Petronas" nearby) are
    /// still two rows, each with its own spinner. Set by `rows(_:for:)`.
    var position = 0

    var id: String { "\(position)|\(isQuery ? "q" : "p")|\(title)|\(subtitle)" }

    init(title: String, subtitle: String, highlights: [NSRange], completion: MKLocalSearchCompletion? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.highlights = highlights
        self.completion = completion
        // A completion with no subtitle is a query as far as MapKit's own query rows go, so a place with no area
        // becomes a "Search" row; and on a phone not set to English MapKit's query subtitle is localized, so a query
        // reads as a place. Both still land somewhere sensible: a Search row lists every match, and a place row picks
        // the first match for the name.
        isQuery = subtitle.isEmpty || subtitle == Self.queryMarker
    }

    init(_ completion: MKLocalSearchCompletion) {
        self.init(
            title: completion.title, subtitle: completion.subtitle,
            highlights: completion.titleHighlightRanges.map(\.rangeValue), completion: completion)
    }

    /// A query row for text the person typed.
    static func query(_ text: String) -> SearchSuggestion {
        SearchSuggestion(title: text, subtitle: "", highlights: [])
    }

    /// What the row reads: "Search petrol station" for a query, the place's name otherwise.
    var shownTitle: String { isQuery ? Self.queryPrefix + title : title }
    var shownHighlights: [NSRange] {
        isQuery ? highlights.map { NSRange(location: $0.location + Self.queryPrefix.utf16.count, length: $0.length) } : highlights
    }
    /// The area under a place; queries have none.
    var shownSubtitle: String { isQuery ? "" : subtitle }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.subtitle == rhs.subtitle && lhs.highlights == rhs.highlights
    }

    /// The suggestions for `text`, with a "Search text" row at the foot when MapKit gave no query row of its own, so
    /// a list of every match is always one tap away.
    static func rows(_ suggestions: [SearchSuggestion], for text: String) -> [SearchSuggestion] {
        var all = suggestions
        if !text.isEmpty, !all.contains(where: \.isQuery) { all.append(.query(text)) }
        return all.enumerated().map { index, row in
            var row = row
            row.position = index
            return row
        }
    }
}

enum HighlightedText {
    /// `title` with the ranges in bold.
    static func attributed(_ title: String, _ ranges: [NSRange]) -> AttributedString {
        var text = AttributedString(title)
        for range in ranges {
            guard let found = Range(range, in: title), let target = Range(found, in: text) else { continue }
            text[target].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}

/// Suggestions as you type. Behind a protocol so tests feed their own.
@MainActor
protocol SuggestionSource: AnyObject {
    /// Called with the query the suggestions answer.
    var onUpdate: ((_ query: String, _ outcome: Result<[SearchSuggestion], Error>) -> Void)? { get set }
    func update(query: String, region: MKCoordinateRegion)
    func stop()
}

@MainActor
final class MapKitSuggestionSource: NSObject, SuggestionSource, MKLocalSearchCompleterDelegate {
    var onUpdate: ((String, Result<[SearchSuggestion], Error>) -> Void)?
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    func update(query: String, region: MKCoordinateRegion) {
        completer.region = region
        completer.queryFragment = query
    }

    func stop() {
        completer.cancel()
        completer.queryFragment = ""
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        nonisolated(unsafe) let completer = completer
        MainActor.assumeIsolated {
            onUpdate?(completer.queryFragment, .success(completer.results.map(SearchSuggestion.init)))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        nonisolated(unsafe) let completer = completer
        MainActor.assumeIsolated { onUpdate?(completer.queryFragment, .failure(error)) }
    }
}

/// A search over a region, and the resolving of a tapped suggestion into a place.
@MainActor
protocol PlaceSearching {
    func search(query: String, region: MKCoordinateRegion) async throws -> [DestinationResult]
    func resolve(_ suggestion: SearchSuggestion) async throws -> DestinationResult?
}

struct MapKitPlaceSearch: PlaceSearching {
    func search(query: String, region: MKCoordinateRegion) async throws -> [DestinationResult] {
        try await RouteBuilder.searchDestinations(query: query, region: region)
    }

    func resolve(_ suggestion: SearchSuggestion) async throws -> DestinationResult? {
        guard let completion = suggestion.completion else { return nil }
        let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        return response.mapItems.lazy.compactMap(RouteBuilder.destination).first
    }
}

extension AlongRoute {
    /// A result farther than this from the line is off the route.
    static let offRouteDistance: CLLocationDistance = 5_000

    /// The line under a result in Add a stop: how far along ("62 km", "40 min along"), or "Off the route" with how
    /// far off the line it is.
    func rowText(for coordinate: CLLocationCoordinate2D) -> (distance: String, time: String?)? {
        guard line.segmentCount > 0, let p = line.project(coordinate) else { return nil }
        if p.distance > Self.offRouteDistance { return ("Off the route", "\(StopFormat.along(meters: p.distance)) off") }
        return text(for: coordinate)
    }

    /// "62 km along" for the label on the map, "Off the route" when the spot is far from the line; nil without a route.
    func pinLine(for coordinate: CLLocationCoordinate2D) -> String? {
        guard let row = rowText(for: coordinate) else { return nil }
        return row.distance == "Off the route" ? row.distance : "\(row.distance) along"
    }

    /// Along the route first, nearest the start first; the ones off the route after, nearest the line first.
    func sorted(_ results: [DestinationResult]) -> [DestinationResult] {
        guard line.segmentCount > 0 else { return results }
        let keyed = results.map { ($0, line.project($0.coordinate)) }
        let on = keyed.filter { ($0.1?.distance ?? .infinity) <= Self.offRouteDistance }
            .sorted { ($0.1?.offset ?? 0) < ($1.1?.offset ?? 0) }
        let off = keyed.filter { ($0.1?.distance ?? .infinity) > Self.offRouteDistance }
            .sorted { ($0.1?.distance ?? 0) < ($1.1?.distance ?? 0) }
        return (on + off).map(\.0)
    }
}

/// The results list of every place a destination or a stop is searched (Where to?, Change destination, Add a stop):
/// suggestions while typing, then a query's many results. What differs is passed in.
struct PlaceSearchResults: View {
    enum Distance {
        /// "≈205 km" as the crow flies from the phone.
        case fromYou
        /// "62 km" and "40 min along" the trip's route.
        case alongRoute
    }

    var model: CreateTripModel
    var distance: Distance
    /// A result's second line with the kind in front ("Petrol station · Perak"), as Add a stop shows it.
    var showsKind = false
    var workingLabel = "Creating trip"
    /// What a tap on a place does with it.
    var onPick: (DestinationResult) -> Void

    @State private var choosingOnMap = false
    @Environment(\.inPanelSheet) private var inSheet

    private var busy: Bool { model.isWorking || model.resolving != nil }
    private var hasRows: Bool { model.pastedPin || model.showingResults || model.isSearching || !model.suggestions.isEmpty }

    var body: some View {
        if hasRows { CardHeader(model.pastedPin ? "Dropped pin" : model.showingResults ? "Results" : "Suggestions") }
        VStack(spacing: 0) {
            if let pin = model.droppedPin {
                resultRow(pin, isPin: true)
            } else if model.showingResults {
                resultRows
            } else {
                suggestionRows
            }
            if hasRows { RowDivider() }
            PlaceResultRow(action: "Choose on map", symbol: "map.fill", color: .blue, disabled: busy, action: { choosingOnMap = true }) {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .scrollTargetLayout()
        .tileOrCard(inSheet)
        .padding(.top, hasRows ? 0 : Spacing.m)
        .fullScreenCover(isPresented: $choosingOnMap) {
            MapPickView(origin: model.origin, along: model.along, geocoder: model.geocoder) { place in
                choosingOnMap = false
                onPick(place)
            }
        }
        if distance == .alongRoute, model.along != nil, model.showingResults, !model.results.isEmpty {
            InlineNote("Distances are along your route.").padding(.top, Spacing.s)
        }
    }

    @ViewBuilder private var resultRows: some View {
        if model.results.isEmpty {
            if model.isSearching {
                if model.spinnerVisible {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 58).accessibilityLabel("Searching")
                } else {
                    Color.clear.frame(height: 58)
                }
            } else if model.errorMessage == nil {
                Text("No places match “\(model.trimmedQuery)”. Try a town name.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.section)
            }
        }
        // One view per result, so a scroll position can name it (Where to? follows the list with its camera).
        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
            VStack(spacing: 0) {
                if index > 0 { RowDivider() }
                resultRow(result)
            }
            .id(result.id)
        }
    }

    @ViewBuilder private var suggestionRows: some View {
        if model.suggestions.isEmpty, model.isSearching {
            if model.spinnerVisible {
                ProgressView().frame(maxWidth: .infinity, minHeight: 58).accessibilityLabel("Searching")
            } else {
                Color.clear.frame(height: 58)
            }
        }
        ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, suggestion in
            if index > 0 { RowDivider() }
            PlaceResultRow(suggestion: suggestion, disabled: busy) {
                if suggestion.isQuery {
                    model.runSearch(suggestion.title)
                } else {
                    Task { if let place = await model.resolve(suggestion) { onPick(place) } }
                }
            } trailing: {
                if model.resolving == suggestion.id { ProgressView().accessibilityLabel("Finding the place") }
            }
        }
    }

    @ViewBuilder private func resultRow(_ result: DestinationResult, isPin: Bool = false) -> some View {
        if isPin {
            PlaceResultRow(pin: result, disabled: busy, action: { onPick(result) }) { trailing(result) }
        } else {
            PlaceResultRow(result: shownResult(result), disabled: busy, action: { onPick(result) }) { trailing(result) }
        }
    }

    private func shownResult(_ result: DestinationResult) -> DestinationResult {
        var shown = result
        if showsKind {
            shown.subtitle = [PlaceKind.word(for: result), result.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return shown
    }

    @ViewBuilder private func trailing(_ result: DestinationResult) -> some View {
        if model.working == result.id {
            ProgressView().accessibilityLabel(workingLabel)
        } else if distance == .alongRoute, let along = model.alongRowText(result) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(along.distance)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                if let time = along.time { Text(time).font(.caption).foregroundStyle(.secondary) }
            }
        } else if let text = model.distanceText(result) {
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

private extension View {
    /// Grouped rows: the sheet's own tile on the convoy-style glass sheet, the grouped card on a plain screen.
    @ViewBuilder func tileOrCard(_ inSheet: Bool) -> some View {
        if inSheet { surfaceTile() } else { ikutCard() }
    }
}
