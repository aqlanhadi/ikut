import CoreLocation
import MapKit
import Observation
import SwiftUI

/// State for Where to?: destination search from the current location, then create the trip (or,
/// from the lobby, change its destination) with the picked place.
@Observable @MainActor
final class CreateTripModel {
    var query = ""
    private(set) var results: [DestinationResult] = []
    private(set) var isSearching = false
    /// The result being turned into a trip; its row shows a spinner.
    private(set) var working: DestinationResult.ID?
    var errorMessage: String?
    /// Last known fix, for the FROM line and straight-line distances.
    private(set) var origin: CLLocationCoordinate2D?
    private(set) var originName: String?

    /// The route a stop would be added to: results then read how far along it they are ("62 km", "40 min along").
    var along: AlongRoute?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isWorking: Bool { working != nil }

    func locate() async {
        guard origin == nil, let here = CLLocationManager().location?.coordinate else { return }
        origin = here
        originName = await RouteBuilder.placeName(at: here)
    }

    func queryChanged() {
        searchTask?.cancel()
        errorMessage = nil
        let text = trimmedQuery
        guard text.count >= 2 else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            do {
                let found = try await RouteBuilder.searchDestinations(query: text)
                guard !Task.isCancelled else { return }
                results = Array(found.prefix(8))
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = "Search failed. Check your connection."
            }
            isSearching = false
        }
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

    #if DEBUG
    /// Shows `results` for `query`, searched from `originName`, without searching or locating.
    func showForDemo(query: String, results: [DestinationResult], origin: CLLocationCoordinate2D, originName: String) {
        self.query = query
        self.results = results
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
    var onDone: (String) -> Void

    init(changingTripId: String? = nil, keepingStops: [StopDraft] = [], onDone: @escaping (String) -> Void) {
        self.changingTripId = changingTripId
        self.keepingStops = keepingStops
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

                if !model.trimmedQuery.isEmpty {
                    CardHeader("Results")
                    resultsCard
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

    private var resultsCard: some View {
        VStack(spacing: 0) {
            if model.isSearching && model.results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .accessibilityLabel("Searching")
            } else if model.results.isEmpty {
                Text("No places match “\(model.trimmedQuery)”. Try a town name.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.section)
            }
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { RowDivider() }
                resultRow(result)
            }
        }
        .ikutCard()
    }

    private func resultRow(_ result: DestinationResult) -> some View {
        PlaceResultRow(result: result, disabled: model.isWorking, action: { pick(result) }) {
            if model.working == result.id {
                ProgressView().accessibilityLabel(changingTripId == nil ? "Creating trip" : "Updating trip")
            } else if let distance = model.distanceText(result) {
                Text(distance)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }

    private func pick(_ result: DestinationResult) {
        searchFocused = false
        Task {
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

/// One search result: its kind's icon, name and subtitle, then whatever `trailing` says (a distance, a spinner).
/// Shared by Where to? and the add-a-stop sheet.
struct PlaceResultRow<Trailing: View>: View {
    var result: DestinationResult
    var disabled = false
    var action: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        let kind = PlaceKind(result)
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(kind.color, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.name).foregroundStyle(.primary).lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
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
        .accessibilityLabel([result.name, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
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
