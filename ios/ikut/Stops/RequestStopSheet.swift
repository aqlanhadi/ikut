import CoreLocation
import Observation
import SwiftUI

/// One reason chip on the request sheet.
struct StopReason: Identifiable, Equatable, Sendable {
    let type: EventType
    let label: String
    let symbol: String
    var id: String { type.rawValue }

    /// Fuel, Toilet, Food, Rest, in the design's order. (The design's "Detour" has no event type.)
    static let all: [StopReason] = [
        StopReason(type: .stopFuel, label: "Fuel", symbol: "fuelpump.fill"),
        StopReason(type: .stopToilet, label: "Toilet", symbol: "toilet.fill"),
        StopReason(type: .stopFood, label: "Food", symbol: "fork.knife"),
        StopReason(type: .stopRest, label: "Rest", symbol: "cup.and.saucer.fill"),
    ]
}

/// State behind `RequestStopSheet`: the chosen type, its suggestions, and the send.
@MainActor @Observable
final class RequestStopModel {
    enum Search: Equatable {
        case idle
        case loading
        case loaded
        case failed
    }

    enum Sending: Equatable {
        case idle
        case sending
        case failed(String)
    }

    let context: StopContext
    /// Set when suggesting another place for an open request instead of making a new one.
    let existing: StopRequestState?
    private let service: any StopServing
    private let searcher: any PlaceSearching

    private(set) var reason: StopReason?
    private(set) var candidates: [StopCandidate] = []
    private(set) var search: Search = .idle
    private(set) var sending: Sending = .idle
    var picked: StopCandidate.ID?
    private var searchTask: Task<Void, Never>?

    init(
        context: StopContext, existing: StopRequestState? = nil, service: any StopServing = StopService(),
        searcher: any PlaceSearching = MapKitPlaceSearcher()
    ) {
        self.context = context
        self.existing = existing
        self.service = service
        self.searcher = searcher
        if let existing { choose(StopReason.all.first { $0.type == existing.type } ?? StopReason.all[3]) }
    }

    var chosen: StopCandidate? { candidates.first { $0.id == picked } }

    /// A reason is chosen and a place is picked, or the search came up empty so the request goes
    /// without a place.
    var canSend: Bool {
        guard reason != nil, sending != .sending else { return false }
        if existing != nil { return chosen != nil }
        return chosen != nil || search == .loaded && candidates.isEmpty || search == .failed
    }

    var sendLabel: String {
        if let existing { return existing.canPin ? "Pin this stop" : "Suggest this stop" }
        return "Send to convoy"
    }

    func choose(_ reason: StopReason) {
        self.reason = reason
        picked = nil
        candidates = []
        searchTask?.cancel()
        searchTask = Task { await runSearch(for: reason) }
    }

    private func runSearch(for reason: StopReason) async {
        search = .loading
        let snapshot = context.snapshot()
        let route = context.mainRoute ?? snapshot?.route
        guard let route, let snapshot else {
            search = .failed
            return
        }
        let mine = EventService.routeOffset(for: snapshot.coordinate, route: route, previousOffset: snapshot.previousOffset)
        let from = max(mine, context.frontOffset() ?? 0)
        do {
            let found = try await StopSuggestions.suggest(
                type: reason.type, route: route, fromOffset: from, searcher: searcher)
            guard !Task.isCancelled, self.reason == reason else { return }
            candidates = found
            search = .loaded
        } catch {
            guard !Task.isCancelled, self.reason == reason else { return }
            search = .failed
        }
    }

    /// Sends the request (or the suggestion). Returns true on success.
    func send() async -> Bool {
        guard let reason, canSend, let snapshot = context.snapshot() else {
            if sending != .sending { sending = .failed("Waiting for your location.") }
            return false
        }
        sending = .sending
        do {
            if let existing {
                guard let place = chosen?.place else { sending = .idle; return false }
                try await service.suggest(place: place, eventId: existing.eventId, canPin: existing.canPin, context: context)
            } else {
                _ = try await service.request(
                    type: reason.type, place: chosen?.place, context: context, snapshot: snapshot)
            }
            sending = .idle
            return true
        } catch {
            sending = .failed("Couldn't send. Check your connection and try again.")
            return false
        }
    }
}

/// "Ask for a stop": pick a reason, see places ahead on the route, send it to the convoy.
/// With `suggestingFor`, the same sheet picks another place for an open request.
struct RequestStopSheet: View {
    @State private var model: RequestStopModel
    var onSent: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(
        context: StopContext, suggestingFor existing: StopRequestState? = nil, service: any StopServing = StopService(),
        searcher: any PlaceSearching = MapKitPlaceSearcher(), onSent: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: RequestStopModel(context: context, existing: existing, service: service, searcher: searcher))
        self.onSent = onSent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.existing == nil { reasonChips }
                content
                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.existing == nil ? "Ask for a stop" : "Suggest another stop").font(.title2.bold())
                Text(model.existing == nil
                    ? "The convoy votes, then the lead car pins it."
                    : "Pick a place ahead. The lead car pins the final stop.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel("Close")
        }
    }

    private var reasonChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StopReason.all) { reason in
                    let selected = model.reason == reason
                    Button { model.choose(reason) } label: {
                        Label(reason.label, systemImage: reason.symbol)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(selected ? Color.primary : Color(.secondarySystemBackground), in: Capsule())
                            .foregroundStyle(selected ? Color(.systemBackground) : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if model.reason == nil {
            note("Pick a reason to see places along the route.")
        } else {
            switch model.search {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for places ahead…").foregroundStyle(.secondary)
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            case .failed:
                note(model.existing == nil
                    ? "Couldn't find places along the route. You can still ask; the lead car chooses where."
                    : "Couldn't find places along the route.")
            case .loaded where model.candidates.isEmpty:
                note(model.existing == nil
                    ? "No places found 15 to 25 km ahead. You can still ask; the lead car chooses where."
                    : "No places found ahead.")
            case .loaded:
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ahead on the route")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(model.candidates) { candidate in candidateRow(candidate) }
                }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func candidateRow(_ candidate: StopCandidate) -> some View {
        let selected = model.picked == candidate.id
        return Button { model.picked = candidate.id } label: {
            HStack(spacing: 12) {
                Image(systemName: model.reason?.symbol ?? "mappin")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(candidate.whereText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(candidate.costText).font(.footnote.weight(.semibold)).foregroundStyle(.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name), \(candidate.whereText), \(candidate.costText)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var sendButton: some View {
        VStack(spacing: 8) {
            if case .failed(let message) = model.sending {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task {
                    if await model.send() {
                        onSent()
                        dismiss()
                    }
                }
            } label: {
                Group {
                    if model.sending == .sending { ProgressView().tint(Color(.systemBackground)) } else { Text(model.sendLabel) }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(model.canSend ? Color.primary : Color(.systemGray5), in: Capsule())
                .foregroundStyle(model.canSend ? Color(.systemBackground) : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!model.canSend)
        }
    }
}
