import Foundation

/// Changing how long a planned stop lasts (D121): which lengths the organizer can pick, who may, and the
/// "Leaving at" that results. Pure, so the tests reach it without the view.
enum StopStay {
    /// The lengths on offer: the usual ones (`PlannedStop.allowedMinutes`), plus the stop's own when it is something
    /// else (a stop added by an older build), in order.
    static func options(current: Int?) -> [Int] {
        guard let current, !PlannedStop.allowedMinutes.contains(current) else { return PlannedStop.allowedMinutes }
        return (PlannedStop.allowedMinutes + [current]).sorted()
    }

    /// Only the organizer, only on a stop still to do (not skipped, not left), never on the meeting point. The rules
    /// check the same once the trip has started.
    static func canEdit(isOrganizer: Bool, isMeeting: Bool, isOpen: Bool) -> Bool {
        isOrganizer && !isMeeting && isOpen
    }

    static func canEdit(_ stop: PlannedStop, isOrganizer: Bool) -> Bool {
        canEdit(isOrganizer: isOrganizer, isMeeting: stop.isMeeting, isOpen: stop.isOpen)
    }

    /// The lengths the rules accept (whole minutes, 1 to 720).
    static func isValid(_ minutes: Int) -> Bool { (1...720).contains(minutes) }

    /// The stop as every phone reads it once the new length arrives; nil when nothing would change.
    static func changed(_ stop: PlannedStop, to minutes: Int) -> PlannedStop? {
        guard isValid(minutes), stop.minutes != minutes else { return nil }
        var copy = stop
        copy.minutes = minutes
        return copy
    }
}
