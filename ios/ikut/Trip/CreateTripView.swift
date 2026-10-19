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
}

/// Where to? (LocationSearch.dc.html): FROM your location, TO a search field, then results.
/// Picking a result creates the trip and goes to its lobby. With `changingTripId` it instead
/// re-points that trip and calls `onDone` with the same id.
struct CreateTripView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model = CreateTripModel()
    @FocusState private var searchFocused: Bool
    var changingTripId: String?
    var onDone: (String) -> Void

    init(changingTripId: String? = nil, onDone: @escaping (String) -> Void) {
        self.changingTripId = changingTripId
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Where to?")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                    .accessibilityAddTraits(.isHeader)

                fromToCard.padding(.top, 12)

                if let message = model.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .accessibilityLabel("Error: \(message)")
                }

                if !model.trimmedQuery.isEmpty {
                    CardHeader("Results")
                    resultsCard
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
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
            HStack(spacing: 12) {
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
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            .accessibilityElement(children: .combine)

            Divider().padding(.leading, 48)

            HStack(spacing: 12) {
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
            .padding(.leading, 16)
            .padding(.trailing, 10)
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            }
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                if index > 0 { RowDivider() }
                resultRow(result)
            }
        }
        .ikutCard()
    }

    private func resultRow(_ result: DestinationResult) -> some View {
        let kind = PlaceKind(result)
        return Button { pick(result) } label: {
            HStack(spacing: 12) {
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
                if model.working == result.id {
                    ProgressView().accessibilityLabel(changingTripId == nil ? "Creating trip" : "Updating trip")
                } else if let distance = model.distanceText(result) {
                    Text(distance)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isWorking)
        .accessibilityLabel([result.name, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
    }

    private func pick(_ result: DestinationResult) {
        searchFocused = false
        Task {
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

/// Icon and tile color for a search result, after LocationSearch.dc.html: towns red, transit
/// purple, nature green, everything else an orange pin.
private struct PlaceKind {
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
