import Foundation

/// Leaving a planned stop (D25 piece 4a): who may, when "Leaving at 12:40" is, and the words around the button.
/// Pure, so the tests reach it without the view. A stop that was left is done for everyone (`PlannedStop.isLeft`).
enum StopLeave {
    /// The time the card shows as "Leaving at": a meeting point's `meetAt`; otherwise the moment the lead car first
    /// counted itself at the stop (`arrivedAt`, one server time every phone reads) plus the planned length. Nil
    /// when there is no planned length, or the lead car has not been counted yet. It never leaves by itself.
    static func leavingAt(_ stop: PlannedStop) -> Date? {
        if stop.isMeeting { return stop.meetAt }
        guard let arrivedAt = stop.arrivedAt, let minutes = stop.minutes else { return nil }
        return arrivedAt.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// "Leaving at 12:40", nil without a time.
    static func leavingLine(_ stop: PlannedStop, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        leavingAt(stop).map { "Leaving at \(ConvoyFormat.clock($0, locale: locale, timeZone: timeZone))" }
    }

    /// The lead car's tracker or the organizer, on a started trip, on a stop still to do (the rules check the same).
    static func canLeave(stop: PlannedStop, isLeadTracker: Bool, isOrganizer: Bool, tripStarted: Bool) -> Bool {
        tripStarted && stop.isOpen && (isLeadTracker || isOrganizer)
    }

    /// The lead car's phone writes `arrivedAt` once: a stop with a planned length, not yet marked, while the lead
    /// car counts itself here (a fresh fix within the here-radius).
    static func shouldMarkArrived(stop: PlannedStop, isLeadTracker: Bool, tripStarted: Bool, myStatus: StopArrival.Status?) -> Bool {
        tripStarted && isLeadTracker && stop.isOpen && !stop.isMeeting && stop.minutes != nil
            && stop.arrivedAt == nil && myStatus == .here
    }

    /// The first stop (by route) that `shouldMarkArrived` for this car, if any.
    static func stopToMarkArrived(
        stops: [PlannedStop], isLeadTracker: Bool, tripStarted: Bool, position: Position?, offset: Double?,
        now: Date
    ) -> PlannedStop? {
        stops.first { stop in
            guard stop.id != nil else { return false }
            let status = StopArrival.status(
                position: position, offset: offset, target: .init(stop), pace: nil, speed: 0, now: now)
            return shouldMarkArrived(stop: stop, isLeadTracker: isLeadTracker, tripStarted: tripStarted, myStatus: status)
        }
    }

    /// "Hafiz" from "Hafiz’s Myvi"; the whole name when it has no possessive.
    static func ownerWord(_ car: Car) -> String {
        for mark in ["’s ", "'s "] {
            if let range = car.name.range(of: mark), range.lowerBound > car.name.startIndex {
                return String(car.name[..<range.lowerBound])
            }
        }
        return car.name
    }

    /// Who the convoy is waiting for, as one line: "Hafiz is 3 min away", "Hafiz and 2 more are still on the way".
    /// Nil when every car is here. `leaving` is the viewer's own car, which is not waited for.
    static func waitingLine(_ rows: [StopArrival.Row], leaving carId: String?) -> String? {
        let away = rows.filter { !$0.isHere && $0.id != carId }
        guard let first = away.first else { return nil }
        let name = ownerWord(first.car)
        if away.count > 1 { return "\(name) and \(away.count - 1) more are still on the way" }
        switch first.status {
        case .away(_, let seconds?): return "\(name) is \(ConvoyFormat.duration(seconds)) away"
        case .away(let distance?, nil): return "\(name) is \(ConvoyFormat.distance(distance)) away"
        default: return "\(name) is still on the way"
        }
    }

    /// The one sentence before Leave is final: "Leave R&R Tapah now? Hafiz is 3 min away." A meeting point starts
    /// the convoy.
    static func confirmSentence(stop: PlannedStop, waiting: String?) -> String {
        let ask = stop.isMeeting ? "Start the convoy from \(stop.name) now?" : "Leave \(stop.name) now?"
        return "\(ask) \(waiting ?? "Everyone is here")."
    }

    /// What the others read where the button would be: "Aqlan taps Leave when everyone’s ready".
    static func waitingForLead(leadCar: Car?) -> String {
        let who = leadCar.map(ownerWord) ?? "The lead car"
        return "\(who) taps Leave when everyone’s ready"
    }
}
