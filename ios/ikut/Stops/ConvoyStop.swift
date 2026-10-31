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

    /// A car this far along the route past the stop point is still at the stop (cars spread out in a car park).
    static let atStopSpread: Double = 150
    /// A planned stop this close past the stop point is where the convoy is stopping: its approach alert is not held.
    static let plannedStopNear: Double = 500

    /// Hazards further along the route than the stop point are held while stopped: a parked car is not approaching
    /// them. Cars still coming in to the stop keep their alerts for what lies before it.
    static func holds(offset: Double, stopOffset: Double?) -> Bool {
        guard let stopOffset else { return false }
        return offset > stopOffset
    }

    /// A planned stop is held only when it lies more than `plannedStopNear` past the stop point: one just past it is
    /// most likely the very place the convoy is pulling into.
    static func holdsPlannedStop(offset: Double, stopOffset: Double?) -> Bool {
        guard let stopOffset else { return false }
        return offset > stopOffset + plannedStopNear
    }

    /// The stop point: the reference car's offset (the lead car, else the front car), unless its fresh fix says it is
    /// moving faster than `parkedSpeed` (the lead car pulling away, a front car that drove on): then nothing is held.
    static func stopPoint(
        reference: ConvoyEntry?, config: ConvoyOrdering.Config = .default
    ) -> Double? {
        guard let reference else { return nil }
        if !reference.isStale, !reference.isPaused, reference.movingSpeed >= config.parkedSpeed { return nil }
        return reference.convoyOffset
    }

    /// The stop point to hold alerts beyond, for my car at `myOffset`: nil (hold nothing) once my car is past the stop
    /// by more than `atStopSpread` (it missed the exit or drove on, and is driving towards what lies ahead), or when
    /// either is unknown.
    static func holdPoint(stopOffset: Double?, myOffset: Double?) -> Double? {
        guard let stopOffset, let myOffset, myOffset <= stopOffset + atStopSpread else { return nil }
        return stopOffset
    }

    /// How long the lead car stays at rest (within `restRadius`) before that place is where it stopped.
    static let settleTime: TimeInterval = 120
    static let restRadius: CLLocationDistance = 100
    /// Before the lead car has settled anywhere (rolling in, a red light short of the car park), the phase ends only
    /// this far from its first fix, so a mistaken We’ve stopped still ends at road speed.
    static let unsettledMoveOff: CLLocationDistance = 2_000

    /// Watches the lead car's own fixes in memory (nothing is written) and says once when it has moved off (#682): a
    /// fresh fix that is moving, more than `moveOffDistance` from where it settled (at rest for `settleTime`), or more
    /// than `unsettledMoveOff` from its first fix while it has not settled. A fix at rest never ends it, however far a
    /// coarse fix jumps. A new phase (another `since`) starts afresh.
    struct MoveOff: Sendable {
        private var phase: Date?
        private var first: CLLocationCoordinate2D?
        private var rest: (at: CLLocationCoordinate2D, since: Date)?
        private var anchor: CLLocationCoordinate2D?
        private var fired = false

        init() {}

        /// No phase, or not the lead car's phone: forget everything.
        mutating func reset() { self = MoveOff() }

        /// - Parameters:
        ///   - at: when the fix was taken.
        ///   - moving: the fix is fresh and faster than `parkedSpeed`.
        mutating func check(phase since: Date?, here: CLLocationCoordinate2D, at: Date, moving: Bool) -> Bool {
            guard let since else {
                self = MoveOff()
                return false
            }
            if phase != since { self = MoveOff(); phase = since }
            if first == nil { first = here }
            if !moving {
                if let rest, Self.distance(rest.at, here) <= ConvoyStop.restRadius {
                    if at.timeIntervalSince(rest.since) >= ConvoyStop.settleTime { anchor = rest.at }
                } else {
                    rest = (here, at)
                }
                return false
            }
            rest = nil
            guard !fired, let from = anchor ?? first else { return false }
            let limit = anchor == nil ? ConvoyStop.unsettledMoveOff : ConvoyStop.moveOffDistance
            fired = Self.distance(from, here) > limit
            return fired
        }

        private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
            CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
    }
}
