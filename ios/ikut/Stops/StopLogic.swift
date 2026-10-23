import FirebaseFirestore
import Foundation

/// `trips/{tripId}/events/{eventId}/votes/{carId}`: a car's OK. One per car: the document id is the
/// car id, so a second phone in the same car writes the same document.
struct StopVote: Codable, Sendable, Equatable, Identifiable {
    /// The car id.
    @DocumentID var id: String?
    /// Who tapped OK for the car.
    var userId: String
    @ServerTimestamp var at: Date?
}

/// Who may do what to a stop request. Mirrors the rules; the rules are what actually enforce it.
enum StopPermissions {
    /// "We've stopped": the asker, the lead car's tracker or the organizer.
    static func canMarkStopped(isAuthor: Bool, isLeadTracker: Bool, isOrganizer: Bool) -> Bool {
        isAuthor || isLeadTracker || isOrganizer
    }

    /// "Cancel request": the asker only, at any time.
    static func canCancel(isAuthor: Bool) -> Bool { isAuthor }
}

/// What the stop card shows: the request, a row per car, and what this viewer may do.
struct StopRequestState: Equatable, Sendable {
    enum VoteStatus: Equatable, Sendable {
        case ok
        case waiting
    }

    struct Row: Equatable, Sendable, Identifiable {
        var carId: String
        var number: Int?
        var colorHex: String
        /// "Wyna’s X70", with " (you)" on the viewer's own car.
        var name: String
        var isMine: Bool
        var status: VoteStatus
        var id: String { carId }
    }

    var eventId: String
    var type: EventType
    var requesterCarId: String
    var requesterNumber: Int?
    /// The requesting car's owner, e.g. "Wyna".
    var requesterName: String
    var askedAt: Date?
    /// What a passenger typed, trimmed; nil when there was nothing.
    var message: String?
    var rows: [Row]
    /// "We've stopped": the asker, the lead car's tracker or the organizer.
    var canMarkStopped: Bool
    /// The viewer wrote this request (only the author may cancel it).
    var isAuthor = false

    /// Cars that said OK; the asking car counts.
    var okCount: Int { rows.filter { $0.status == .ok }.count }

    /// The viewer's car has said OK (or is the asking car).
    var viewerCarIsOK: Bool { rows.first { $0.isMine }?.status == .ok }

    /// "Wyna needs fuel".
    var title: String { "\(requesterName) \(Self.need(for: type))" }

    /// "Wyna needs fuel · 40 km behind" when the asking car is over 2 km from mine (`far`), else `title`.
    func title(far: String?) -> String { far.map { "\(title) · \($0)" } ?? title }

    /// "Car 2 · asked 1 min ago".
    func subtitle(now: Date) -> String {
        var parts: [String] = []
        if let requesterNumber { parts.append("Car \(requesterNumber)") }
        if let askedAt { parts.append(StopLogic.askedAgo(since: askedAt, now: now)) }
        return parts.joined(separator: " · ")
    }

    /// The line under the title on the pill: the message on one line, else "Car 2 · just now".
    func pillDetail(now: Date) -> String {
        if let message { return StopLogic.oneLine(message) }
        var parts: [String] = []
        if let requesterNumber { parts.append("Car \(requesterNumber)") }
        if let askedAt {
            let age = max(0, now.timeIntervalSince(askedAt))
            parts.append(age < 60 ? "just now" : "\(ConvoyFormat.duration(age)) ago")
        }
        return parts.joined(separator: " · ")
    }

    static func need(for type: EventType) -> String {
        switch type {
        case .stopFuel: "needs fuel"
        case .stopFood: "needs food"
        case .stopToilet: "needs a toilet break"
        default: "needs a rest"
        }
    }
}

/// Everything the stop screens read: the open requests, oldest first.
struct StopBoard: Equatable, Sendable {
    var requests: [StopRequestState] = []

    static let empty = StopBoard()

    /// Requests that still need this car's OK.
    var unansweredCount: Int { requests.filter(StopLogic.needsAnswer).count }
}

enum StopLogic {
    /// The longest a message may be (the rules' limit on `message`).
    static let maxMessageLength = 280

    /// A stop request closes itself this long after it was asked (the rules cap `expiresAt` there).
    static let lifetime: TimeInterval = 30 * 60

    /// The owner's first name from a car name: "Wyna’s X70" and "Wyna's car" both give "Wyna".
    static func ownerName(fromCarName name: String) -> String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker), range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }

    /// A message as it is sent: trimmed, at most 280 characters, nil when empty.
    static func cleanedMessage(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxMessageLength))
    }

    /// Line breaks turned into spaces, for the one line on the pill.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "asked just now", "asked 1 min ago".
    static func askedAgo(since asked: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(asked))
        return age < 60 ? "asked just now" : "asked \(ConvoyFormat.duration(age)) ago"
    }

    // MARK: Which requests are open

    /// A stop request that has not been closed: not marked closed, and `expiresAt` (30 minutes after
    /// it was asked, or now once closed) is still ahead. Nothing writes when the 30 minutes pass.
    /// A document without `expiresAt` closes 30 minutes after it was asked; one with neither (a
    /// write not yet stamped by the server) counts as just asked.
    static func isOpen(_ event: TripEvent, now: Date) -> Bool {
        event.category == .stopRequest && event.id != nil && event.status != .closed
            && ((event.expiresAt ?? event.createdAt.map { $0.addingTimeInterval(lifetime) }).map { $0 > now } ?? true)
    }

    /// Every open request, oldest first.
    static func openStops(in events: [TripEvent], now: Date) -> [TripEvent] {
        events
            .filter { isOpen($0, now: now) }
            .sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
    }

    // MARK: Cars

    /// The lead car's tracker is this user.
    static func isLeadTracker(cars: [Car], myCarId: String, myUserId: String) -> Bool {
        cars.first { $0.id == myCarId }.map { $0.isLead && $0.trackerUserId == myUserId } ?? false
    }

    /// Cars that get a row: tracked cars, cars that said OK, and the requesting car. The requesting
    /// car counts as OK. Cars sort by badge number, then name.
    static func tally(
        event: TripEvent, votes: [StopVote], cars: [Car], myUserId: String, myCarId: String, isOrganizer: Bool
    ) -> StopRequestState? {
        guard let eventId = event.id else { return nil }
        let voteByCar = votes.keyedByID()
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
            return StopRequestState.Row(
                carId: id, number: car.number, colorHex: car.color,
                name: id == myCarId ? "\(car.name) (you)" : car.name, isMine: id == myCarId,
                status: id == event.carId || voteByCar[id] != nil ? .ok : .waiting)
        }
        let requester = cars.first { $0.id == event.carId }
        let isAuthor = event.authorId == myUserId
        return StopRequestState(
            eventId: eventId, type: event.type, requesterCarId: event.carId,
            requesterNumber: requester?.number,
            requesterName: requester.map { ownerName(fromCarName: $0.name) } ?? "A car",
            askedAt: event.createdAt, message: cleanedMessage(event.message), rows: rows,
            canMarkStopped: StopPermissions.canMarkStopped(
                isAuthor: isAuthor,
                isLeadTracker: isLeadTracker(cars: cars, myCarId: myCarId, myUserId: myUserId),
                isOrganizer: isOrganizer),
            isAuthor: isAuthor)
    }

    // MARK: What each screen reads

    /// The viewer's car is the one that asked.
    static func viewerIsRequester(_ state: StopRequestState) -> Bool {
        state.rows.contains { $0.isMine && $0.carId == state.requesterCarId }
    }

    /// A question for this car: another car's request that this car has not said OK to. One OK per
    /// car: once either phone in the car taps, the other no longer gets the question.
    static func needsAnswer(_ state: StopRequestState) -> Bool {
        !viewerIsRequester(state) && !state.viewerCarIsOK
    }

    /// "Fuel", "Food", "Toilet", "Rest": the tile names, and what the Pit stop button says.
    static func reasonLabel(_ type: EventType) -> String {
        switch type {
        case .stopFuel: "Fuel"
        case .stopFood: "Food"
        case .stopToilet: "Toilet"
        default: "Rest"
        }
    }

    /// The icon of the reason, for the button, the pill and the card.
    static func reasonSymbol(_ type: EventType) -> String {
        switch type {
        case .stopFuel: "fuelpump.fill"
        case .stopFood: "fork.knife"
        case .stopToilet: "toilet.fill"
        default: "cup.and.saucer.fill"
        }
    }

    /// "Fuel · 2 of 4 OK".
    static func statusLine(_ state: StopRequestState) -> String {
        "\(reasonLabel(state.type)) · \(state.okCount) of \(state.rows.count) OK"
    }

    /// What the Pit stop button shows.
    struct ButtonContent: Equatable, Sendable {
        var label: String
        var symbol: String
        /// Requests this car has not said OK to; 0 hides the badge.
        var badge: Int
        var accessibilityLabel: String
    }

    static func buttonContent(for board: StopBoard) -> ButtonContent {
        let plain = "mappin.and.ellipse"
        let requests = board.requests
        guard !requests.isEmpty else {
            return ButtonContent(label: "Pit stop", symbol: plain, badge: 0, accessibilityLabel: "Pit stop")
        }
        let unanswered = board.unansweredCount
        let tail = unanswered == 0 ? "" : unanswered == 1 ? ", you have not said OK" : ", you have \(unanswered) to say OK to"
        if requests.count > 1 {
            return ButtonContent(
                label: "\(requests.count) stops", symbol: plain, badge: unanswered,
                accessibilityLabel: "\(requests.count) stops open\(tail)")
        }
        let state = requests[0]
        return ButtonContent(
            label: statusLine(state), symbol: reasonSymbol(state.type), badge: unanswered,
            accessibilityLabel: "\(reasonLabel(state.type)) stop, \(state.okCount) of \(state.rows.count) cars said OK\(tail)")
    }

    /// "Waiting for 3 cars", the asker's pill and card.
    static func waitingText(_ state: StopRequestState) -> String {
        let waiting = state.rows.filter { $0.status != .ok }.count
        return waiting == 0 ? "Everyone said OK" : waiting == 1 ? "Waiting for 1 car" : "Waiting for \(waiting) cars"
    }

    // MARK: Small helpers

    /// "Me" for the viewer's car, else the owner's first name.
    static func shortName(_ row: StopRequestState.Row) -> String {
        row.isMine ? "Me" : ownerName(fromCarName: row.name)
    }

    /// "Aisha’s Myvi, OK"; the viewer's car adds ", you".
    static func voterAccessibilityLabel(_ row: StopRequestState.Row) -> String {
        let name = row.name.replacingOccurrences(of: " (you)", with: "")
        let status = row.status == .ok ? "OK" : "waiting"
        return "\(row.isMine ? "\(name), you" : name), \(status)"
    }
}
