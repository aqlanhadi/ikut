import Foundation

/// The one message under the trip pill (MapBannerSlot.dc.html, decisions #282 a/g and #323): of everything that
/// wants the top of the map, only the most urgent shows. What waits behind comes back by itself when the top one
/// goes, and was already spoken, so nothing is stacked or counted. The one cue is a red dot on the trip pill for an
/// error held behind another message, because an error never times out.
///
/// Pure: the map says what is up and since when, this says which one to draw.
enum BannerSlot {
    /// Everything that can take the slot, most urgent first (`rank`).
    enum Message: Hashable, CaseIterable {
        /// A hazard ahead with its live distance.
        case hazardApproach
        /// A car asking to stop: the OK pill.
        case stopPill
        /// The driver's own report ("Sending…", "Reported debris · Undo", or a failure) runs a timer (8 s), so it goes
        /// over the planned-stop approach, which can stand for minutes (D60, decision #330): waiting behind it would
        /// let the Undo window run out unseen. A hazard ahead or a car asking to stop still outrank it. Its haptic
        /// does not depend on it being shown (`reportHaptics`).
        case toast
        /// The planned stop coming up.
        case stopApproach
        /// "Passed the debris" keeps its own 3 s timer, so it goes over the standing messages below too.
        case passed
        /// An error stays until it is fixed or closed, and the driver has to see it: it goes over the standing
        /// messages below (a failed Resume would otherwise hide behind the pause it failed to end).
        case error
        /// Sharing paused: stays until resumed; comes back once the error is closed.
        case paused
        // The rest: the newest of these shows (`tieOrder` breaks a tie). D38's "destination changed" joins here.
        case catchUp
        case alertBanner
        case routeNotice

        /// Lower is more urgent. The last three have the same rank: those compete on arrival.
        var rank: Int {
            switch self {
            case .hazardApproach: 0
            case .stopPill: 1
            case .toast: 2
            case .stopApproach: 3
            case .passed: 4
            case .error: 5
            case .paused: 6
            case .catchUp, .alertBanner, .routeNotice: 7
            }
        }

        /// Among "the rest" with the same arrival.
        fileprivate var tieOrder: Int {
            switch self {
            case .alertBanner: 1
            case .catchUp: 2
            case .routeNotice: 3
            default: 4
            }
        }
    }

    struct Result: Equatable {
        /// The message to draw, nil when the slot is empty.
        var shown: Message?
        /// An error is up but another message has the slot: the trip pill shows a red dot.
        var errorHeld: Bool
    }

    /// - Parameters:
    ///   - present: what is up now.
    ///   - arrivals: since when each has been up (`Arrivals`); a missing one (up this very frame) counts as the newest.
    static func resolve(present: Set<Message>, arrivals: [Message: Date] = [:]) -> Result {
        let top = present.min { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.rank == 7 {
                let da = arrivals[a] ?? .distantFuture, db = arrivals[b] ?? .distantFuture
                if da != db { return da > db }
            }
            return a.tieOrder < b.tieOrder
        }
        return Result(shown: top, errorHeld: present.contains(.error) && top != .error)
    }

    /// What the map has in hand, as plain values: `present` turns it into the messages that want the slot, each with
    /// an identity that changes when it is another message of the same kind (also what it announces under).
    struct Inputs {
        var hazardApproachId: String?
        var stopPillId: String?
        /// The planned-stop approach, only when its pill can be drawn (its stop is known).
        var stopApproachId: String?
        var toast: ReportToastModel.State = .hidden
        var passedText: String?
        var error: String?
        var paused = false
        var catchUpId: String?
        var alertBannerId: String?
        var routeNoticeText: String?
    }

    static func present(_ i: Inputs) -> [Message: String] {
        var present: [Message: String] = [:]
        if let id = i.hazardApproachId { present[.hazardApproach] = id }
        if let id = i.stopPillId { present[.stopPill] = id }
        if let id = i.stopApproachId { present[.stopApproach] = id }
        switch i.toast {
        case .hidden: break
        case .sending(let label): present[.toast] = "Sending \(label)"
        case .reported(let label, _): present[.toast] = "Reported \(label). You can undo it."
        case .failed(let message): present[.toast] = message
        }
        if let text = i.passedText { present[.passed] = text }
        if let message = i.error { present[.error] = message }
        if i.paused { present[.paused] = "paused" }
        if let id = i.catchUpId { present[.catchUp] = id }
        if let id = i.alertBannerId { present[.alertBanner] = id }
        if let text = i.routeNoticeText { present[.routeNotice] = text }
        return present
    }

    /// Remembers since when each message has been up, so "the newest of the rest" can be told. A message with a
    /// new identity (another alert, another error line) counts as new; one that goes away is forgotten.
    struct Arrivals: Equatable {
        private var seen: [Message: (identity: String, since: Date)] = [:]

        mutating func update(present: [Message: String], now: Date) {
            seen = seen.filter { present[$0.key] == $0.value.identity }
            for (message, identity) in present where seen[message] == nil {
                seen[message] = (identity, now)
            }
        }

        var dates: [Message: Date] { seen.mapValues(\.since) }

        static func == (a: Arrivals, b: Arrivals) -> Bool { a.dates == b.dates }
    }
}
