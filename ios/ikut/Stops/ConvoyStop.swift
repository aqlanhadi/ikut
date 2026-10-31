import CoreLocation
import Foundation

/// The convoy's stopped phase (D122): the lead car's tracker or the organizer taps We’ve stopped on a stop request,
/// the trip records it (`Trip.stoppedAt`, `stoppedBy`, `stoppedEventId`), and every phone shows Stopped until the
/// lead car or the organizer taps Continue (or Leave on a planned stop), which deletes the fields.
///
/// A forgotten phase never sticks: it counts as over `cap` after it began, whatever the trip says (the rules use the
/// same 90 minutes, so a new We’ve stopped is taken then), and the lead car's phone ends it once its car has moved
/// more than `moveOffDistance` from where it stood (`MoveOff`). Pure.
struct ConvoyStop: Equatable, Sendable {
    /// After this long the phase counts as over. Mirrors `firestore.rules` (`stopPhaseLive`).
    static let cap: TimeInterval = 90 * 60
    /// The lead car this far (straight line) from where it stood when the phase began: the convoy is moving again.
    static let moveOffDistance: CLLocationDistance = 500

    var since: Date
    var by: String?
    var eventId: String?

    /// The phase in effect at `now`, nil when there is none (never stopped, Continue tapped, or past the cap).
    static func current(_ trip: Trip?, now: Date) -> ConvoyStop? {
        guard let trip, trip.status == .active, let since = trip.stoppedAt,
              now.timeIntervalSince(since) < cap else { return nil }
        return ConvoyStop(since: since, by: trip.stoppedBy, eventId: trip.stoppedEventId)
    }

    /// When a phase that began at `since` stops counting, for a timer.
    static func endsAt(_ since: Date) -> Date { since.addingTimeInterval(cap) }

    /// Who may start and end it: the lead car's tracker or the organizer (the rules ask the same).
    static func mayStartOrEnd(isLeadTracker: Bool, isOrganizer: Bool) -> Bool { isLeadTracker || isOrganizer }

    /// We’ve stopped also starts the phase: the right person, a stop request closed as stopped, and no phase on yet
    /// (the asker's own We’ve stopped closes the request only).
    static func startsWith(reason: StopClosedReason, isLeadTracker: Bool, isOrganizer: Bool, active: Bool) -> Bool {
        reason == .stopped && !active && mayStartOrEnd(isLeadTracker: isLeadTracker, isOrganizer: isOrganizer)
    }

    /// Hazards and planned stops further along the route than the stop point are held while stopped: a parked car is
    /// not approaching them. Cars still coming in to the stop keep their alerts for what lies before it.
    static func holds(offset: Double, stopOffset: Double?) -> Bool {
        guard let stopOffset else { return false }
        return offset > stopOffset
    }

    /// Remembers where the lead car stood when it first saw the phase, in memory only (nothing is written), and says
    /// once when it has moved off. A new phase (another `since`) starts afresh.
    struct MoveOff: Sendable {
        private var phase: Date?
        private var anchor: CLLocationCoordinate2D?
        private var fired = false

        init() {}

        /// True once, the first time `here` is more than `moveOffDistance` from the first fix seen in this phase.
        mutating func check(phase since: Date?, here: CLLocationCoordinate2D) -> Bool {
            guard let since else {
                self = MoveOff()
                return false
            }
            if phase != since { self = MoveOff(); phase = since }
            guard let anchor else {
                anchor = here
                return false
            }
            guard !fired else { return false }
            let moved = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                .distance(from: CLLocation(latitude: here.latitude, longitude: here.longitude))
            fired = moved > ConvoyStop.moveOffDistance
            return fired
        }
    }
}
