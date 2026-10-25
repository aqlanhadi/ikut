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
        /// The planned stop coming up.
        case stopApproach
        /// "Passed the debris" and the report toast ("Reported debris · Undo") keep their own timers (3 s, 5 s), so
        /// they go over the standing messages below: waiting behind one that can last half an hour would let
        /// their time run out unseen.
        case toast
        case passed
        /// Sharing paused: stays until resumed.
        case paused
        // The rest: the newest of these shows (`restOrder` breaks a tie). D38's "destination changed" joins here.
        case catchUp
        case alertBanner
        case routeNotice
        case error

        /// Lower is more urgent. Everything from `catchUp` on has the same rank: those compete on arrival.
        var rank: Int {
            switch self {
            case .hazardApproach: 0
            case .stopPill: 1
            case .stopApproach: 2
            case .toast: 3
            case .passed: 4
            case .paused: 5
            case .catchUp, .alertBanner, .routeNotice, .error: 6
            }
        }

        /// Among "the rest" with the same arrival: an error first (it never times out), then the others.
        fileprivate var tieOrder: Int {
            switch self {
            case .error: 0
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
    ///   - arrivals: since when each has been up (`Arrivals`); a missing one counts as oldest.
    static func resolve(present: Set<Message>, arrivals: [Message: Date] = [:]) -> Result {
        let top = present.min { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.rank == 6 {
                let da = arrivals[a] ?? .distantPast, db = arrivals[b] ?? .distantPast
                if da != db { return da > db }
            }
            return a.tieOrder < b.tieOrder
        }
        return Result(shown: top, errorHeld: present.contains(.error) && top != .error)
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
