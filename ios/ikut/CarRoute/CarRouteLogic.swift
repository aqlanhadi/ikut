import CoreLocation
import Foundation

/// What a car's route doc fields should become. Maps one-to-one onto the three keys the rules let
/// the tracker write (`route`, `mergeOffset`, `state`).
struct CarRoutePlan: Sendable, Equatable {
    /// Encoded polyline (precision 5); nil when the car is already on the main route.
    var route: String?
    /// Meters along the main route where the car joins it.
    var mergeOffset: Double?
    var state: CarState
    /// How the merge was found; informational.
    var kind: Kind

    enum Kind: Sendable, Equatable {
        /// Within `nearMainThreshold` of the main route: no own route.
        case onMainRoute
        /// The own route ends on the main route; `mergeOffset` is where.
        case merges
        /// The own route never comes within the merge tolerance of the main route; see `CarRouteLogic.makePlan`.
        case neverMerges
    }
}

/// Pure decisions for per-car routes: no MapKit, no Firestore.
enum CarRouteLogic {
    /// A car this close to the main route needs no route of its own.
    ///
    /// 150 m: a few times the worst normal GPS error (~30 m in a city) plus the lateral spread of
    /// a dual carriageway, a slip road or a petrol-station forecourt, so cars driving the convoy
    /// route are never spuriously sent off to compute their own. Small enough that a car on a
    /// different road (a parallel trunk road is typically 300 m or more away) gets a real route.
    static let nearMainThreshold: CLLocationDistance = 150

    /// Tolerance handed to `RouteLine.mergeOffset(of:)`. It must equal `RouteLine.mergeOffset`'s
    /// default, because `PositionBuilder` recomputes the merge from the stored route with that default
    /// and the two have to agree on where the car joins.
    static let mergeTolerance: CLLocationDistance = 50

    /// How much of the own route is kept past the merge point. The shared stretch is already stored
    /// as the main route, so only a margin is kept: enough that `mergeOffset(of:)`, which walks back
    /// from the route's end, finds the same boundary, and that a fix a little past the merge still
    /// projects onto the own route.
    static let tailPastMerge: CLLocationDistance = 500

    /// Largest encoded route we store (characters). The rules only require `route is string`, so the
    /// real limit is Firestore's 1 MiB document size; 100,000 characters leaves a wide margin.
    static let maxEncodedLength = 100_000

    static func needsOwnRoute(distanceFromMain: CLLocationDistance) -> Bool {
        distanceFromMain > nearMainThreshold
    }

    /// Plan for a car at `location`, or nil when it needs its own route (`computed` is then required).
    static func planIfOnMain(location: CLLocationCoordinate2D, main: RouteLine) -> CarRoutePlan? {
        guard let p = main.project(location), !needsOwnRoute(distanceFromMain: p.distance) else { return nil }
        return CarRoutePlan(route: nil, mergeOffset: p.offset, state: .convoy, kind: .onMainRoute)
    }

    /// Builds the plan from a computed route (start to destination).
    ///
    /// 1. Finds where the route joins `main` for good (`RouteLine.mergeOffset`).
    /// 2. Cuts it `tailPastMerge` past that point and simplifies it to fit `maxEncodedLength`.
    /// 3. Recomputes the merge on the decoded, stored route, so `mergeOffset` is exactly what
    ///    `PositionBuilder` will derive from the stored polyline.
    ///
    /// If the route never joins (it ends more than `mergeTolerance` from the main route, e.g. the
    /// destination snaps to a different road), the whole route is stored with `state` = `.joining`,
    /// and `mergeOffset` is the main-route offset nearest to the route's end (the destination
    /// approach). `PositionBuilder` then never sets `convoyOffset` for this car, so the car is
    /// absent from convoy ordering, and `CarRouteService.handle` marks it `.convoy` when it is within
    /// `nearMainThreshold` of the main route or reaches the end of its own route.
    static func makePlan(computed: [CLLocationCoordinate2D], main: RouteLine, toMeetingPoint: Bool = false) -> CarRoutePlan? {
        guard computed.count >= 2, !main.isEmpty else { return nil }
        let full = RouteLine(computed)
        // On the way to a meeting point the car joins only on arrival, at the main route's start; the whole route is kept.
        if toMeetingPoint, let meet = main.meetingMerge(of: full, tolerance: mergeTolerance) {
            let simplified = RouteSimplifier.simplify(computed, maxEncodedLength: maxEncodedLength)
            return CarRoutePlan(route: Polyline.encode(simplified), mergeOffset: meet.mainOffset, state: .joining, kind: .merges)
        }
        guard let merge = main.mergeOffset(of: full, tolerance: mergeTolerance) else {
            let simplified = RouteSimplifier.simplify(computed, maxEncodedLength: maxEncodedLength)
            let end = computed[computed.count - 1]
            return CarRoutePlan(
                route: Polyline.encode(simplified), mergeOffset: main.project(end)?.offset ?? main.length,
                state: .joining, kind: .neverMerges)
        }
        let cut = truncate(full, atOffset: merge.otherOffset + tailPastMerge)
        let simplified = RouteSimplifier.simplify(cut, maxEncodedLength: maxEncodedLength)
        let encoded = Polyline.encode(simplified)
        let stored = RouteLine(Polyline.decode(encoded))
        let mainOffset = main.mergeOffset(of: stored, tolerance: mergeTolerance)?.mainOffset ?? merge.mainOffset
        return CarRoutePlan(route: encoded, mergeOffset: mainOffset, state: .joining, kind: .merges)
    }

    /// The route up to `offset` meters, ending exactly at that offset. Unchanged when `offset` is past the end.
    static func truncate(_ line: RouteLine, atOffset offset: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard offset < line.length, let end = line.coordinate(atOffset: offset) else { return line.coordinates }
        var out: [CLLocationCoordinate2D] = []
        for (i, c) in line.coordinates.enumerated() where line.cumulative[i] < offset {
            out.append(c)
        }
        out.append(end)
        return out
    }

    /// True once the car's offset along its own route reaches the merge offset along that route.
    /// Mirrors `PositionBuilder`, which uses `>=`.
    static func hasMerged(ownOffset: Double, ownMergeOffset: Double) -> Bool {
        ownOffset >= ownMergeOffset
    }
}

/// Decides when a car has left the route it should be on and needs a new one. Pure value type.
///
/// Fires when the car has been farther than `distance` from the reference route for `fixes`
/// consecutive fixes, or for `duration` seconds without a fix back on it, and at least
/// `minInterval` has passed since the last recompute. While throttled the off-route run keeps
/// counting, so a car still off-route fires as soon as the throttle lapses.
///
/// Defaults: 100 m is well beyond GPS noise, so a car that merely drifts across lanes does not
/// trigger; 5 fixes (about 5 s at 1 Hz) or 15 s confirms a real turn-off, while ignoring a tunnel or
/// an urban-canyon jump; one recompute per minute caps MKDirections traffic (Apple rate-limits it).
struct OffRouteDetector: Sendable, Equatable {
    var distance: CLLocationDistance = 100
    var fixes = 5
    var duration: TimeInterval = 15
    var minInterval: TimeInterval = 60

    private(set) var offCount = 0
    private(set) var offSince: Date?
    private(set) var lastRecompute: Date?

    init(distance: CLLocationDistance = 100, fixes: Int = 5, duration: TimeInterval = 15, minInterval: TimeInterval = 60) {
        self.distance = distance
        self.fixes = fixes
        self.duration = duration
        self.minInterval = minInterval
    }

    /// Feeds one fix (its distance from the reference route and its time). True when to recompute.
    /// Call `markRecomputed` when you start one.
    mutating func observe(distanceFromRoute: CLLocationDistance, at time: Date) -> Bool {
        guard distanceFromRoute > distance else {
            offCount = 0
            offSince = nil
            return false
        }
        offCount += 1
        if offSince == nil { offSince = time }
        let confirmed = offCount >= fixes || time.timeIntervalSince(offSince ?? time) >= duration
        guard confirmed else { return false }
        if let last = lastRecompute, time.timeIntervalSince(last) < minInterval { return false }
        return true
    }

    /// Records a recompute attempt (successful or not) and restarts the off-route run.
    mutating func markRecomputed(at time: Date) {
        lastRecompute = time
        offCount = 0
        offSince = nil
    }

    /// Restarts the off-route run without touching the throttle (e.g. after merging).
    mutating func resetRun() {
        offCount = 0
        offSince = nil
    }
}

/// Douglas–Peucker line simplification.
enum RouteSimplifier {
    /// Keeps the first and last points and every point that deviates more than `tolerance` meters
    /// from the simplified line. Iterative, so very long routes cannot overflow the stack.
    static func simplify(_ points: [CLLocationCoordinate2D], tolerance: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard points.count > 2, tolerance > 0 else { return points }
        let c = cos(points[0].latitude * .pi / 180)
        let xy: [(Double, Double)] = points.map {
            let d = RouteLine.localMeters(of: $0, from: points[0], cosLat: c)
            return (d.x, d.y)
        }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (lo, hi) = stack.popLast() {
            guard hi - lo > 1 else { continue }
            var maxD = 0.0
            var index = lo
            for i in (lo + 1)..<hi {
                let d = segmentDistance(xy[i], xy[lo], xy[hi])
                if d > maxD { maxD = d; index = i }
            }
            if maxD > tolerance {
                keep[index] = true
                stack.append((lo, index))
                stack.append((index, hi))
            }
        }
        return zip(points, keep).compactMap { $1 ? $0 : nil }
    }

    /// Simplifies only as much as needed: the route is returned untouched if it already encodes to at
    /// most `maxEncodedLength` characters; otherwise tolerance doubles from 5 m (to at most 160 m,
    /// then keeps doubling) until it fits. Stays well under the 50 m merge tolerance in practice.
    static func simplify(_ points: [CLLocationCoordinate2D], maxEncodedLength: Int) -> [CLLocationCoordinate2D] {
        var result = points
        var tolerance = 5.0
        while Polyline.encode(result).utf8.count > maxEncodedLength, result.count > 2, tolerance < 1e6 {
            result = simplify(points, tolerance: tolerance)
            tolerance *= 2
        }
        return result
    }

    private static func segmentDistance(_ p: (Double, Double), _ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let dx = b.0 - a.0
        let dy = b.1 - a.1
        let len2 = dx * dx + dy * dy
        let t = len2 > 0 ? min(1, max(0, ((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2)) : 0
        let ex = p.0 - (a.0 + t * dx)
        let ey = p.1 - (a.1 + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }
}
