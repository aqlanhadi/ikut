import CoreLocation

/// A route polyline with precomputed cumulative distances, for projecting positions onto it.
///
/// Distance model: segment lengths are great-circle (haversine) on a sphere of radius
/// `earthRadius` (6,371,008.8 m), summed into per-vertex offsets. Projection onto a segment uses a
/// local equirectangular plane centred on the segment start, scaled by the segment's mid latitude.
/// That is accurate to well under a meter for segments up to a few km; the snapped offset is
/// `cumulative[i] + t * haversineLength(i)` so offsets stay consistent with `length`.
struct RouteLine: Sendable {
    static let earthRadius: CLLocationDistance = 6_371_008.8

    /// Where a projected point landed relative to the ends of the route.
    enum Clamp: Sendable {
        case none
        /// The point is behind the first vertex; `offset` is 0.
        case beforeStart
        /// The point is beyond the last vertex; `offset` is `length`.
        case afterEnd
    }

    struct Projection: Sendable {
        /// Meters along the route from its first vertex.
        var offset: CLLocationDistance
        /// Perpendicular (or end-point, when clamped) distance from the route in meters.
        var distance: CLLocationDistance
        /// Index of the segment (vertex `i` to `i + 1`) the point snapped to. 0 for a single-point route.
        var segmentIndex: Int
        var coordinate: CLLocationCoordinate2D
        var clamp: Clamp
    }

    let coordinates: [CLLocationCoordinate2D]
    /// Offset in meters of each vertex; same count as `coordinates`.
    let cumulative: [CLLocationDistance]
    var length: CLLocationDistance { cumulative.last ?? 0 }
    var isEmpty: Bool { coordinates.isEmpty }
    var segmentCount: Int { max(0, coordinates.count - 1) }

    private let segLength: [Double]
    private let cosLat: [Double]
    private let bx: [Double]
    private let by: [Double]

    init(_ coordinates: [CLLocationCoordinate2D]) {
        self.coordinates = coordinates
        var cumulative: [Double] = []
        var segLength: [Double] = []
        var cosLat: [Double] = []
        var bx: [Double] = []
        var by: [Double] = []
        cumulative.reserveCapacity(coordinates.count)
        if !coordinates.isEmpty { cumulative.append(0) }
        if coordinates.count > 1 {
            for i in 0..<(coordinates.count - 1) {
                let a = coordinates[i]
                let b = coordinates[i + 1]
                let len = Self.haversine(a, b)
                segLength.append(len)
                cumulative.append(cumulative[i] + len)
                let c = cos((a.latitude + b.latitude) / 2 * .pi / 180)
                cosLat.append(c)
                let d = Self.localMeters(of: b, from: a, cosLat: c)
                bx.append(d.x)
                by.append(d.y)
            }
        }
        self.cumulative = cumulative
        self.segLength = segLength
        self.cosLat = cosLat
        self.bx = bx
        self.by = by
    }

    /// Great-circle distance in meters.
    static func haversine(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = wrapLongitude(b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Meters east (x) and north (y) of `origin` on the flat plane used for projection; `cosLat` is the
    /// cosine of the latitude the plane is scaled at.
    static func localMeters(
        of p: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D, cosLat: Double
    ) -> (x: Double, y: Double) {
        (wrapLongitude(p.longitude - origin.longitude) * .pi / 180 * cosLat * earthRadius,
         (p.latitude - origin.latitude) * .pi / 180 * earthRadius)
    }

    private static func wrapLongitude(_ d: Double) -> Double {
        if d > 180 { return d - 360 }
        if d < -180 { return d + 360 }
        return d
    }

    // MARK: Projection

    private struct Candidate {
        var distance: Double
        var segment: Int
        var rawT: Double
        var t: Double
    }

    private func evaluate(_ p: CLLocationCoordinate2D, segment i: Int) -> Candidate {
        let a = coordinates[i]
        let c = cosLat[i]
        let (px, py) = Self.localMeters(of: p, from: a, cosLat: c)
        let len2 = bx[i] * bx[i] + by[i] * by[i]
        let raw = len2 > 0 ? (px * bx[i] + py * by[i]) / len2 : 0
        let t = min(1, max(0, raw))
        let dx = px - t * bx[i]
        let dy = py - t * by[i]
        return Candidate(distance: (dx * dx + dy * dy).squareRoot(), segment: i, rawT: raw, t: t)
    }

    /// Candidates within this many meters of the best distance count as ties.
    private static let tieDistance: CLLocationDistance = 5

    private func best(of p: CLLocationCoordinate2D, in range: ClosedRange<Int>, hint: Int?) -> Candidate {
        var minD = Double.infinity
        var chosen: Candidate?
        for i in range {
            let c = evaluate(p, segment: i)
            minD = min(minD, c.distance)
            guard c.distance <= minD + Self.tieDistance else { continue }
            guard let current = chosen, current.distance <= minD + Self.tieDistance else { chosen = c; continue }
            if let hint {
                if abs(c.segment - hint) < abs(current.segment - hint) { chosen = c }
            } else if c.distance < current.distance {
                chosen = c
            }
        }
        return chosen!
    }

    /// Projects `point` onto the route. Returns nil only for an empty route.
    ///
    /// Without `hint` every segment is scanned (O(n)). With `hint` (the last known segment index)
    /// only segments within `window` of it are scanned first; if the best distance there exceeds
    /// `fallbackDistance`, the whole route is scanned instead. When several segments are within 5 m
    /// of the best distance (route doubling back or looping), the one closest to the hint wins, or
    /// the nearest by distance (first on exact ties) when no hint is given.
    func project(
        _ point: CLLocationCoordinate2D,
        hint: Int? = nil,
        window: Int = 24,
        fallbackDistance: CLLocationDistance = 100
    ) -> Projection? {
        guard let first = coordinates.first else { return nil }
        guard segmentCount > 0 else {
            return Projection(
                offset: 0, distance: Self.haversine(first, point), segmentIndex: 0,
                coordinate: first, clamp: .none
            )
        }
        let last = segmentCount - 1
        var found: Candidate
        if let hint {
            let h = min(max(hint, 0), last)
            found = best(of: point, in: max(0, h - window)...min(last, h + window), hint: h)
            if found.distance > fallbackDistance {
                found = best(of: point, in: 0...last, hint: h)
            }
        } else {
            found = best(of: point, in: 0...last, hint: nil)
        }
        return makeProjection(found)
    }

    private func makeProjection(_ c: Candidate) -> Projection {
        let a = coordinates[c.segment]
        let b = coordinates[c.segment + 1]
        let snapped = CLLocationCoordinate2D(
            latitude: a.latitude + c.t * (b.latitude - a.latitude),
            longitude: a.longitude + c.t * Self.wrapLongitude(b.longitude - a.longitude)
        )
        var clamp = Clamp.none
        if c.segment == 0 && c.rawT <= 0 { clamp = .beforeStart }
        if c.segment == segmentCount - 1 && c.rawT >= 1 { clamp = .afterEnd }
        return Projection(
            offset: cumulative[c.segment] + c.t * segLength[c.segment],
            distance: c.distance, segmentIndex: c.segment, coordinate: snapped, clamp: clamp
        )
    }

    // MARK: Offsets

    /// The point `offset` meters along the route, clamped to the route's ends. Nil for an empty route.
    func coordinate(atOffset offset: CLLocationDistance) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first else { return nil }
        guard segmentCount > 0, offset > 0 else { return first }
        if offset >= length { return coordinates[coordinates.count - 1] }
        // Last vertex with cumulative <= offset.
        var lo = 0
        var hi = coordinates.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= offset { lo = mid } else { hi = mid }
        }
        let len = segLength[lo]
        let t = len > 0 ? (offset - cumulative[lo]) / len : 0
        let a = coordinates[lo]
        let b = coordinates[lo + 1]
        return CLLocationCoordinate2D(
            latitude: a.latitude + t * (b.latitude - a.latitude),
            longitude: a.longitude + t * Self.wrapLongitude(b.longitude - a.longitude)
        )
    }

    /// Signed route distance from one offset to another (positive when `to` is further along).
    /// Both are clamped to `0...length` first.
    func distance(fromOffset from: CLLocationDistance, toOffset to: CLLocationDistance) -> CLLocationDistance {
        min(max(to, 0), length) - min(max(from, 0), length)
    }

    // MARK: Merging

    /// Where a car's route to a meeting point joins this route: the very end of `other`, when `other` ends at this
    /// route's start (the main route starts at the meeting point). Unlike `mergeOffset(of:)` it ignores a stretch
    /// before the end that runs within `tolerance` of this route, such as the other carriageway on the way in, so
    /// a car is not counted as joined until it reaches the meeting point. Nil when `other` doesn't end there.
    func meetingMerge(
        of other: RouteLine, tolerance: CLLocationDistance = 50
    ) -> (otherOffset: CLLocationDistance, mainOffset: CLLocationDistance)? {
        guard let start = coordinates.first, let end = other.coordinates.last,
              RouteLine.haversine(start, end) <= tolerance else { return nil }
        return (other.length, 0)
    }

    /// Where `other` joins this route for good: the first point along `other` from which it stays
    /// within `tolerance` of this route until its end. `other` is sampled every ~25 m, walking back
    /// from its end, then the boundary is bisected to about a meter. Returns nil if `other` ends
    /// farther than `tolerance` from this route (never joins, or touches then leaves).
    func mergeOffset(
        of other: RouteLine,
        tolerance: CLLocationDistance = 50
    ) -> (otherOffset: CLLocationDistance, mainOffset: CLLocationDistance)? {
        guard !isEmpty, let end = other.coordinates.last,
              var onProjection = project(end), onProjection.distance <= tolerance
        else { return nil }
        var onOffset = other.length
        let step = 25.0
        var hint = onProjection.segmentIndex
        var offOffset: Double?
        var s = other.length - step
        while s > 0 {
            guard let c = other.coordinate(atOffset: s), let p = project(c, hint: hint, fallbackDistance: tolerance * 2)
            else { return nil }
            if p.distance > tolerance { offOffset = s; break }
            onOffset = s
            onProjection = p
            hint = p.segmentIndex
            s -= step
        }
        guard var off = offOffset else {
            let p = other.coordinates.first.flatMap { project($0, hint: hint, fallbackDistance: tolerance * 2) }
            return (0, p?.offset ?? onProjection.offset)
        }
        while onOffset - off > 1 {
            let mid = (onOffset + off) / 2
            guard let c = other.coordinate(atOffset: mid), let p = project(c, hint: hint, fallbackDistance: tolerance * 2)
            else { break }
            if p.distance > tolerance {
                off = mid
            } else {
                onOffset = mid
                onProjection = p
                hint = p.segmentIndex
            }
        }
        return (onOffset, onProjection.offset)
    }
}
