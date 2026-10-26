import CoreLocation
import Observation
import SwiftUI

/// The create flow on Home's map (MapFirst B2 and B3): Where to? search, then New trip with the route drawn.
/// Nothing is written until `create`. Wraps the same `CreateTripModel` the search always used, so Back to the
/// search finds its query and results as they were.
@Observable @MainActor
final class NewTripFlow {
    struct Ready: Equatable {
        var place: DestinationResult
        var route: BuiltRoute
    }

    enum Phase: Equatable {
        case search
        case ready(Ready)
    }

    /// Writes the trip and returns its id.
    typealias Creator = (_ name: String, _ place: DestinationResult, _ route: BuiltRoute) async throws -> String

    let search: CreateTripModel
    private(set) var phase: Phase = .search
    /// The Name field's text; empty until typed.
    var name = ""
    private(set) var isCreating = false
    var createError: String?
    /// The result at the top of the list as it scrolls (its id); nil before the list has scrolled.
    var topResultID: String?

    /// Most pins drawn for one search: the map stays readable, and the list is the rest.
    static let maxPins = 20

    init(search: CreateTripModel = CreateTripModel()) {
        self.search = search
    }

    var ready: Ready? {
        if case .ready(let ready) = phase { return ready }
        return nil
    }

    // MARK: Name

    /// Left empty (or only spaces) the trip is "Trip to <destination>"; otherwise what was typed, trimmed.
    static func tripName(typed: String, destination: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? TripService.defaultTripName(destination: destination) : trimmed
    }

    /// The Name field's placeholder.
    var namePlaceholder: String {
        TripService.defaultTripName(destination: ready?.place.name ?? "")
    }

    // MARK: Pins and camera

    /// The places drawn as pins: the dropped pin, or a searched query's results (the first `maxPins`). Suggestions
    /// while typing are not places yet. On New trip only the destination is drawn.
    var pins: [DestinationResult] {
        if let ready { return [ready.place] }
        if let pin = search.droppedPin { return [pin] }
        guard search.showingResults else { return [] }
        return Array(search.results.prefix(Self.maxPins))
    }

    /// The pin the camera goes to while searching: the result at the top of the list, else the first one.
    var focusTarget: DestinationResult? {
        guard ready == nil else { return nil }
        let shown = pins
        if let id = topResultID, let match = shown.first(where: { $0.id == id }) { return match }
        return shown.first
    }

    // MARK: Steps

    /// A result was tapped: build its route (nothing is written) and show New trip. A route that fails to build
    /// stays on the search, with the message on the search model.
    func pick(_ place: DestinationResult) async {
        guard let route = await search.preview(place) else { return }
        createError = nil
        name = ""
        phase = .ready(Ready(place: place, route: route))
    }

    /// Back to the search, query and results kept.
    func back() {
        phase = .search
        createError = nil
    }

    /// Writes the trip with the route the preview built (no second build). Returns the trip's id, nil with
    /// `createError` set when it could not be written (the sheet stays, so Create trip can be tried again).
    func create(using creator: Creator) async -> String? {
        guard let ready, !isCreating else { return nil }
        isCreating = true
        createError = nil
        defer { isCreating = false }
        do {
            return try await creator(Self.tripName(typed: name, destination: ready.place.name), ready.place, ready.route)
        } catch {
            createError = error.localizedDescription
            return nil
        }
    }

    // MARK: Words

    /// "Perak · 205 km · about 2 h 40 min from you".
    static func detailLine(place: DestinationResult, route: BuiltRoute) -> String {
        let area = place.subtitle.replacingOccurrences(of: ", Malaysia", with: "")
        return [area, RouteFormat.distance(route.distance), "about \(ConvoyFormat.duration(route.travelTime)) from you"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    #if DEBUG
    /// New trip for `place`, as after a pick, without building a route.
    func showReadyForDemo(place: DestinationResult, route: BuiltRoute) {
        phase = .ready(Ready(place: place, route: route))
    }
    #endif
}
