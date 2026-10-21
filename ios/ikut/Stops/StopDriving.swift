import Foundation

/// Whether this phone is in a moving car, from its own location speed (discovery page, rule 1 and
/// question 5). Above `speed` for `holdFor` seconds counts as driving; back below it for the same
/// time counts as stopped, so a red light does not unlock the card for a second.
struct DrivingDetector: Equatable, Sendable {
    /// 15 km/h in meters per second.
    static let speed: Double = 15 / 3.6
    static let holdFor: TimeInterval = 10

    private(set) var isDriving = false
    /// When the speed first crossed the line the other way; nil while it hasn't.
    private var crossedAt: Date?

    init(isDriving: Bool = false) { self.isDriving = isDriving }

    /// Feeds one reading. An unknown speed (nil or negative, as CoreLocation reports it) changes nothing.
    mutating func feed(speed metersPerSecond: Double?, at time: Date) {
        guard let metersPerSecond, metersPerSecond >= 0 else { return }
        let above = metersPerSecond > Self.speed
        guard above != isDriving else {
            crossedAt = nil
            return
        }
        let start = crossedAt ?? time
        crossedAt = start
        if time.timeIntervalSince(start) >= Self.holdFor {
            isDriving = above
            crossedAt = nil
        }
    }
}

/// What the open stop card remembers until it closes: the answer to "Are you a passenger?". It is
/// never written anywhere (discovery page, question 13): the next card asks again.
struct StopCardSession: Equatable, Sendable {
    private(set) var isPassenger = false

    mutating func confirmPassenger() { isPassenger = true }

    /// "I'm driving": back to the default place; nothing is remembered.
    mutating func confirmDriving() { isPassenger = false }

    /// The card closed.
    mutating func close() { isPassenger = false }
}

/// What the card allows while the phone moves.
enum StopCardGate {
    enum Mode: Equatable, Sendable {
        /// Not moving, or a passenger said so: everything works.
        case full
        /// Moving, a stop is open: status only, with "Stop and park to change anything."
        case readOnly
        /// Moving, no stop open: four tiles, then the best place read back. Never the place list.
        case driverAsk
    }

    static func mode(driving: Bool, session: StopCardSession, hasOpenStop: Bool) -> Mode {
        guard driving, !session.isPassenger else { return .full }
        return hasOpenStop ? .readOnly : .driverAsk
    }

    /// Search, Drop a pin and the full place list ask "Are you a passenger?" first on a moving phone.
    static func needsPassengerCheck(driving: Bool, session: StopCardSession) -> Bool {
        driving && !session.isPassenger
    }
}
