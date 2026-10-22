import CoreLocation
import FirebaseFirestore
import Foundation

/// The answer a car gives to a stop request. "Skip this one" is a later task.
enum StopAnswer: String, Codable, Sendable, Equatable {
    case yes
    case notNow

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopAnswer(rawValue: raw) ?? .notNow
    }

    /// Old builds only know `agree`, so it is written next to `answer`.
    var agree: Bool { self == .yes }
}

/// `trips/{tripId}/events/{eventId}/votes/{carId}`: one vote per car.
struct StopVote: Codable, Sendable, Equatable, Identifiable {
    /// The car id.
    @DocumentID var id: String?
    /// Who answered for the car.
    var userId: String
    var agree: Bool
    /// Missing on votes from old builds; then `agree` is all there is.
    var answer: StopAnswer?
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

/// Where a car is, as far as the stop screens need it. Taken from the positions the phone already has.
struct StopCarFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Meters along the main route; nil until the car has merged.
    var offset: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// What the stop card shows: the request, a row per car, and what this viewer may do.
struct StopRequestState: Equatable, Sendable {
    enum VoteStatus: Equatable, Sendable {
        case agreed
        case waiting
        /// Said "Not now".
        case notNow
        /// Voted no and named another place.
        case suggested
    }

    /// Once a place is pinned: a car is here (within `StopLogic.hereRadius`) or this many minutes away.
    enum Arrival: Equatable, Sendable {
        case here
        case minutes(Int)
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
        var arrival: Arrival?
        var id: String { carId }

        init(
            carId: String, number: Int?, colorHex: String, name: String, isMine: Bool, status: VoteStatus,
            suggestion: StopPlace?, arrival: Arrival? = nil
        ) {
            self.carId = carId
            self.number = number
            self.colorHex = colorHex
            self.name = name
            self.isMine = isMine
            self.status = status
            self.suggestion = suggestion
            self.arrival = arrival
        }
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
    /// The viewer wrote this request (the rules let only the author cancel it).
    var isAuthor = false
    /// The viewer's car's answer, nil while it has not answered.
    var myAnswer: StopAnswer?
    /// "Aisha": who pinned the place, when a car's tracker is known.
    var pinnedByName: String?
    /// Where the asking car is along the route, for the line the lead sends back.
    var requesterOffset: Double?
    /// Nobody pinned a place within `StopLogic.noAnswerAfter`.
    var isNoAnswer = false

    var agreedCount: Int { rows.filter { $0.status == .agreed }.count }

    var isPinned: Bool { place != nil }

    /// Cars at the pinned place.
    var hereCount: Int { rows.filter { $0.arrival == .here }.count }

    /// The viewer's car is at the pinned place.
    var viewerIsHere: Bool { rows.first { $0.isMine }?.arrival == .here }

    /// "Wyna needs fuel".
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

    /// Whole minutes from the viewer to the place, either way along the route; nil while unknown.
    var viewerMinutes: Int? {
        if case .minutes(let minutes)? = rows.first(where: { $0.isMine })?.arrival { return minutes }
        guard let d = distanceToPlace else { return nil }
        return StopLogic.minutes(forMeters: abs(d))
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

/// Everything the stop screens read: the open requests (oldest first) and, when this car asked and
/// nobody answered, that request.
struct StopBoard: Equatable, Sendable {
    var requests: [StopRequestState] = []
    /// This car's own request that nobody pinned in time, shown as "No answer" so it can ask again.
    var missed: StopRequestState?

    static let empty = StopBoard()

    /// Requests that still need this car's answer.
    var unansweredCount: Int { requests.filter(StopLogic.needsAnswer).count }
}

enum StopLogic {
    /// NEXT STOP on the panel: the first open request that has a pinned place (not just the first request).
    static func nextStop(_ board: StopBoard) -> StopPlace? {
        board.requests.compactMap(\.place).first
    }

    /// Meters per second (90 km/h) used for the ETA to a stop, as in the design's "18 km · 12 min".
    static let assumedSpeed: Double = 25

    /// A request nobody pinned this long after it was asked reads "No answer" (page section 4).
    static let noAnswerAfter: TimeInterval = 10 * 60
    /// A "No answer" request stays on the asker's screen this long after it was asked, so there is
    /// time to see it and ask again.
    static let missedVisibleFor: TimeInterval = 20 * 60
    /// A car within this many meters of the pinned place is "here" (page section 4).
    static let hereRadius: CLLocationDistance = 150

    /// The owner's first name from a car name: "Wyna’s X70" and "Wyna's car" both give "Wyna".
    static func ownerName(fromCarName name: String) -> String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker), range.lowerBound > name.startIndex {
                return String(name[..<range.lowerBound])
            }
        }
        return name
    }

    // MARK: Which requests are open

    /// A stop request that has not been closed or resolved (no `expiresAt` yet, or one in the future).
    static func isOpen(_ event: TripEvent, now: Date) -> Bool {
        event.category == .stopRequest && event.id != nil && event.status != .closed
            && (event.expiresAt.map { $0 > now } ?? true)
    }

    /// Open, still without a pinned place, and asked `noAnswerAfter` ago or longer.
    static func isNoAnswer(_ event: TripEvent, now: Date) -> Bool {
        guard isOpen(event, now: now), event.place == nil, event.status != .pinned,
              let asked = event.createdAt else { return false }
        return now.timeIntervalSince(asked) >= noAnswerAfter
    }

    /// Every open request, oldest first. One that nobody pinned in `noAnswerAfter` is not in it
    /// (it is "No answer", see `missedAsk`). Replaces the single newest `activeStop`, which hid the
    /// older of two requests while it was still open.
    static func openStops(in events: [TripEvent], now: Date) -> [TripEvent] {
        events
            .filter { isOpen($0, now: now) && !isNoAnswer($0, now: now) }
            .sorted { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
    }

    /// Requests the lead car's or organizer's phone closes with `closedReason: noAnswer`.
    static func noAnswerToClose(in events: [TripEvent], now: Date) -> [TripEvent] {
        events.filter { isNoAnswer($0, now: now) }
    }

    /// This car's newest request, if nobody answered it (asked again since: nil).
    static func missedAsk(in events: [TripEvent], myCarId: String, now: Date) -> TripEvent? {
        let mine = events
            .filter { $0.category == .stopRequest && $0.id != nil && $0.carId == myCarId && $0.closedReason != .cancelled }
            .max { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        guard let mine, let asked = mine.createdAt, now.timeIntervalSince(asked) < missedVisibleFor else { return nil }
        return isNoAnswer(mine, now: now) || mine.closedReason == .noAnswer ? mine : nil
    }

    // MARK: Cars

    /// Whole minutes for `meters` at `assumedSpeed`, at least 1.
    static func minutes(forMeters meters: Double) -> Int {
        max(1, Int((meters / assumedSpeed / 60).rounded()))
    }

    /// Here when within `hereRadius` of the place, else the minutes still to drive: along the route
    /// when the car's offset is known, else in a straight line.
    static func arrival(of fix: StopCarFix, to place: StopPlace) -> StopRequestState.Arrival {
        let target = CLLocationCoordinate2D(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        let straight = RouteLine.haversine(fix.coordinate, target)
        if straight <= hereRadius { return .here }
        return .minutes(minutes(forMeters: fix.offset.map { abs(place.routeOffset - $0) } ?? straight))
    }

    /// The lead car's tracker is this user.
    static func isLeadTracker(cars: [Car], myCarId: String, myUserId: String) -> Bool {
        cars.first { $0.id == myCarId }.map { $0.isLead && $0.trackerUserId == myUserId } ?? false
    }

    /// Cars that get a row: tracked cars, cars that voted, and the requesting car.
    /// The requesting car counts as agreed. Cars sort by badge number, then name.
    static func tally(
        event: TripEvent, votes: [StopVote], cars: [Car], myUserId: String, myCarId: String,
        isOrganizer: Bool, viewerOffset: Double?, now: Date, fixes: [String: StopCarFix] = [:]
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
            let vote = voteByCar[id]
            let status: StopRequestState.VoteStatus
            if id == event.carId || vote?.answer == .yes || (vote?.answer == nil && vote?.agree == true) {
                status = .agreed
            } else if vote?.suggestion != nil {
                status = .suggested
            } else if vote?.answer == .notNow {
                status = .notNow
            } else {
                status = .waiting
            }
            let arrival = event.place.flatMap { place in fixes[id].map { arrival(of: $0, to: place) } }
            return StopRequestState.Row(
                carId: id, number: car.number, colorHex: car.color,
                name: id == myCarId ? "\(car.name) (you)" : car.name, isMine: id == myCarId,
                status: status, suggestion: vote?.suggestion, arrival: arrival)
        }
        let requester = cars.first { $0.id == event.carId }
        let isLeadTracker = isLeadTracker(cars: cars, myCarId: myCarId, myUserId: myUserId)
        let pinner = event.place?.pinnedBy.flatMap { uid in cars.first { $0.trackerUserId == uid } }
        let myVote = voteByCar[myCarId]
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
            viewerOffset: viewerOffset, isResolved: event.expiresAt.map { $0 <= now } ?? false,
            isAuthor: event.authorId == myUserId,
            myAnswer: myVote.map { $0.answer ?? ($0.agree ? .yes : .notNow) },
            pinnedByName: pinner.map { ownerName(fromCarName: $0.name) },
            requesterOffset: fixes[event.carId]?.offset,
            isNoAnswer: isNoAnswer(event, now: now) || event.closedReason == .noAnswer)
    }

    // MARK: What each screen reads

    /// The viewer's car is the one that asked.
    static func viewerIsRequester(_ state: StopRequestState) -> Bool {
        state.rows.contains { $0.isMine && $0.carId == state.requesterCarId }
    }

    /// A question for this car: another car's request, no place pinned yet, and nothing answered
    /// (the lead car or organizer answers by pinning).
    static func needsAnswer(_ state: StopRequestState) -> Bool {
        guard !viewerIsRequester(state), !state.isPinned else { return false }
        return state.canPin || state.myAnswer == nil
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

    /// "Fuel · 2 of 4" while deciding, "Fuel · 12 min" once pinned, "Fuel · 3 of 4 here" at the stop.
    static func statusLine(_ state: StopRequestState) -> String {
        let reason = reasonLabel(state.type)
        guard state.isPinned else { return "\(reason) · \(state.agreedCount) of \(state.rows.count)" }
        if state.viewerIsHere { return "\(reason) · \(state.hereCount) of \(state.rows.count) here" }
        if let minutes = state.viewerMinutes { return "\(reason) · \(minutes) min" }
        return "\(reason) · pinned"
    }

    /// What the Pit stop button shows.
    struct ButtonContent: Equatable, Sendable {
        var label: String
        var symbol: String
        /// Requests this car has not answered; 0 hides the badge.
        var badge: Int
        var accessibilityLabel: String
    }

    static func buttonContent(for board: StopBoard) -> ButtonContent {
        let plain = "mappin.and.ellipse"
        let requests = board.requests
        if requests.isEmpty {
            if let missed = board.missed {
                let reason = reasonLabel(missed.type)
                return ButtonContent(
                    label: "\(reason) · No answer", symbol: reasonSymbol(missed.type), badge: 0,
                    accessibilityLabel: "\(reason) stop, nobody answered. Opens it so you can ask again")
            }
            return ButtonContent(label: "Pit stop", symbol: plain, badge: 0, accessibilityLabel: "Pit stop")
        }
        let unanswered = board.unansweredCount
        let tail = unanswered == 0 ? "" : unanswered == 1 ? ", you have not answered" : ", you have \(unanswered) to answer"
        if requests.count > 1 {
            return ButtonContent(
                label: "\(requests.count) stops", symbol: plain, badge: unanswered,
                accessibilityLabel: "\(requests.count) stops open\(tail)")
        }
        let state = requests[0]
        let reason = reasonLabel(state.type)
        let detail: String
        if state.isPinned {
            if state.viewerIsHere {
                detail = "\(state.hereCount) of \(state.rows.count) cars here"
            } else if let minutes = state.viewerMinutes {
                detail = "pinned at \(state.place?.name ?? "a place"), \(minutes) minutes away"
            } else {
                detail = "pinned at \(state.place?.name ?? "a place")"
            }
        } else {
            detail = "\(state.agreedCount) of \(state.rows.count) cars agreed"
        }
        return ButtonContent(
            label: statusLine(state), symbol: reasonSymbol(state.type), badge: unanswered,
            accessibilityLabel: "\(reason) stop, \(detail)\(tail)")
    }

    /// "Petronas R&R Tapah · 18 km · 12 min", or what the lead car does when there is no place yet.
    static func placeLine(_ state: StopRequestState) -> String {
        guard let place = state.shownPlace else { return "The lead car chooses where" }
        var parts = [place.name]
        if let d = state.distanceToPlace {
            parts.append(d < 0 ? "Passed" : ConvoyFormat.distance(d))
            parts.append("\(minutes(forMeters: abs(d))) min")
        }
        return parts.joined(separator: " · ")
    }

    /// "Aisha agreed. Waiting for Hafiz and Daniel", the Deciding step of the asker's timeline.
    static func decidingText(_ state: StopRequestState) -> String {
        let agreed = state.rows.filter { $0.status == .agreed && $0.carId != state.requesterCarId }
        let waiting = state.rows.filter { $0.status != .agreed }
        var parts: [String] = []
        if !agreed.isEmpty { parts.append("\(joined(agreed.map { ownerName(fromCarName: $0.name) })) agreed.") }
        if !waiting.isEmpty {
            parts.append("Waiting for \(joined(waiting.map { $0.name.replacingOccurrences(of: " (you)", with: "") }))")
        }
        return parts.isEmpty ? "Waiting for the other cars" : parts.joined(separator: " ")
    }

    /// "Ali", "Ali and Sara", "Ali, Sara and Daniel".
    static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// What the lead tells the asker after choosing a different place: "Aisha chose Petronas Bidor. 9 min back."
    static func chosenLine(leadName: String, place: StopPlace, state: StopRequestState) -> String {
        let base = "\(leadName) chose \(place.name)."
        guard let from = state.requesterOffset else { return base }
        let delta = place.routeOffset - from
        return "\(base) \(minutes(forMeters: abs(delta))) min \(delta < 0 ? "back" : "ahead")."
    }

    // MARK: Small helpers kept from the old card

    /// "Me" for the viewer's car, else the owner's first name.
    static func shortName(_ row: StopRequestState.Row) -> String {
        row.isMine ? "Me" : ownerName(fromCarName: row.name)
    }

    /// "Aisha’s Myvi, agreed"; the viewer's car adds ", you".
    static func voterAccessibilityLabel(_ row: StopRequestState.Row) -> String {
        let name = row.name.replacingOccurrences(of: " (you)", with: "")
        let status: String
        switch row.arrival {
        case .here?: status = "here"
        case .minutes(let minutes)?: status = "\(minutes) minutes away"
        case nil:
            status = switch row.status {
            case .agreed: "agreed"
            case .waiting: "waiting"
            case .notNow: "said not now"
            case .suggested: "suggested another stop"
            }
        }
        return "\(row.isMine ? "\(name), you" : name), \(status)"
    }
}
