import Foundation

/// What the Live Activity's views decide from a content state, kept out of the views so the app's tests reach it
/// (the file is compiled into both the app and `ikutWidgets`). Pure; no Firebase.
enum ConvoyActivityPresentation {
    typealias Kind = ConvoyActivityAttributes.Kind
    typealias State = ConvoyActivityAttributes.ContentState

    /// How long after the newest other-car data the activity counts as not updating (note 6).
    static let staleAfter: TimeInterval = 120

    /// What to draw: the state, or Not updating (greyed, over whatever it was) once the system says it is stale.
    /// Sharing paused ends at its own stale date (the pause's end), so a pause never reads Not updating while it lasts.
    enum Display: Equatable {
        case state(Kind)
        case notUpdating(was: Kind)

        var kind: Kind {
            switch self {
            case .state(let kind), .notUpdating(let kind): kind
            }
        }

        var isNotUpdating: Bool { if case .notUpdating = self { true } else { false } }
    }

    /// Arrived and Trip ended carry no stale date, so they are never greyed.
    static func display(_ state: State, isStale: Bool) -> Display {
        guard isStale, state.kind != .arrived, state.kind != .tripEnded else { return .state(state.kind) }
        return .notUpdating(was: state.kind)
    }

    // MARK: Compact trailing value

    /// The symbol before the compact value: a ring for a time to a stop (or here), a flag for the destination, a tick for
    /// a count of OKs or ready cars.
    enum Prefix: Equatable { case none, ring, flag, tick }

    enum Trailing: Equatable {
        case nothing
        /// At most `maxCharacters` characters, after an optional prefix symbol.
        case value(String, Prefix)
        /// One glyph on its own: the cars for Waiting, a tick for Arrived, a cross for Trip ended.
        case cars, tick, cross
    }

    /// The compact island has 45 pt of content beside the camera cutout: at 13 pt that is five characters.
    static let maxCharacters = 5

    static func trailing(_ s: State, now: Date) -> Trailing {
        switch s.kind {
        case .waiting:
            guard s.isOrganizer, let ready = s.readyCount, let total = s.carCount else { return .cars }
            return .value(count(ready, of: total), .tick)
        case .joining:
            if let meters = s.joinMeters { return .value(compactDistance(meters), .none) }
            return s.joinSeconds.map { .value(compactDuration($0), .none) } ?? .nothing
        case .parkedAhead:
            return s.otherMeters.map { .value(compactDistance($0), .none) } ?? .nothing
        case .catchUp:
            return s.otherMeters.map { .value(compactDistance($0), .none) } ?? .nothing
        case .inConvoy:
            if s.stopName != nil {
                if let seconds = s.stopSeconds { return .value(compactDuration(seconds), .ring) }
                return s.stopMeters.map { .value(compactDistance($0), .ring) } ?? .nothing
            }
            if let seconds = s.destinationSeconds { return .value(compactDuration(seconds), .flag) }
            return s.destinationMeters.map { .value(compactDistance($0), .flag) } ?? .nothing
        case .atStop:
            guard let here = s.hereCount, let total = s.hereTotal else { return .nothing }
            return .value(count(here, of: total), .ring)
        case .hazardAhead:
            return s.hazardMeters.map { .value(compactDistance($0), .none) } ?? .nothing
        case .stopRequest:
            guard let ok = s.okCount, let total = s.okTotal else { return .nothing }
            return .value(count(ok, of: total), .tick)
        case .stopped:
            return s.stoppedSince.map { .value(compactDuration(now.timeIntervalSince($0)), .none) } ?? .nothing
        case .sharingPaused:
            return s.pausedUntil.map { .value(compactDuration($0.timeIntervalSince(now)), .none) } ?? .nothing
        case .arrived: return .tick
        case .tripEnded: return .cross
        }
    }

    /// "3/4"; each side is capped at 99 so it never passes five characters.
    static func count(_ n: Int, of total: Int) -> String { "\(min(n, 99))/\(min(total, 99))" }

    /// "350 m", "3.3km", "14 km", "160km": at most five characters (`ConvoyFormat.distance` gives "1.0 km", "100 km").
    static func compactDistance(_ meters: Double) -> String {
        let m = max(0, meters.isFinite ? meters : 0)
        let tens = Int((m / 10).rounded()) * 10
        if tens < 1000 { return "\(tens) m" }
        let km = m / 1000
        if km < 10 {
            let tenths = (km * 10).rounded() / 10
            return tenths >= 10 ? "10 km" : String(format: "%.1fkm", tenths)
        }
        let whole = min(999, Int(km.rounded()))
        return whole < 100 ? "\(whole) km" : "\(whole)km"
    }

    /// "41m", "2h41": whole minutes under an hour, then hours and two-digit minutes with no separator.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(0, seconds.isFinite ? seconds : 0) / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes)m" }
        let h = min(99, minutes / 60), m = minutes % 60
        return String(format: "%dh%02d", h, m)
    }

    /// Whole minutes since `date`, at least 1: Stopped counts up ("12 min"); the title never holds a timer (note 17).
    static func minutes(since date: Date, now: Date) -> Int { max(1, Int(now.timeIntervalSince(date) / 60)) }

    /// Whole minutes until `date`, at least 1: Sharing paused counts down ("Back on in 23 min").
    static func minutes(until date: Date, now: Date) -> Int { max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up))) }
}
