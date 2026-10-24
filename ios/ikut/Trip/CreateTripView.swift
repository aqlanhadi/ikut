import CoreLocation
import MapKit
import Observation
import SwiftUI

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
                        .accessibilityIdentifier("createTripError")
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
        // One title: "Where to?" in the content, so the bar's title stays empty (HIG toolbars).
        .navigationTitle("")
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
