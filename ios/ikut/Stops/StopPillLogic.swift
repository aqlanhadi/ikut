import Foundation

/// The one slim pill at the top of the map for a stop (discovery page, section 2 and rule 5).
/// Pure: `StopPillMemory` remembers when each thing was first seen and `StopPillPlanner.current`
/// says what to show now.
enum StopPill: Equatable, Sendable {
    /// Another car's request: the reason, one line, and one big OK.
    case question(eventId: String, symbol: String, title: String, detail: String)
    /// "You said OK · 3 of 4 OK", after a tap.
    case confirm(symbol: String, title: String, detail: String)
    /// The asker's own phone: "Sent to the convoy", never a question.
    case asked(title: String, detail: String)

    var id: String {
        switch self {
        case .question(let eventId, _, _, _): "question-\(eventId)"
        case .confirm(_, let title, _): "confirm-\(title)"
        case .asked: "asked"
        }
    }
}

struct StopPillMemory: Equatable, Sendable {
    struct Confirmation: Equatable, Sendable {
        var title: String
        var detail: String
        var at: Date
    }

    /// When a question about this request first reached the screen.
    var questionSeen: [String: Date] = [:]
    var askedSeen: [String: Date] = [:]
    var confirmation: Confirmation?

    /// Remembers when each request first needed an OK, or was first seen as this car's own. Call
    /// whenever the requests change.
    mutating func observe(_ requests: [StopRequestState], now: Date) {
        for request in requests {
            if StopLogic.needsAnswer(request), questionSeen[request.eventId] == nil {
                questionSeen[request.eventId] = now
            }
            if StopLogic.viewerIsRequester(request), askedSeen[request.eventId] == nil {
                // An old request of mine that was open when the map appeared is not news.
                if let asked = request.askedAt, now.timeIntervalSince(asked) > StopPillPlanner.askedWindow {
                    askedSeen[request.eventId] = .distantPast
                } else {
                    askedSeen[request.eventId] = now
                }
            }
        }
    }

    /// After a tap on OK (the pill's or the card's): "You said OK" with how many cars said OK now.
    mutating func noteOK(_ request: StopRequestState, now: Date) {
        let count = request.okCount + (request.viewerCarIsOK ? 0 : 1)
        confirmation = Confirmation(title: "You said OK", detail: "\(count) of \(request.rows.count) OK", at: now)
    }
}

enum StopPillPlanner {
    /// Seconds the question stays before it goes quiet and waits on the button (rule 5).
    static let questionWindow: TimeInterval = 20
    /// Seconds a confirmation after a tap stays.
    static let confirmWindow: TimeInterval = 5
    /// Seconds "Sent to the convoy" stays on the asker's phone.
    static let askedWindow: TimeInterval = 5

    /// The pill to show at `now`, or nil. Order: a confirmation of the tap, then the oldest request
    /// this car has not said OK to (one at a time, until its 20 seconds are up), then the asker's own
    /// confirmation. `requests` are oldest first. `distance` gives meters along the route from my car to
    /// a car (positive: ahead), so a request from over 2 km away says how far: "Wyna needs fuel · 40 km behind".
    static func current(
        requests: [StopRequestState], memory: StopPillMemory, now: Date,
        distance: (String) -> Double? = { _ in nil }
    ) -> StopPill? {
        if let c = memory.confirmation, now.timeIntervalSince(c.at) < confirmWindow {
            let symbol = requests.first.map { StopLogic.reasonSymbol($0.type) } ?? Symbol.tick
            return .confirm(symbol: symbol, title: c.title, detail: c.detail)
        }
        for request in requests where StopLogic.needsAnswer(request) {
            guard let seen = memory.questionSeen[request.eventId], now.timeIntervalSince(seen) < questionWindow else { continue }
            return .question(
                eventId: request.eventId, symbol: StopLogic.reasonSymbol(request.type),
                title: request.title(far: distance(request.requesterCarId).flatMap { ConvoyFormat.relativeDistance($0) }),
                detail: request.pillDetail(now: now))
        }
        for request in requests where StopLogic.viewerIsRequester(request) {
            guard let seen = memory.askedSeen[request.eventId], now.timeIntervalSince(seen) < askedWindow else { continue }
            return .asked(title: "Sent to the convoy", detail: StopLogic.waitingText(request))
        }
        return nil
    }

    /// The next moment the pill's content changes by itself, for a timer; nil when it won't.
    static func nextChange(requests: [StopRequestState], memory: StopPillMemory, now: Date) -> Date? {
        var times: [Date] = []
        if let c = memory.confirmation { times.append(c.at.addingTimeInterval(confirmWindow)) }
        for request in requests {
            if let seen = memory.questionSeen[request.eventId] { times.append(seen.addingTimeInterval(questionWindow)) }
            if let seen = memory.askedSeen[request.eventId] { times.append(seen.addingTimeInterval(askedWindow)) }
        }
        return times.filter { $0 > now }.min()
    }
}
