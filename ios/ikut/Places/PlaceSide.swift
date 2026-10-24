import CoreLocation
import Foundation

/// A place the route passes, with where it is along the route and which carriageway it serves. Port of `along` in
/// `tools/osm/places.mjs`.
struct PlaceAlong: Sendable, Identifiable {
    enum Kind: Sendable, Equatable {
        case services, restArea, fuel
    }

    /// Left or right of the route line at the place's nearest point; `both` for an overhead-bridge R&R whose
    /// outline spans the road (Sungai Buloh), which serves both directions.
    enum Side: Sendable, Equatable {
        case left, right, both
    }

    /// Which carriageway of the route the place's slip roads join.
    enum Carriageway: Sendable, Equatable {
        case ours, opposite
    }

    var id: String
    var kind: Kind
    var name: String?
    var coordinate: CLLocationCoordinate2D
    var ring: [CLLocationCoordinate2D]?
    var facilities: Set<PlaceFacility>
    var brands: [String]
    /// Meters along the route at the place's nearest point.
    var offset: CLLocationDistance
    /// Meters from the route line, whole.
    var distance: Int
    var side: Side
    /// From the slip roads, when any reaches the route's road; the side of the line decides `ours`, this is
    /// reported beside it.
    var carriageway: Carriageway?
    /// The place serves our direction: Malaysia drives on the left, so it sits to the left of the route (or spans it).
    var ours: Bool
    /// Where to route to: the gate on our slip road when one is mapped, else the place itself.
    var entrance: CLLocationCoordinate2D
    var slipEntrance: Bool
    /// Where the stop sits on the route: where our slip road leaves it, else the place projected.
    var routeOffset: CLLocationDistance
}

enum PlaceSide {
    /// Left or right of the route at the point's nearest spot, with the offset and distance. Driving on the left,
    /// our side is the left.
    static func sideOf(_ point: CLLocationCoordinate2D, _ line: RouteLine) -> (offset: Double, distance: Double, side: PlaceAlong.Side)? {
        guard let p = line.project(point), line.segmentCount > 0 else { return nil }
        let i = p.segmentIndex
        let cosLat = cos(point.latitude * .pi / 180)
        let a = RouteLine.localMeters(of: line.coordinates[i], from: point, cosLat: cosLat)
        let b = RouteLine.localMeters(of: line.coordinates[i + 1], from: point, cosLat: cosLat)
        // Cross product of the segment direction and the vector to the point (at the origin): positive = left.
        let cross = (b.x - a.x) * (0 - a.y) - (b.y - a.y) * (0 - a.x)
        return (p.offset, p.distance, cross > 0 ? .left : .right)
    }

    /// An outline with corners more than `span` meters to each side of the route line spans the road.
    static func straddles(_ ring: [CLLocationCoordinate2D], _ line: RouteLine) -> Bool {
        var left = false, right = false
        for p in ring {
            guard let s = sideOf(p, line), s.distance >= PlaceRules.span, s.distance <= PlaceRules.reach else { continue }
            if s.side == .left { left = true } else { right = true }
        }
        return left && right
    }

    /// Smallest difference between two bearings, 0...180.
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        let d = abs(((a - b).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360))
        return d > 180 ? 360 - d : d
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from north.
    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        dLon *= .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Route bearing at `offset`, over `bearingSpan` either side.
    static func routeBearing(_ line: RouteLine, at offset: Double) -> Double {
        let a = line.coordinate(atOffset: max(0, offset - PlaceRules.bearingSpan))!
        let b = line.coordinate(atOffset: min(line.length, offset + PlaceRules.bearingSpan))!
        return bearing(a, b)
    }

    /// `ours` or `opposite` for one slip road junction, nil when it is not on the route's road.
    static func junctionSide(_ s: PlaceSlipRoad, _ line: RouteLine) -> PlaceAlong.Carriageway? {
        guard let p = line.project(s.junction), p.distance <= PlaceRules.onRoad else { return nil }
        let d = angleBetween(s.bearing, routeBearing(line, at: p.offset))
        if d <= PlaceRules.sameDirection { return .ours }
        if d >= PlaceRules.oppositeDirection { return .opposite }
        return nil
    }

    /// Which carriageway of the route a place serves, from its slip roads: the side of the nearest entry (the
    /// shortest road from the motorway into the place), else of the nearest exit; nil when no slip road reaches the
    /// route's road. Nearest, not every one: two-way service roads behind an R&R often link both sides.
    static func carriageway(entries: [PlaceSlipRoad], exits: [PlaceSlipRoad], _ line: RouteLine) -> PlaceAlong.Carriageway? {
        for list in [entries, exits] {
            let sided = list.compactMap { s in junctionSide(s, line).map { (s, $0) } }
                .sorted { $0.0.meters < $1.0.meters }
            if let first = sided.first { return first.1 }
        }
        return nil
    }

    /// Places within `reach` of the route, in route order, each with its offset, side, carriageway from the slip
    /// roads, the entrance to route to and `ours`. The side of the line decides. Only places inside the route's
    /// bounding box (plus `reach`) are projected, so the whole country's file costs little.
    static func along(sites: [PlaceSite], fuel: [FuelStation], line: RouteLine,
                      reach: Double = PlaceRules.reach) -> [PlaceAlong] {
        guard let box = Box(line.coordinates, margin: reach + 100) else { return [] }
        var out: [PlaceAlong] = []
        for site in sites where box.contains(site.coordinate) {
            out.append(contentsOf: row(
                id: site.id, kind: site.kind == .services ? .services : .restArea, name: site.name,
                coordinate: site.coordinate, ring: site.ring, facilities: site.facilities, brands: site.brands,
                entries: site.entries, exits: site.exits, line: line, reach: reach))
        }
        for pump in fuel where box.contains(pump.coordinate) {
            out.append(contentsOf: row(
                id: pump.id, kind: .fuel, name: pump.name, coordinate: pump.coordinate, ring: nil,
                facilities: [.fuel], brands: pump.name.map { [$0] } ?? [],
                entries: [], exits: [], line: line, reach: reach))
        }
        return out.sorted { $0.routeOffset < $1.routeOffset }
    }

    private static func row(
        id: String, kind: PlaceAlong.Kind, name: String?, coordinate: CLLocationCoordinate2D,
        ring: [CLLocationCoordinate2D]?, facilities: Set<PlaceFacility>, brands: [String],
        entries: [PlaceSlipRoad], exits: [PlaceSlipRoad], line: RouteLine, reach: Double
    ) -> [PlaceAlong] {
        guard var s = sideOf(coordinate, line), s.distance <= reach else { return [] }
        // An overhead-bridge R&R (Sungai Buloh) spans the road and serves both directions.
        if let ring, straddles(ring, line) { s.side = .both }
        let cw = carriageway(entries: entries, exits: exits, line)
        // Our way in: an entry on our carriageway before the place (the diverge), the nearest one.
        let ourEntry = entries
            .filter { junctionSide($0, line) == .ours }
            .compactMap { e in line.project(e.junction).map { (e, $0.offset) } }
            .filter { $0.1 <= s.offset + PlaceRules.entrySlack }
            .max { $0.1 < $1.1 }
        let ours = s.side == .left || s.side == .both
        return [PlaceAlong(
            id: id, kind: kind, name: name, coordinate: coordinate, ring: ring, facilities: facilities, brands: brands,
            offset: s.offset, distance: Int(s.distance.rounded()), side: s.side, carriageway: cw, ours: ours,
            entrance: ourEntry?.0.gate ?? coordinate, slipEntrance: ourEntry != nil,
            routeOffset: ourEntry?.1 ?? s.offset)]
    }

    /// The route's bounding box, grown by a margin in meters.
    private struct Box {
        var south, north, west, east: Double
        init?(_ points: [CLLocationCoordinate2D], margin: Double) {
            guard let first = points.first else { return nil }
            var s = first.latitude, n = first.latitude, w = first.longitude, e = first.longitude
            for p in points {
                s = min(s, p.latitude); n = max(n, p.latitude); w = min(w, p.longitude); e = max(e, p.longitude)
            }
            let dLat = margin / 111_000
            let dLon = margin / (111_000 * max(0.1, cos(max(abs(s), abs(n)) * .pi / 180)))
            south = s - dLat; north = n + dLat; west = w - dLon; east = e + dLon
        }
        func contains(_ p: CLLocationCoordinate2D) -> Bool {
            p.latitude >= south && p.latitude <= north && p.longitude >= west && p.longitude <= east
        }
    }
}
