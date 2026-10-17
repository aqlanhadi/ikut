import CoreLocation
import Observation
import SwiftUI

/// State for the create-trip form: name, destination search and the built route.
@Observable @MainActor
final class CreateTripModel {
    var name: String
    var query = ""
    private(set) var results: [DestinationResult] = []
    private(set) var destination: DestinationResult?
    private(set) var route: BuiltRoute?
    private(set) var isSearching = false
    private(set) var isBuildingRoute = false
    private(set) var isCreating = false
    var errorMessage: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var routeTask: Task<Void, Never>?

    init(defaultName: String) {
        name = defaultName
    }

    var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && route != nil && !isCreating
    }

    func queryChanged() {
        searchTask?.cancel()
        errorMessage = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, text != destination?.name else {
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
                results = found
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                errorMessage = "Search failed. Check your connection."
            }
            isSearching = false
        }
    }

    func pick(_ result: DestinationResult) {
        searchTask?.cancel()
        isSearching = false
        results = []
        destination = result
        query = result.name
        buildRoute()
    }

    func buildRoute() {
        guard let destination else { return }
        routeTask?.cancel()
        route = nil
        errorMessage = nil
        isBuildingRoute = true
        routeTask = Task {
            do {
                let built = try await RouteBuilder.buildRoute(to: destination.coordinate)
                guard !Task.isCancelled else { return }
                route = built
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
            isBuildingRoute = false
        }
    }

    func create(organizer: TripOrganizer) async -> String? {
        guard let destination, let route, canCreate else { return nil }
        isCreating = true
        errorMessage = nil
        defer { isCreating = false }
        do {
            let ids = try await TripService.createTrip(
                name: name.trimmingCharacters(in: .whitespaces), destination: destination,
                route: route, organizer: organizer)
            return ids.tripId
        } catch {
            errorMessage = "Couldn't create the trip. \(error.localizedDescription)"
            return nil
        }
    }
}

/// Organizer flow: name the trip, pick a destination, and create it.
struct CreateTripView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model: CreateTripModel
    var onCreated: (String) -> Void

    init(defaultName: String = "", onCreated: @escaping (String) -> Void) {
        _model = State(initialValue: CreateTripModel(defaultName: defaultName))
        self.onCreated = onCreated
    }

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text("Name").frame(width: 64, alignment: .leading)
                        TextField("Trip name", text: $model.name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .disabled(model.isCreating)
                            .accessibilityLabel("Trip name")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    RowDivider()
                    destinationRow
                }
                .ikutCard()
                .padding(.top, 20)

                if model.isSearching || !model.results.isEmpty {
                    resultsCard.padding(.top, 12)
                }

                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(message)")
                        if model.destination != nil, model.route == nil, !model.isBuildingRoute {
                            Button("Try again") { model.buildRoute() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: create) {
                if model.isCreating {
                    ProgressView().tint(.white).accessibilityLabel("Creating trip")
                } else {
                    Text("Create Trip")
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(!model.canCreate || auth.userID == nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.ikutScreen)
        }
        .navigationTitle("New Trip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.name.isEmpty { model.name = TripService.defaultTripName(for: auth.displayName) }
        }
    }

    /// Red pin tile, the destination search field and, once picked, the route summary.
    private var destinationRow: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Search for a place", text: $model.query)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .disabled(model.isCreating)
                    .accessibilityLabel("Destination search")
                    .onChange(of: model.query) { model.queryChanged() }
                routeSummary
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private var routeSummary: some View {
        if model.isBuildingRoute {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Building route…")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if let route = model.route, model.destination != nil {
            Text(RouteFormat.summary(route))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var resultsCard: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityLabel("Searching")
            }
            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                if index > 0 || model.isSearching { RowDivider() }
                Button { model.pick(result) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel([result.name, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
            }
        }
        .ikutCard()
    }

    private func create() {
        guard let uid = auth.userID else { return }
        let organizer = TripOrganizer(id: uid, displayName: auth.displayName ?? "Organizer")
        Task {
            if let tripId = await model.create(organizer: organizer) { onCreated(tripId) }
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
