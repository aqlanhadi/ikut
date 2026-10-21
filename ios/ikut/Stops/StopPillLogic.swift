import Foundation

/// The one slim pill at the top of the map for a stop (discovery page, section 2 and rule 5).
/// Pure: `StopPillMemory` remembers when each thing was first seen and `StopPillPlanner.current`
/// says what to show now.
enum StopPill: Equatable, Sendable {
    /// Another car's request: one big button, one word.
    case question(eventId: String, symbol: String, title: String, detail: String, button: String, isPin: Bool)
    /// "You said yes · 3 of 4 agreed", after a tap.
    case confirm(symbol: String, title: String, detail: String)
    /// "Stop in 12 min", dark, once a place is pinned.
    case pinned(symbol: String, title: String, detail: String)
    /// The asker's own phone: "Asked the convoy", never a question.
    case asked(title: String, detail: String)

    var id: String {
        switch self {
        case .question(let eventId, _, _, _, _, _): "question-\(eventId)"
        case .confirm(_, let title, _): "confirm-\(title)"
        case .pinned(_, let title, _): "pinned-\(title)"
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
    var pinnedSeen: [String: Date] = [:]
    var askedSeen: [String: Date] = [:]
    var confirmation: Confirmation?

    /// Remembers when each request first needed an answer, was first pinned, or was first seen as this
    /// car's own. Call whenever the requests change.
    mutating func observe(_ requests: [StopRequestState], now: Date) {
        for request in requests {
            if StopLogic.needsAnswer(request), questionSeen[request.eventId] == nil {
                questionSeen[request.eventId] = now
            }
            if request.isPinned, pinnedSeen[request.eventId] == nil { pinnedSeen[request.eventId] = now }
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

    /// After a tap on the pill: "You said yes" with how many cars agreed now.
    mutating func noteAnswered(_ request: StopRequestState, answer: StopAnswer, now: Date) {
        let agreed = request.agreedCount + (answer == .yes && request.myAnswer != .yes ? 1 : 0)
        let word = answer == .yes ? "You said yes" : "You said not now"
        confirmation = Confirmation(title: word, detail: "\(agreed) of \(request.rows.count) agreed", at: now)
    }

    /// After the lead car or organizer pinned from the pill: the pinned pill takes over.
    mutating func notePinned(_ request: StopRequestState, now: Date) {
        pinnedSeen[request.eventId] = now
    }
}

enum StopPillPlanner {
    /// Seconds the question stays before it goes quiet and waits on the button (rule 5).
    static let questionWindow: TimeInterval = 20
    /// Seconds a confirmation after a tap stays.
    static let confirmWindow: TimeInterval = 5
    /// Seconds the dark "Stop in 12 min" pill stays before it folds into the button's label.
    static let pinnedWindow: TimeInterval = 8
    /// Seconds "Asked the convoy" stays on the asker's phone.
    static let askedWindow: TimeInterval = 5

    /// The pill to show at `now`, or nil. Order: a confirmation of the tap, then the oldest request
    /// this car has not answered (one at a time, until its 20 seconds are up), then a fresh pin, then
    /// the asker's own confirmation. `requests` are oldest first.
    static func current(requests: [StopRequestState], memory: StopPillMemory, now: Date) -> StopPill? {
        if let c = memory.confirmation, now.timeIntervalSince(c.at) < confirmWindow {
            let symbol = requests.first.map { StopLogic.reasonSymbol($0.type) } ?? "checkmark"
            return .confirm(symbol: symbol, title: c.title, detail: c.detail)
        }
        for request in requests where StopLogic.needsAnswer(request) {
            guard let seen = memory.questionSeen[request.eventId], now.timeIntervalSince(seen) < questionWindow else { continue }
            return .question(
                eventId: request.eventId, symbol: StopLogic.reasonSymbol(request.type), title: request.title,
                detail: StopLogic.placeLine(request), button: request.canPin ? "Pin this stop" : "Yes",
                isPin: request.canPin)
        }
        for request in requests where request.isPinned {
            guard let seen = memory.pinnedSeen[request.eventId], now.timeIntervalSince(seen) < pinnedWindow,
                  let place = request.place else { continue }
            let title = request.viewerMinutes.map { "Stop in \($0) min" } ?? "Stop pinned"
            let by = request.pinnedByName.map { "pinned by \($0)" } ?? "pinned by the organizer"
            return .pinned(symbol: "flag.fill", title: title, detail: "\(place.name) · \(by)")
        }
        for request in requests where StopLogic.viewerIsRequester(request) {
            guard let seen = memory.askedSeen[request.eventId], now.timeIntervalSince(seen) < askedWindow else { continue }
            let waiting = request.rows.filter { $0.status != .agreed }.count
            return .asked(
                title: "Asked the convoy",
                detail: waiting == 0 ? "Everyone agreed" : waiting == 1 ? "Waiting for 1 car" : "Waiting for \(waiting) cars")
        }
        return nil
    }

    /// The next moment the pill's content changes by itself, for a timer; nil when it won't.
    static func nextChange(requests: [StopRequestState], memory: StopPillMemory, now: Date) -> Date? {
        var times: [Date] = []
        if let c = memory.confirmation { times.append(c.at.addingTimeInterval(confirmWindow)) }
        for request in requests {
            if let seen = memory.questionSeen[request.eventId] { times.append(seen.addingTimeInterval(questionWindow)) }
            if let seen = memory.pinnedSeen[request.eventId] { times.append(seen.addingTimeInterval(pinnedWindow)) }
            if let seen = memory.askedSeen[request.eventId] { times.append(seen.addingTimeInterval(askedWindow)) }
        }
        return times.filter { $0 > now }.min()
    }
}
