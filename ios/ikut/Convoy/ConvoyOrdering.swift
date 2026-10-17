import CoreLocation
import FirebaseFirestore
import Foundation

/// A convoy car with a `convoyOffset`, in convoy order.
struct ConvoyEntry: Equatable, Identifiable, Sendable {
    var id: String
    var car: Car
    var position: Position
    /// Meters along the main route.
    var convoyOffset: Double
    /// Smoothed speed estimate in m/s, floored at `Config.minSpeed`. Used for gap and merge times.
    var speed: Double
    /// The car furthest ahead (first in the list).
    var isFront: Bool
    /// The designated lead (`Car.isLead`); not necessarily the front.
    var isLead: Bool
    /// Position is old. Never true while `isPaused`: a paused car is expected to go quiet.
    var isStale: Bool
    /// The tracker paused sharing (`TripSessionLogic.isPaused`); the last position is frozen.
    var isPaused = false
    /// Seconds since the last position; nil when the position has no timestamp yet.
    var age: TimeInterval?
    /// Gap to the car ahead; nil for the front car.
    var gap: Gap?
    /// Time behind the ETA reference car (the front-most fresh car), summed over the gaps between.
    /// Zero for the reference itself; nil for cars ahead of it (stale fronts).
    var timeBehindReference: TimeInterval?

    struct Gap: Equatable, Sendable {
        var distance: Double
        var time: TimeInterval
        /// Over the separation threshold (distance or time).
        var isSeparated: Bool
    }
}

/// A car still on its own route, heading for the merge point.
struct JoiningEntry: Equatable, Identifiable, Sendable {
    var id: String
    var car: Car
    /// Nil until the car has a position.
    var position: Position?
    /// Meters left to the merge point; nil when unknown (see `ConvoyOrdering`).
    var distanceToMerge: Double?
    /// `distanceToMerge` over the smoothed speed, floored; nil when the distance is unknown.
    var timeToMerge: TimeInterval?
    var speed: Double
    var isStale: Bool
    var isPaused = false
    var age: TimeInterval?
}

struct ConvoySnapshot: Equatable, Sendable {
    /// Front car first.
    var convoy: [ConvoyEntry]
    /// Nearest to merging first; unknown distances last.
    var joining: [JoiningEntry]

    static let empty = ConvoySnapshot(convoy: [], joining: [])

    /// The car furthest ahead.
    var front: ConvoyEntry? { convoy.first }
    /// The designated lead car, if it is in the convoy.
    var lead: ConvoyEntry? { convoy.first(where: \.isLead) }
    /// The car whose ETA is requested: the front-most car with a fresh, unpaused position. A stale car's
    /// position says little about where it is now, so it must not anchor everyone's ETA.
    var etaReference: ConvoyEntry? { convoy.first(where: { !$0.isStale && !$0.isPaused }) }
    /// Front to back, meters. Nil with fewer than two cars.
    var spread: Double? {
        guard let first = convoy.first, let last = convoy.last, convoy.count > 1 else { return nil }
        return first.convoyOffset - last.convoyOffset
    }
    var separatedGaps: [ConvoyEntry] { convoy.filter { $0.gap?.isSeparated == true } }
}

/// Orders the convoy and works out gaps. Pure: everything comes in as arguments.
///
/// **Who is in the convoy:** a car with a position whose `convoyOffset` is non-nil, whatever its
/// `state` says (the position is written by the tracker, `state` may lag). A car with a position but
/// no `convoyOffset` is joining. A car with no position yet is joining if `state == .joining`, and
/// left out otherwise (nothing to place it by).
///
/// **Order:** `convoyOffset` descending, then badge number, then id, so equal offsets don't flicker.
///
/// **Front vs lead:** the list is in road order, so the first row is the *actual front*
/// (`isFront`), and `isLead` marks the *designated lead* wherever it is. The UI shows "Lead" on the
/// designated lead, and "Front" on the front car when it isn't the lead. Gaps are always to the car
/// physically ahead, and ETAs hang off the front, not the lead, because that's the car whose route
/// remaining is shortest. If the lead falls behind, nothing reorders around it.
///
/// **Gap time:** gap distance / follower's speed. The speed comes from `speeds` (smoothed, see
/// `SpeedSmoother`), falling back to the raw `Position.speed`, then is floored at `Config.minSpeed`
/// (5 m/s = 18 km/h) so a car stopped at lights doesn't produce an hour-long gap.
///
/// **Joining distance:** the car's remaining distance along its own route to the point where it
/// joins the main route. That point is `ownMergeOffsets[carId]` (from
/// `RouteLine.mergeOffset(of:).otherOffset`, see `mergeOffsets`), minus `routeOffset`, clamped at 0.
/// If there is no such offset (no route, never joins), the straight-line distance from the car to the
/// main-route coordinate at `car.mergeOffset` is used instead, or nil when that is unknown too.
enum ConvoyOrdering {
    struct Config: Equatable, Sendable {
        /// Lower bound for speed estimates, m/s.
        var minSpeed: Double = 5
        /// A position older than this is stale.
        var staleAfter: TimeInterval = 60
        /// A gap is flagged when it is longer than this (meters) or ...
        var separationDistance: Double = 5000
        /// ... slower than this (seconds).
        var separationTime: TimeInterval = 300

        static let `default` = Config()
    }

    static func order(
        cars: [Car],
        positions: [String: Position],
        now: Date,
        speeds: [String: Double] = [:],
        mainRoute: RouteLine? = nil,
        ownMergeOffsets: [String: Double] = [:],
        config: Config = .default
    ) -> ConvoySnapshot {
        var convoy: [ConvoyEntry] = []
        var joining: [JoiningEntry] = []

        for car in cars {
            let id = carID(car)
            let position = positions[id]
            let speed = effectiveSpeed(speeds[id] ?? position?.speed, config: config)
            let age = position?.updatedAt.map { max(0, now.timeIntervalSince($0)) }
            let paused = TripSessionLogic.isPaused(car, now: now)
            let stale = !paused && (age ?? 0) > config.staleAfter

            if let position, let offset = position.convoyOffset {
                convoy.append(ConvoyEntry(
                    id: id, car: car, position: position, convoyOffset: offset, speed: speed,
                    isFront: false, isLead: car.isLead, isStale: stale, isPaused: paused, age: age,
                    gap: nil, timeBehindReference: nil))
            } else if position != nil || car.state == .joining {
                let distance = position.flatMap {
                    distanceToMerge(car: car, position: $0, mainRoute: mainRoute, ownMergeOffset: ownMergeOffsets[id])
                }
                joining.append(JoiningEntry(
                    id: id, car: car, position: position, distanceToMerge: distance,
                    timeToMerge: distance.map { $0 / speed }, speed: speed, isStale: stale, isPaused: paused, age: age))
            }
        }

        convoy.sort { a, b in
            if a.convoyOffset != b.convoyOffset { return a.convoyOffset > b.convoyOffset }
            return numberOrder(a.car, b.car)
        }
        for i in convoy.indices {
            convoy[i].isFront = i == 0
            guard i > 0 else { continue }
            let distance = max(0, convoy[i - 1].convoyOffset - convoy[i].convoyOffset)
            let time = distance / convoy[i].speed
            convoy[i].gap = ConvoyEntry.Gap(
                distance: distance, time: time,
                isSeparated: distance > config.separationDistance || time > config.separationTime)
        }
        if let ref = convoy.firstIndex(where: { !$0.isStale && !$0.isPaused }) {
            var total: TimeInterval = 0
            convoy[ref].timeBehindReference = 0
            for i in (ref + 1)..<max(ref + 1, convoy.count) {
                total += convoy[i].gap?.time ?? 0
                convoy[i].timeBehindReference = total
            }
        }

        joining.sort { a, b in
            switch (a.distanceToMerge, b.distanceToMerge) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return numberOrder(a.car, b.car)
            }
        }
        return ConvoySnapshot(convoy: convoy, joining: joining)
    }

    /// Own-route merge offsets for every car that has a route that joins `main`. Not free (it walks
    /// the route), so callers compute it when cars or the main route change, not on every fix.
    static func mergeOffsets(cars: [Car], main: RouteLine) -> [String: Double] {
        var result: [String: Double] = [:]
        for car in cars {
            guard let encoded = car.route, let own = ownRoute(encoded),
                  let merge = main.mergeOffset(of: own) else { continue }
            result[carID(car)] = merge.otherOffset
        }
        return result
    }

    /// A decoded car route, or nil when it has fewer than two points.
    static func ownRoute(_ encoded: String) -> RouteLine? {
        let line = RouteLine(Polyline.decode(encoded))
        return line.coordinates.count > 1 ? line : nil
    }

    static func carID(_ car: Car) -> String { car.id ?? car.name }

    static func effectiveSpeed(_ speed: Double?, config: Config) -> Double {
        let s = speed.flatMap { $0.isFinite ? $0 : nil } ?? 0
        return max(config.minSpeed, s)
    }

    private static func distanceToMerge(
        car: Car, position: Position, mainRoute: RouteLine?, ownMergeOffset: Double?
    ) -> Double? {
        if let ownMergeOffset { return max(0, ownMergeOffset - position.routeOffset) }
        guard let mainRoute, let offset = car.mergeOffset, let point = mainRoute.coordinate(atOffset: offset)
        else { return nil }
        let here = CLLocationCoordinate2D(latitude: position.location.latitude, longitude: position.location.longitude)
        return RouteLine.haversine(here, point)
    }

    private static func numberOrder(_ a: Car, _ b: Car) -> Bool {
        let na = a.number ?? Int.max
        let nb = b.number ?? Int.max
        if na != nb { return na < nb }
        return carID(a) < carID(b)
    }
}

/// Smooths each car's speed so gap times don't flicker with every fix.
///
/// Exponential moving average with `alpha` 0.3 per *new* fix (a fix with the same `updatedAt` as the
/// last one is ignored, so re-delivered snapshots don't over-weight it). At one fix a second that is a
/// time constant of about 3 s: quick enough to follow braking, slow enough to flatten GPS noise.
/// The floor is applied by `ConvoyOrdering`, after smoothing, so a stop dips the average instead of
/// being clipped before it.
struct SpeedSmoother: Sendable {
    var alpha: Double = 0.3
    private var estimates: [String: (speed: Double, stamp: Date?)] = [:]

    init(alpha: Double = 0.3) { self.alpha = alpha }

    mutating func ingest(carId: String, position: Position) {
        let raw = position.speed.isFinite ? max(0, position.speed) : 0
        guard let old = estimates[carId] else {
            estimates[carId] = (raw, position.updatedAt)
            return
        }
        if let stamp = position.updatedAt, stamp == old.stamp { return }
        estimates[carId] = (old.speed + alpha * (raw - old.speed), position.updatedAt)
    }

    mutating func ingest(_ positions: [String: Position]) {
        for (id, p) in positions { ingest(carId: id, position: p) }
        let gone = estimates.keys.filter { positions[$0] == nil }
        for id in gone { estimates[id] = nil }
    }

    func speed(for carId: String) -> Double? { estimates[carId]?.speed }

    var all: [String: Double] { estimates.mapValues(\.speed) }
}
