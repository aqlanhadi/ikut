import FirebaseFirestore
import Foundation
import MapKit

/// One ended trip drawn on Home's map: its main route (thinned) and destination.
struct PastTripRoute: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var destinationName: String
    var destinationLatitude: Double
    var destinationLongitude: Double
    /// Thinned main route, [lat, lng] pairs; may be empty if the trip had no route.
    var points: [[Double]]

    var destination: CLLocationCoordinate2D { .init(latitude: destinationLatitude, longitude: destinationLongitude) }
    var coordinates: [CLLocationCoordinate2D] { points.compactMap { $0.count == 2 ? .init(latitude: $0[0], longitude: $0[1]) : nil } }
    var start: CLLocationCoordinate2D? { coordinates.first }
}

/// How a region sits in the map MapKit frames (D118). MapKit fits a region inside the map less its one bottom padding:
/// the screen's width by the screen's height less the padding, from the screen's top edge. It zooms until BOTH spans fit,
/// so for a route wider than the view is (long and thin, east to west) the longitude binds and the view shows more
/// latitude than the region asked for; a vertical shift worked out from the requested latitude then lands the route off
/// centre in the strip. `aspect` (that width over that height) tells which span binds.
enum MapFit {
    /// An iPhone 17 Pro's width.
    static let referenceWidth: CGFloat = 402
    /// The map's width over its framed height on the reference phone at the default text size.
    static var referenceAspect: Double { aspect(width: referenceWidth, height: SheetStops.referenceScreen, padding: LobbySheet.defaultMapPadding) }

    /// Width over height of what MapKit frames, from the screen's size and the one bottom padding. The reference
    /// aspect for a map not measured yet.
    static func aspect(width: CGFloat, height: CGFloat, padding: CGFloat) -> Double {
        let framed = height - padding
        guard width > 0, framed > 1 else { return referenceAspect }
        return Double(width / framed)
    }

    /// Degrees of latitude the view really spans for a region of `latitudeDelta` by `longitudeDelta` at `latitude`:
    /// the larger of what was asked and what the longitude needs (a degree of longitude is `cos(latitude)` as long as a
    /// degree of latitude).
    static func viewLatitudeSpan(latitudeDelta: Double, longitudeDelta: Double, latitude: Double, aspect: Double) -> Double {
        max(latitudeDelta, longitudeDelta * cos(latitude * .pi / 180) / max(aspect, 0.05))
    }
}

/// Pure helpers for Home's past-trips map.
enum PastTripsMapLogic {
    /// At most this many past routes are drawn (newest first).
    static let maxTrips = 12
    /// Each drawn route keeps at most this many points; enough for a city-to-city overview.
    static let maxPoints = 250

    /// Ended trips to draw, newest first, capped at `maxTrips`.
    static func tripsToDraw(_ entries: [PastTrips.Entry], limit: Int = maxTrips) -> [PastTrips.Entry] {
        Array(entries.filter { $0.endedAt != nil }.prefix(limit))
    }

    /// Keeps every n-th point so at most `maxPoints` remain, always keeping the first and last.
    static func thin(_ coords: [CLLocationCoordinate2D], maxPoints: Int = maxPoints) -> [CLLocationCoordinate2D] {
        guard maxPoints >= 2, coords.count > maxPoints else { return coords }
        let step = Double(coords.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { coords[Int((Double($0) * step).rounded())] }
    }

    static func route(id: String, name: String, destinationName: String, destination: CLLocationCoordinate2D,
                      encodedRoute: String) -> PastTripRoute {
        let line = thin(Polyline.decode(encodedRoute))
        return PastTripRoute(id: id, name: name, destinationName: destinationName,
                             destinationLatitude: destination.latitude, destinationLongitude: destination.longitude,
                             points: line.map { [$0.latitude, $0.longitude] })
    }

    /// A region showing every route and destination with some margin, with the content centred in
    /// the part of the map between `topObscured` and `bottomObscured` (fractions of its height, e.g.
    /// the status bar and the sheet; together clamped to 0.7; a negative bottom lets the band reach below the
    /// frame). Nil when there is nothing to show.
    static func region(fitting routes: [PastTripRoute], padding: Double = 1.1, minSpan: Double = 0.05,
                       bottomObscured: Double = 0, topObscured: Double = 0,
                       aspect: Double = MapFit.referenceAspect) -> MKCoordinateRegion? {
        let all = routes.flatMap { $0.coordinates + [$0.destination] }
            .filter { CLLocationCoordinate2DIsValid($0) }
        guard let first = all.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in all {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        var bottom = max(bottomObscured, -1), top = max(topObscured, 0)
        if bottom + top > 0.7 { let scale = 0.7 / (bottom + top); bottom *= scale; top *= scale }
        let visibleLat = max((maxLat - minLat) * padding, minSpan)
        let latDelta = min(visibleLat / (1 - bottom - top), 170)
        let lngDelta = min(max((maxLng - minLng) * padding, minSpan), 350)
        // Shift the map's centre so the content sits centred in the visible band, by the latitude the view really spans:
        // a wide route binds on longitude and the view shows more than `latDelta`.
        let midLat = (minLat + maxLat) / 2
        let viewLat = MapFit.viewLatitudeSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta, latitude: midLat, aspect: aspect)
        let centerLat = midLat + viewLat * (top - bottom) / 2
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: max(-85, min(85, centerLat)), longitude: (minLng + maxLng) / 2),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lngDelta))
    }
}

/// Loads the routes of the newest ended trips for Home's map. Routes of ended trips never change,
/// so each is read once: from the recap cache when the recap was opened on this phone, otherwise
/// from the trip doc alone (no subcollections), then kept in a small file cache.
enum PastTripsMapService {
    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("home-routes.json")
    }

    static func cachedRoutes() -> [String: PastTripRoute] {
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([PastTripRoute].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private static func save(_ routes: [PastTripRoute]) {
        guard let url = cacheURL, let data = try? JSONEncoder().encode(routes) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Keeps `route` for Home, as the trip is left: once out of it, this phone can no longer read the trip.
    static func remember(_ route: PastTripRoute) {
        var cache = cachedRoutes()
        cache[route.id] = route
        save(Array(cache.values))
    }

    /// Drops one trip's route from the file cache (Delete from history).
    static func forget(tripId: String) {
        var cache = cachedRoutes()
        guard cache.removeValue(forKey: tripId) != nil else { return }
        save(Array(cache.values))
    }

    /// What to write to the file cache after a load: the routes Home still lists, or nothing when the load
    /// was for one trip outside them (`keeping: false`), which must not shrink the 12-trip cache.
    static func routesToKeep(_ entries: [PastTrips.Entry], cache: [String: PastTripRoute], keeping: Bool) -> [PastTripRoute]? {
        keeping ? entries.compactMap { cache[$0.id] } : nil
    }

    /// Routes for `entries` in the same order; trips that can't be read are skipped.
    /// `keeping: false` is for a single trip outside the newest 12 (picked from the list): the file cache,
    /// which holds only what Home draws, is left as it is.
    @MainActor static func load(_ entries: [PastTrips.Entry], keeping: Bool = true, db: Firestore = Firestore.firestore()) async -> [PastTripRoute] {
        var cache = cachedRoutes()
        var result: [PastTripRoute] = []
        for entry in entries {
            if let hit = cache[entry.id] {
                result.append(hit)
            } else if !PickedTripLogic.readsServer(entry) {
                // Left early: only a route cached on Leave; the trip is members-only.
                continue
            } else if let recap = RecapService.cached(tripId: entry.id) {
                let r = PastTripsMapLogic.route(id: entry.id, name: recap.name, destinationName: recap.destinationName,
                                                destination: recap.destination, encodedRoute: recap.route)
                cache[entry.id] = r
                result.append(r)
            } else if let trip = try? await db.document(FirestorePaths.trip(entry.id)).getDocument(as: Trip.self) {
                let d = trip.destination.coordinate
                let r = PastTripsMapLogic.route(id: entry.id, name: trip.name, destinationName: trip.destination.name,
                                                destination: .init(latitude: d.latitude, longitude: d.longitude),
                                                encodedRoute: trip.route)
                cache[entry.id] = r
                result.append(r)
            }
        }
        // Keep only what Home still lists, and never a trip deleted from history while this was loading.
        let removed = HistoryDelete.removedIds
        if let toSave = routesToKeep(entries.filter { !removed.contains($0.id) }, cache: cache, keeping: keeping) { save(toSave) }
        return result.filter { !removed.contains($0.id) }
    }
}
