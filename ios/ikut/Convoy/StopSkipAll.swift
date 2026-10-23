import Foundation

/// The organizer skipping a stop for everyone (D25 piece 4b): when the button is there, and the words around it.
/// Pure, so the tests reach it without the view. The write is `StopLeaveService.skipForEveryone`; the route is not
/// rebuilt, so a skipped stop only drops out of Next stop, the approach alert, the ETA and the Join ticket.
enum StopSkipAll {
    /// The organizer, on a started trip, on a stop the convoy has not reached: no car counted here (`carReached`,
    /// a car at the stop now or seen there a moment ago) and the lead car has not marked its arrival. Once the
    /// convoy is there it is Leave (4a). A meeting point is never skipped for everyone: the organizer Leaves it.
    static func canSkip(stop: PlannedStop, isOrganizer: Bool, tripStarted: Bool, carReached: Bool) -> Bool {
        isOrganizer && isSkippable(stop: stop, tripStarted: tripStarted, carReached: carReached)
    }

    /// The same state seen by anyone: the stop could still be skipped for everyone, by the organizer.
    static func isSkippable(stop: PlannedStop, tripStarted: Bool, carReached: Bool) -> Bool {
        tripStarted && stop.isOpen && !stop.isMeeting && stop.arrivedAt == nil && !carReached
    }

    /// A car counted at the stop, or seen there a moment ago.
    static func carReached(_ rows: [StopArrival.Row]) -> Bool {
        rows.contains { row in
            switch row.status {
            case .here, .lastSeenHere: true
            default: false
            }
        }
    }

    /// What the organizer reads under the button.
    static let caption = "For everyone. The route stays as it is."

    /// The one sentence before the skip is final.
    static func confirmSentence(stop: PlannedStop) -> String {
        "Skip \(stop.name) for everyone? You can’t undo this, and the route stays as it is."
    }

    /// What everyone else reads where the button would be: "Aqlan can skip this stop for everyone." The organizer's
    /// name comes from their member document (`organizerName`); until that is loaded, the owner word of car number 1
    /// (the organizer's car, kept on rejoin; the lead car can be another car); else "The organizer".
    static func passengerLine(organizerName: String?, cars: [Car]) -> String {
        let named = organizerName.flatMap { $0.isEmpty ? nil : $0 }
        let who = named ?? cars.first { $0.number == 1 }.map(StopLeave.ownerWord) ?? "The organizer"
        return "\(who) can skip this stop for everyone."
    }
}
