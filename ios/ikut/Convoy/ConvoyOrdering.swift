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
    /// The same smoothed speed without the floor: how fast the car is really going (0 when parked).
    var movingSpeed: Double = 0
    /// Slower than `Config.parkedSpeed` (about 20 km/h): stopped, parked or crawling.
    var isParked = false
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
    /// Time behind the ETA reference car (`ConvoySnapshot.etaReference`), summed over the gaps between.
    /// Zero for the reference itself; nil for cars ahead of it (a stale front, a car parked far ahead).
    var timeBehindReference: TimeInterval?
    /// Within `ConvoyArrival.radius` of the end of the main route.
    var hasArrived = false

    struct Gap: Equatable, Sendable {
        var distance: Double
        var time: TimeInterval
        /// Over the separation threshold (distance or time).
        var isSeparated: Bool
        /// Over the threshold, and a car ahead of the gap and a car behind it were within the threshold of
        /// each other earlier in the trip (`ConvoySnapshot.together`) and are over it now: they were
        /// together and have drifted apart. Only this warns; a car that has been far ahead or behind since
        /// it joined doesn't, nor a gap between two parked cars that a moving car is coming up to.
        var hasDrifted = false
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

/// Two cars, in either order.
struct CarPair: Hashable, Sendable {
    let first: String
    let second: String

    init(_ a: String, _ b: String) {
        first = min(a, b)
        second = max(a, b)
    }
}

struct ConvoySnapshot: Equatable, Sendable {
    /// Front car first.
    var convoy: [ConvoyEntry]
    /// Nearest to merging first; unknown distances last.
    var joining: [JoiningEntry]
    /// The car the ETA is requested for (see `ConvoyOrdering.referenceIndex`); nil with no fresh car.
    var referenceId: String?
    /// Pairs of cars that have been within the separation threshold of each other at some refresh so
    /// far, this one included. The caller keeps it and passes it back in (`ConvoyOrdering.order`).
    var together: Set<CarPair> = []

    static let empty = ConvoySnapshot(convoy: [], joining: [])

    /// The car furthest ahead.
    var front: ConvoyEntry? { convoy.first }
    /// The designated lead car, if it is in the convoy.
    var lead: ConvoyEntry? { convoy.first(where: \.isLead) }
    /// The car whose ETA is requested, and every other car's arrival is worked out from: the designated
    /// lead when it is fresh, else the car with the most fresh cars around it (`ConvoyOrdering`).
    var etaReference: ConvoyEntry? { referenceId.flatMap { id in convoy.first(where: { $0.id == id }) } }
    /// Front to back, meters. Nil with fewer than two cars.
    var spread: Double? {
        guard let first = convoy.first, let last = convoy.last, convoy.count > 1 else { return nil }
        return first.convoyOffset - last.convoyOffset
    }
    /// Cars behind a gap that has opened up between cars that were together (`Gap.hasDrifted`): what the
    /// separation warning is about.
    var driftedGaps: [ConvoyEntry] { convoy.filter { $0.gap?.hasDrifted == true } }
    /// Meters along the main route from car `from` to car `to`: positive when `to` is ahead. Nil unless
    /// both are in the convoy.
    func distance(from: String?, to: String) -> Double? {
        guard let from, let a = convoy.first(where: { $0.id == from }),
              let b = convoy.first(where: { $0.id == to }) else { return nil }
        return b.convoyOffset - a.convoyOffset
    }
    /// Every car (convoy and joining) has reached the destination; false with no cars.
    var everyoneArrived: Bool { !convoy.isEmpty && joining.isEmpty && convoy.allSatisfy(\.hasArrived) }
    func hasArrived(_ carId: String?) -> Bool {
        guard let carId else { return false }
        return convoy.first(where: { $0.id == carId })?.hasArrived ?? false
    }
}

/// When a car counts as arrived: its offset along the main route is within `radius` meters of the
/// route's end (the destination). Pure.
enum ConvoyArrival {
    static let radius: Double = 150

    static func hasArrived(offset: Double, routeLength: Double?) -> Bool {
        guard let routeLength, routeLength > 0, offset.isFinite else { return false }
        return offset >= routeLength - radius
    }
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
/// physically ahead. If the lead falls behind, nothing reorders around it.
///
/// **ETA reference** (D26): the car every arrival time is worked out from. A car on the route is in
/// the convoy however far ahead it is (a friend parked at an R&R 38 km on), so the front car says
/// little about when the convoy arrives. The reference is the designated lead when its position is
/// fresh; else the fresh car with the most other fresh cars within `Config.groupRadius` (2 km) of it,
/// the one further back on a tie; nil with no fresh car. Arrived and paused cars never count.
///
/// **Separation** (D26): a gap over the threshold warns only once the cars on either side of it were
/// within the threshold of each other at some point (`together`, kept by the caller across refreshes)
/// and those two are over it now.
/// A pair counts as together when both are fresh and the one behind is within `separationDistance`
/// and `separationTime` of the one ahead. Pairs, not neighbours, so a car passing between two others
/// doesn't make them forget they were together.
///
/// **Gap time:** gap distance / follower's speed. The speed comes from `speeds` (smoothed, see
/// `SpeedSmoother`), falling back to the raw `Position.speed`, then is floored at `Config.minSpeed`
/// (5 m/s = 18 km/h) so a car stopped at lights doesn't produce an hour-long gap.
///
/// **Joining distance:** the car's remaining distance along its own route to the point where it
/// joins the main route. That point is `ownMergeOffsets[carId]` (from
/// `RouteLine.mergeOffset(of:).otherOffset`, see `mergeOffsets`), minus `routeOffset`, clamped at 0.
/// If the car has its own route but no such offset (it never joins), the rest of that route: its length minus
/// `routeOffset`, by road. If there is no route, the straight-line distance from the car to the
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
        /// Cars this close (meters along the route) count as one group, for the ETA reference and the
        /// distance in the words ("38 km ahead").
        var groupRadius: Double = 2000
        /// Slower than this (m/s, about 20 km/h) a car reads as parked.
        var parkedSpeed: Double = 20 / 3.6

        static let `default` = Config()
    }

    static func order(
        cars: [Car],
        positions: [String: Position],
        now: Date,
        speeds: [String: Double] = [:],
        mainRoute: RouteLine? = nil,
        ownMergeOffsets: [String: Double] = [:],
        together: Set<CarPair> = [],
        config: Config = .default
    ) -> ConvoySnapshot {
        var convoy: [ConvoyEntry] = []
        var joining: [JoiningEntry] = []

        for car in cars {
            let id = carID(car)
            let position = positions[id]
            let moving = movingSpeed(speeds[id] ?? position?.speed)
            let speed = effectiveSpeed(moving, config: config)
            let age = position?.updatedAt.map { max(0, now.timeIntervalSince($0)) }
            let paused = TripSessionLogic.isPaused(car, now: now)
            let stale = !paused && (age ?? 0) > config.staleAfter

            if let position, let offset = position.convoyOffset {
                convoy.append(ConvoyEntry(
                    id: id, car: car, position: position, convoyOffset: offset, speed: speed,
                    movingSpeed: moving, isParked: moving < config.parkedSpeed, isFront: false, isLead: car.isLead,
                    isStale: stale, isPaused: paused, age: age, gap: nil, timeBehindReference: nil,
                    hasArrived: ConvoyArrival.hasArrived(offset: offset, routeLength: mainRoute?.length)))
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
        let pairs = together.union(togetherPairs(convoy, config: config))
        let ordered = convoy
        for i in convoy.indices where i > 0 && convoy[i].gap?.isSeparated == true {
            convoy[i].gap?.hasDrifted = ordered[..<i].contains { a in
                ordered[i...].contains { b in
                    pairs.contains(CarPair(a.id, b.id)) && isApart(a, b, config: config)
                }
            }
        }
        let refIndex = referenceIndex(convoy, config: config)
        if let ref = refIndex {
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
        return ConvoySnapshot(
            convoy: convoy, joining: joining, referenceId: refIndex.map { convoy[$0].id }, together: pairs)
    }

    /// `behind` is over the separation threshold from `ahead` (distance, or time at its floored speed).
    private static func isApart(_ ahead: ConvoyEntry, _ behind: ConvoyEntry, config: Config) -> Bool {
        let distance = ahead.convoyOffset - behind.convoyOffset
        return distance > config.separationDistance || distance / behind.speed > config.separationTime
    }

    /// A fresh car: its position is recent and its tracker isn't paused.
    private static func isFresh(_ e: ConvoyEntry) -> Bool { !e.isStale && !e.isPaused }

    /// Pairs of fresh cars within the separation threshold of each other right now. `convoy` is front first.
    static func togetherPairs(_ convoy: [ConvoyEntry], config: Config) -> Set<CarPair> {
        var pairs: Set<CarPair> = []
        let fresh = convoy.filter(isFresh)
        for (i, ahead) in fresh.enumerated() {
            for behind in fresh[(i + 1)...] {
                let distance = ahead.convoyOffset - behind.convoyOffset
                guard distance <= config.separationDistance else { break }
                if distance / behind.speed <= config.separationTime { pairs.insert(CarPair(ahead.id, behind.id)) }
            }
        }
        return pairs
    }

    /// Index of the ETA reference in `convoy` (front first): the designated lead when fresh, else the
    /// fresh car with the most fresh cars within `groupRadius`, the one further back on a tie. Cars
    /// that have arrived don't count. Nil when no car qualifies.
    static func referenceIndex(_ convoy: [ConvoyEntry], config: Config) -> Int? {
        let candidates = convoy.indices.filter { isFresh(convoy[$0]) && !convoy[$0].hasArrived }
        if let lead = candidates.first(where: { convoy[$0].isLead }) { return lead }
        var best: (index: Int, count: Int)?
        for i in candidates {
            let count = candidates.filter {
                $0 != i && abs(convoy[$0].convoyOffset - convoy[i].convoyOffset) <= config.groupRadius
            }.count
            // Front first, so `>=` keeps the one further back on a tie.
            if count >= (best?.count ?? -1) { best = (i, count) }
        }
        return best?.index
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
        max(config.minSpeed, movingSpeed(speed))
    }

    /// A speed as it is, without the floor: 0 when unknown, negative or not a number.
    static func movingSpeed(_ speed: Double?) -> Double {
        max(0, speed.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }

    private static func distanceToMerge(
        car: Car, position: Position, mainRoute: RouteLine?, ownMergeOffset: Double?
    ) -> Double? {
        if let ownMergeOffset { return max(0, ownMergeOffset - position.routeOffset) }
        // An own route that never meets the main one (no merge offset for it): the rest of that route, by road.
        // Only once the main route is known; before that, a missing offset says nothing about merging.
        if mainRoute != nil, let encoded = car.route, let own = ownRoute(encoded) {
            return max(0, own.length - position.routeOffset)
        }
        guard let mainRoute, let offset = car.mergeOffset, let point = mainRoute.coordinate(atOffset: offset)
        else { return nil }
        let here = position.location.coordinate
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
