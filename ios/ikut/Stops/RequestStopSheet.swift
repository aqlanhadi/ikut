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

    /// Back to the reason tiles.
    func clearReason() {
        searchTask?.cancel()
        reason = nil
        picked = nil
        candidates = []
        search = .idle
        sending = .idle
    }

    /// Search done (with or without places) and nothing in flight: the request can go by itself.
    var isReadyToAutoSend: Bool {
        existing == nil && canSend && (search == .loaded || search == .failed)
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
            // A new request goes with the nearest place unless the sender picks another.
            if existing == nil { picked = found.first?.id }
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

/// "Pit stop" (RequestStop.dc.html): one tap on a reason finds the nearest place ahead and sends
/// the request by itself after a short countdown, unless the sender changes or cancels it.
/// With `suggestingFor`, the same sheet instead lists places to suggest for an open request.
struct RequestStopSheet: View {
    @State private var model: RequestStopModel
    var onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// When the countdown sends the request; nil while it isn't counting.
    @State private var sendAt: Date?

    static let autoSendDelay: TimeInterval = 5

    init(
        context: StopContext, suggestingFor existing: StopRequestState? = nil, service: any StopServing = StopService(),
        searcher: any PlaceSearching = MapKitPlaceSearcher(), onSent: @escaping () -> Void = {}
    ) {
        _model = State(initialValue: RequestStopModel(context: context, existing: existing, service: service, searcher: searcher))
        self.onSent = onSent
    }

    var body: some View {
        if model.existing == nil {
            oneTap
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
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
    }

    // MARK: One tap (new request)

    private var oneTap: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let reason = model.reason {
                confirm(reason)
            } else {
                tiles
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onChange(of: model.isReadyToAutoSend, initial: true) { _, ready in
            sendAt = ready ? Date().addingTimeInterval(Self.autoSendDelay) : nil
        }
        .onChange(of: model.picked) {
            // Picking another place restarts the countdown so there's time to see it.
            if model.isReadyToAutoSend { sendAt = Date().addingTimeInterval(Self.autoSendDelay) }
        }
        .task(id: sendAt) {
            guard let sendAt else { return }
            try? await Task.sleep(for: .seconds(max(0, sendAt.timeIntervalSinceNow)))
            guard !Task.isCancelled, self.sendAt == sendAt else { return }
            send()
        }
    }

    private var tiles: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pit stop").font(.title2.bold())
                    Text("One tap. We’ll find the next good place.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                closeButton
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(StopReason.all) { reason in
                    Button { model.choose(reason) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: reason.symbol)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 52, height: 52)
                                .background(Color.orange, in: Circle())
                            Text(reason.label).font(.headline).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 112)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func confirm(_ reason: StopReason) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Self.title(for: reason)).font(.title2.bold())
                Spacer()
                Button("Change") {
                    sendAt = nil
                    model.clearReason()
                }
                .font(.body.weight(.semibold))
                .disabled(model.sending == .sending)
            }

            chosenPlace(reason)

            if model.candidates.count > 1 {
                Menu {
                    Picker("Place", selection: $model.picked) {
                        ForEach(model.candidates) { candidate in
                            Text("\(candidate.name) · \(ConvoyFormat.distance(candidate.distanceAhead))")
                                .tag(Optional(candidate.id))
                        }
                    }
                } label: {
                    Label("Other places ahead", systemImage: "list.bullet")
                        .font(.subheadline.weight(.semibold))
                }
            }

            Spacer(minLength: 0)

            if case .failed(let message) = model.sending {
                Text(message).font(.footnote).foregroundStyle(.red)
            } else {
                Text("Sends by itself. No need to touch anything else.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            countdownButton
            Button("Cancel", role: .cancel) { dismiss() }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    @ViewBuilder
    private func chosenPlace(_ reason: StopReason) -> some View {
        HStack(spacing: 12) {
            Image(systemName: reason.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Color.orange, in: Circle())
            if model.search == .idle || model.search == .loading {
                Text("Finding the next good place…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                ProgressView()
            } else if let chosen = model.chosen {
                VStack(alignment: .leading, spacing: 1) {
                    Text(chosen.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(chosen.whereText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(chosen.costText).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("No place found ahead").font(.body.weight(.semibold))
                    Text("The lead car chooses where.").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Accent pill that fills up as the countdown runs; tapping sends straight away.
    private var countdownButton: some View {
        Button(action: send) {
            TimelineView(.animation(minimumInterval: 0.1, paused: sendAt == nil)) { context in
                let left = sendAt.map { max(0, $0.timeIntervalSince(context.date)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.accentColor)
                    if let left {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: proxy.size.width * (1 - left / Self.autoSendDelay))
                        }
                    }
                    Group {
                        if model.sending == .sending {
                            ProgressView().tint(.white)
                        } else if let left {
                            Text("Sending to convoy in \(Int(left.rounded(.up)))s")
                        } else {
                            Text("Send now")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(height: 50)
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.canSend)
        .accessibilityLabel("Send now")
        .accessibilityHint("Sends by itself in a few seconds")
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
        }
        .accessibilityLabel("Close")
    }

    private func send() {
        sendAt = nil
        Task {
            if await model.send() {
                onSent()
                dismiss()
            }
        }
    }

    /// "Need gas", "Toilet break", "Food stop", "Quick rest".
    static func title(for reason: StopReason) -> String {
        switch reason.type {
        case .stopFuel: "Need gas"
        case .stopToilet: "Toilet break"
        case .stopFood: "Food stop"
        default: "Quick rest"
        }
    }

    // MARK: Suggest another place (existing request)

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
