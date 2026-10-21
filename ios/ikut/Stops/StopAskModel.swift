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
            if sending != .sending { sending = .failed("Waiting for your location. Try again in a moment.") }
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
            sending = .failed("Could not reach the convoy. Try again in a moment.")
            return false
        }
    }
}
