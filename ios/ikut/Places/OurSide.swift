import CoreLocation
import Foundation

/// Puts a rest-area stop on the carriageway we drive. Apple's search returns "R&R Tapah" on whichever side it likes;
/// a route to the other side drives on to the next exit and turns back. Before the legs are asked for, a stop that
/// sits on a services or rest area whose twin on the other carriageway is ours moves to that twin's point (its name
/// stays what the organizer picked). Anything else is left exactly as it is.
enum OurSide {
    /// A stop this close to a site's outline (or point) is at that site.
    static let matchRadius: Double = 300
    /// Sites this close, of the same kind and name, are the two ways of one R&R.
    static let twinRadius: Double = 1_000

    /// The places file inside the app, read once.
    static let bundledSites: [PlaceSite] = (try? PlacesLoader.bundled())?.sites ?? []

    /// "Tapah Rest Area Arah Utara" and "Tapah Rest Area (Southbound)" are one name: the way of travel, the brackets
    /// and "Hentian Sebelah" (Malay for lay-by) are left out. Nil for a site with no name to compare.
    static func baseName(_ name: String?) -> String? {
        guard let name else { return nil }
        let ignored: Set<String> = [
            "arah", "sebelah", "utara", "selatan", "timur", "barat", "north", "south", "east", "west", "northbound",
            "southbound", "eastbound", "westbound", "bound", "u", "s",
        ]
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !ignored.contains($0) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// Meters from `point` to the site: 0 inside its outline, else to the nearest edge; to its point with no outline.
    static func distance(from point: CLLocationCoordinate2D, to site: PlaceSite) -> Double {
        guard let ring = site.ring, ring.count >= 3 else { return RouteLine.haversine(point, site.coordinate) }
        let cosLat = cos(point.latitude * .pi / 180)
        let pts = ring.map { RouteLine.localMeters(of: $0, from: point, cosLat: cosLat) }
        var inside = false
        var best = Double.infinity
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            if (a.y > 0) != (b.y > 0), 0 < (b.x - a.x) * (0 - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? max(0, min(1, (-a.x * dx - a.y * dy) / len2)) : 0
            best = min(best, hypot(a.x + t * dx, a.y + t * dy))
        }
        return inside ? 0 : best
    }

    /// The site the stop is at: the nearest within `matchRadius`.
    static func site(at point: CLLocationCoordinate2D, in sites: [PlaceSite]) -> PlaceSite? {
        sites.map { ($0, distance(from: point, to: $0)) }
            .filter { $0.1 <= matchRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Where the stop should be instead, or nil to leave it: it is at a site whose side is not ours on `line` and a
    /// twin of the same name is. Nil too for an overhead R&R (it serves both ways), a site or twin too far from the
    /// route to tell the side, and a stop that is not at any site.
    static func ourTwin(of point: CLLocationCoordinate2D, on line: RouteLine, sites: [PlaceSite]) -> PlaceSite? {
        guard let here = site(at: point, in: sites) else { return nil }
        let base = baseName(here.name)
        let group = sites.filter { s in
            s.id == here.id
                || (base != nil && s.kind == here.kind && baseName(s.name) == base
                    && RouteLine.haversine(s.coordinate, here.coordinate) <= twinRadius)
        }
        let rows = PlaceSide.along(sites: group, fuel: [], line: line)
        guard let mine = rows.first(where: { $0.id == here.id }), !mine.ours else { return nil }
        let twin = rows.filter { $0.ours && $0.id != here.id }
            .min { RouteLine.haversine($0.coordinate, here.coordinate) < RouteLine.haversine($1.coordinate, here.coordinate) }
        return group.first { $0.id == twin?.id }
    }

    /// The stops with each rest-area stop that sits on the wrong carriageway of `line` moved to its twin's point.
    /// `line` is the road we are on now (the trip's route); without one, nothing moves.
    static func snap(_ items: [StopDraft], on line: RouteLine?, sites: [PlaceSite] = bundledSites) -> [StopDraft] {
        guard let line, line.segmentCount > 0, !sites.isEmpty else { return items }
        return items.map { item in
            guard !item.isMeeting, StopNoteText.isRestArea(item.kind),
                  let twin = ourTwin(of: item.coordinate, on: line, sites: sites)
            else { return item }
            var moved = item
            moved.latitude = twin.coordinate.latitude
            moved.longitude = twin.coordinate.longitude
            return moved
        }
    }
}
