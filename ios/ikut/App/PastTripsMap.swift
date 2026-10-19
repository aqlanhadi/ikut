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
    /// the status bar and the sheet; together clamped to 0.7). Nil when there is nothing to show.
    static func region(fitting routes: [PastTripRoute], padding: Double = 1.1, minSpan: Double = 0.05,
                       bottomObscured: Double = 0, topObscured: Double = 0) -> MKCoordinateRegion? {
        let all = routes.flatMap { $0.coordinates + [$0.destination] }
            .filter { CLLocationCoordinate2DIsValid($0) }
        guard let first = all.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in all {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        var bottom = max(bottomObscured, 0), top = max(topObscured, 0)
        if bottom + top > 0.7 { let scale = 0.7 / (bottom + top); bottom *= scale; top *= scale }
        let visibleLat = max((maxLat - minLat) * padding, minSpan)
        let latDelta = min(visibleLat / (1 - bottom - top), 170)
        let lngDelta = min(max((maxLng - minLng) * padding, minSpan), 350)
        // Shift the map's centre so the content sits centred in the visible band.
        let centerLat = (minLat + maxLat) / 2 + latDelta * (top - bottom) / 2
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

    /// Routes for `entries` in the same order; trips that can't be read are skipped.
    @MainActor static func load(_ entries: [PastTrips.Entry], db: Firestore = Firestore.firestore()) async -> [PastTripRoute] {
        var cache = cachedRoutes()
        var result: [PastTripRoute] = []
        for entry in entries {
            if let hit = cache[entry.id] {
                result.append(hit)
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
        // Keep only what Home still lists.
        save(entries.compactMap { cache[$0.id] })
        return result
    }
}
