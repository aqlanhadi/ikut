import FirebaseFirestore
import Foundation

/// `trips/{tripId}/events/{eventId}/votes/{carId}`: one vote per car.
struct StopVote: Codable, Sendable, Equatable, Identifiable {
    /// The car id.
    @DocumentID var id: String?
    var userId: String
    var agree: Bool
    @ServerTimestamp var at: Date?
    /// Another place this car would rather stop at. The requesting car proposes its place this way.
    var suggestion: StopPlace?
}

/// Who may do what to a stop request. Mirrors the rules; the rules are what actually enforce it.
enum StopPermissions {
    /// The lead car's tracker or the organizer pins the place.
    static func canPin(isLeadTracker: Bool, isOrganizer: Bool) -> Bool { isLeadTracker || isOrganizer }

    /// The author, the lead car's tracker or the organizer resolves the request.
    static func canResolve(isAuthor: Bool, isLeadTracker: Bool, isOrganizer: Bool) -> Bool {
        isAuthor || isLeadTracker || isOrganizer
    }
}

/// What the stop card shows: the request, a row per car, and what this viewer may do.
struct StopRequestState: Equatable, Sendable {
    enum VoteStatus: Equatable, Sendable {
        case agreed
        case waiting
        /// Voted no and named another place.
        case suggested
    }

    struct Row: Equatable, Sendable, Identifiable {
        var carId: String
        var number: Int?
        var colorHex: String
        /// "Wyna’s X70", with " (you)" on the viewer's own car.
        var name: String
        var isMine: Bool
        var status: VoteStatus
        var suggestion: StopPlace?
        var id: String { carId }
    }

    var eventId: String
    var type: EventType
    var requesterCarId: String
    var requesterNumber: Int?
    /// The requesting car's owner, e.g. "Wyna".
    var requesterName: String
    var askedAt: Date?
    var rows: [Row]
    /// The pinned stop, once the lead car or organizer has pinned one.
    var place: StopPlace?
    /// The requesting car's own suggestion, shown until a place is pinned.
    var proposal: StopPlace?
    /// What the other cars suggested instead.
    var alternatives: [Row]
    var viewerAgrees: Bool
    var canPin: Bool
    var canResolve: Bool
    /// The viewer's meters along the main route; nil while unknown.
    var viewerOffset: Double?
    var isResolved: Bool

    var agreedCount: Int { rows.filter { $0.status == .agreed }.count }

    /// "Wyna Needs Gas".
    var title: String { "\(requesterName) \(Self.need(for: type))" }

    /// "Car 2 · asked 1 min ago".
    func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let requesterNumber { parts.append("Car \(requesterNumber)") }
        if let askedAt {
            let age = max(0, now.timeIntervalSince(askedAt))
            parts.append(age < 60 ? "asked just now" : "asked \(ConvoyFormat.duration(age)) ago")
        }
        return parts.joined(separator: " · ")
    }

    /// The place to show: the pin, else the requester's proposal.
    var shownPlace: StopPlace? { place ?? proposal }

    /// Meters from the viewer to `shownPlace`; negative once passed. Nil without both.
    var distanceToPlace: Double? {
        guard let viewerOffset, let shownPlace else { return nil }
        return shownPlace.routeOffset - viewerOffset
    }

    /// "18 km ahead", "850 m ahead", or "Passed".
    var distanceText: String? {
        guard let d = distanceToPlace else { return nil }
        return d < 0 ? "Passed" : "\(ConvoyFormat.distance(d)) ahead"
    }

    /// "About 12 min", at `StopLogic.assumedSpeed`.
    var etaText: String? {
        guard let d = distanceToPlace, d >= 0 else { return nil }
        return "About \(ConvoyFormat.duration(d / StopLogic.assumedSpeed))"
    }

    static func need(for type: EventType) -> String {
        switch type {
        case .stopFuel: "Needs Gas"
        case .stopFood: "Needs Food"
        case .stopToilet: "Needs a Toilet Break"
        default: "Needs a Rest"
        }
    }
}

enum StopLogic {
    /// Meters per second (90 km/h) used for the ETA to a stop, as in the design's "18 km · 12 min".
    static let assumedSpeed: Double = 25

    /// The owner's first name from a car name: "Wyna’s X70" and "Wyna's car" both give "Wyna".
    static func ownerName(fromCarName name: String) -> String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker), range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }

    /// Latest unresolved stop request, or nil.
    static func activeStop(in events: [TripEvent], now: Date) -> TripEvent? {
        events
            .filter { $0.category == .stopRequest && $0.id != nil && ($0.expiresAt.map { $0 > now } ?? true) }
            .max { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
    }

    /// Cars that get a row: tracked cars, cars that voted, and the requesting car.
    /// The requesting car counts as agreed. Cars sort by badge number, then name.
    static func tally(
        event: TripEvent, votes: [StopVote], cars: [Car], myUserId: String, myCarId: String,
        isOrganizer: Bool, viewerOffset: Double?, now: Date
    ) -> StopRequestState? {
        guard let eventId = event.id else { return nil }
        let voteByCar = Dictionary(votes.compactMap { v in v.id.map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        let voters = cars.filter { car in
            guard let id = car.id else { return false }
            return car.trackerUserId != nil || voteByCar[id] != nil || id == event.carId
        }
        .sorted { a, b in
            let na = a.number ?? Int.max
            let nb = b.number ?? Int.max
            return na != nb ? na < nb : a.name < b.name
        }
        let rows: [StopRequestState.Row] = voters.map { car in
            let id = car.id ?? ""
            let vote = voteByCar[id]
            let status: StopRequestState.VoteStatus
            if id == event.carId || vote?.agree == true {
                status = .agreed
            } else if vote?.suggestion != nil {
                status = .suggested
            } else {
                status = .waiting
            }
            return StopRequestState.Row(
                carId: id, number: car.number, colorHex: car.color,
                name: id == myCarId ? "\(car.name) (you)" : car.name, isMine: id == myCarId,
                status: status, suggestion: vote?.suggestion)
        }
        let requester = cars.first { $0.id == event.carId }
        let me = cars.first { $0.id == myCarId }
        let isLeadTracker = me.map { $0.isLead && $0.trackerUserId == myUserId } ?? false
        return StopRequestState(
            eventId: eventId, type: event.type, requesterCarId: event.carId,
            requesterNumber: requester?.number,
            requesterName: requester.map { ownerName(fromCarName: $0.name) } ?? "A car",
            askedAt: event.createdAt, rows: rows, place: event.place,
            proposal: voteByCar[event.carId]?.suggestion,
            alternatives: rows.filter { $0.suggestion != nil && $0.carId != event.carId },
            viewerAgrees: rows.first { $0.isMine }?.status == .agreed,
            canPin: StopPermissions.canPin(isLeadTracker: isLeadTracker, isOrganizer: isOrganizer),
            canResolve: StopPermissions.canResolve(
                isAuthor: event.authorId == myUserId, isLeadTracker: isLeadTracker, isOrganizer: isOrganizer),
            viewerOffset: viewerOffset, isResolved: event.expiresAt.map { $0 <= now } ?? false)
    }
}

/// Whether the stop card is open or folded into a chip, and what it last saw.
struct StopCardMemory: Equatable, Sendable {
    /// The request plus the pinned place: a change re-opens the card once.
    var key: String
    var viewerAgreed: Bool
    var collapsed: Bool
}

extension StopLogic {
    /// "stop1|R&R Tapah": changes with a new request or a newly pinned place.
    static func cardKey(_ state: StopRequestState) -> String {
        "\(state.eventId)|\(state.place?.name ?? "")"
    }

    /// The viewer's car asked for this stop.
    static func viewerIsRequester(_ state: StopRequestState) -> Bool {
        state.rows.contains { $0.isMine && $0.carId == state.requesterCarId }
    }

    /// Collapse rules. A new request opens, except the requester's own (or one already agreed to);
    /// a newly pinned place re-opens it once; agreeing folds it; otherwise the viewer's choice stands.
    static func nextCardMemory(_ memory: StopCardMemory?, state: StopRequestState) -> StopCardMemory {
        let key = cardKey(state)
        guard let memory, memory.key.hasPrefix(state.eventId + "|") else {
            return StopCardMemory(
                key: key, viewerAgreed: state.viewerAgrees,
                collapsed: viewerIsRequester(state) || state.viewerAgrees)
        }
        var next = memory
        next.key = key
        next.viewerAgreed = state.viewerAgrees
        if memory.key != key {
            next.collapsed = false
        } else if !memory.viewerAgreed && state.viewerAgrees {
            next.collapsed = true
        }
        return next
    }

    /// "Me" for the viewer's car, else the owner's first name.
    static func shortName(_ row: StopRequestState.Row) -> String {
        row.isMine ? "Me" : ownerName(fromCarName: row.name)
    }

    /// "Aisha’s Myvi, agreed"; the viewer's car adds ", you".
    static func voterAccessibilityLabel(_ row: StopRequestState.Row) -> String {
        let name = row.name.replacingOccurrences(of: " (you)", with: "")
        let status = switch row.status {
        case .agreed: "agreed"
        case .waiting: "waiting"
        case .suggested: "suggested another stop"
        }
        return "\(row.isMine ? "\(name), you" : name), \(status)"
    }

    /// "Fuel stop · R&R Demo · 3/4" for the folded card.
    static func chipText(_ state: StopRequestState) -> String {
        let kind = switch state.type {
        case .stopFuel: "Fuel stop"
        case .stopFood: "Food stop"
        case .stopToilet: "Toilet stop"
        default: "Rest stop"
        }
        return [kind, state.shownPlace?.name, "\(state.agreedCount)/\(state.rows.count)"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
