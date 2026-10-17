import CoreLocation
import FirebaseFirestore
import Foundation
import MapKit

/// A place found by search, before it is projected onto the route.
struct FoundPlace: Sendable, Equatable {
    var name: String
    var coordinate: CLLocationCoordinate2D

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.coordinate.latitude == b.coordinate.latitude && a.coordinate.longitude == b.coordinate.longitude
    }
}

/// A suggested stop on the route.
struct StopCandidate: Sendable, Equatable, Identifiable {
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// Meters along the main route where the place is closest to it.
    var routeOffset: Double
    /// Meters from the viewer along the route.
    var distanceAhead: Double
    /// Straight-line meters between the place and the route.
    var offRoute: Double

    var id: String { "\(name)@\(Int(routeOffset))" }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.distanceAhead == b.distanceAhead }

    var place: StopPlace {
        StopPlace(
            name: name, coordinate: GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude),
            routeOffset: routeOffset, pinnedBy: nil)
    }

    /// "18 km ahead · about 12 min".
    var whereText: String {
        let eta = ConvoyFormat.duration(distanceAhead / StopLogic.assumedSpeed).lowercased()
        let base = "\(ConvoyFormat.distance(distanceAhead)) ahead · about \(eta)"
        return offRoute > StopSuggestions.onRouteTolerance ? base + " · \(ConvoyFormat.distance(offRoute)) off route" : base
    }

    /// "On route" or the extra drive "+4 min" (there and back at about 50 km/h).
    var costText: String {
        guard offRoute > StopSuggestions.onRouteTolerance else { return "On route" }
        return "+\(max(1, Int((2 * offRoute / 13.9 / 60).rounded()))) min"
    }
}

/// Looks up places by text near a point. A protocol so tests don't hit MapKit.
protocol PlaceSearching: Sendable {
    func search(query: String, near center: CLLocationCoordinate2D, radius: CLLocationDistance) async throws -> [FoundPlace]
}

/// `MKLocalSearch` points of interest within `radius` of `center`.
struct MapKitPlaceSearcher: PlaceSearching {
    func search(query: String, near center: CLLocationCoordinate2D, radius: CLLocationDistance) async throws -> [FoundPlace] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center, latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
        request.resultTypes = .pointOfInterest
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let name = item.name, !name.isEmpty else { return nil }
            return FoundPlace(name: name, coordinate: item.placemark.coordinate)
        }
    }
}

enum StopSuggestions {
    /// Places within this many meters of the route count as on it.
    static let onRouteTolerance: CLLocationDistance = 500
    /// Farthest a suggestion may sit from the route.
    static let maxOffRoute: CLLocationDistance = 3_000
    /// Candidates start this far ahead (15 to 25 km, centred on 20 km).
    static let nearestAhead: CLLocationDistance = 15_000
    static let farthestAhead: CLLocationDistance = 25_000
    static let searchRadius: CLLocationDistance = 12_000

    /// Search text for the stop type: fuel is petrol stations, food is restaurants, rest and
    /// toilet are rest areas ("R&R" is what Malaysian highways call them).
    static func queries(for type: EventType) -> [String] {
        switch type {
        case .stopFuel: ["petrol station", "gas station"]
        case .stopFood: ["restaurant"]
        default: ["R&R", "rest area"]
        }
    }

    /// The point to search around: 20 km ahead of `offset` on the route, or the route's end if nearer.
    static func searchCenter(on route: RouteLine, from offset: CLLocationDistance) -> CLLocationCoordinate2D? {
        route.coordinate(atOffset: min(route.length, max(0, offset) + (nearestAhead + farthestAhead) / 2))
    }

    /// Projects `places` onto `route` and keeps those between `fromOffset + minAhead` and the route's
    /// end that are within `maxOffRoute`. Sorted by distance along the route, nearest first, with
    /// same-named places within 200 m of each other collapsed to one. Pure.
    static func rank(
        _ places: [FoundPlace], route: RouteLine, fromOffset: CLLocationDistance,
        minAhead: CLLocationDistance = 1_000, maxAhead: CLLocationDistance = 60_000, limit: Int = 5
    ) -> [StopCandidate] {
        var seen: [StopCandidate] = []
        let projected: [StopCandidate] = places.compactMap { place in
            guard let p = route.project(place.coordinate), p.distance <= maxOffRoute else { return nil }
            let ahead = p.offset - fromOffset
            guard ahead >= minAhead, ahead <= maxAhead else { return nil }
            return StopCandidate(
                name: place.name, coordinate: place.coordinate, routeOffset: p.offset,
                distanceAhead: ahead, offRoute: p.distance)
        }
        .sorted { a, b in a.routeOffset != b.routeOffset ? a.routeOffset < b.routeOffset : a.offRoute < b.offRoute }
        for candidate in projected {
            let duplicate = seen.contains {
                $0.name == candidate.name && RouteLine.haversine($0.coordinate, candidate.coordinate) < 200
            }
            if !duplicate { seen.append(candidate) }
        }
        return Array(seen.prefix(limit))
    }

    /// Searches for the stop type around 20 km ahead and ranks the results. A failed query is
    /// skipped so one bad search doesn't hide the others; only if every query fails does it throw.
    static func suggest(
        type: EventType, route: RouteLine, fromOffset: CLLocationDistance, searcher: any PlaceSearching
    ) async throws -> [StopCandidate] {
        guard let center = searchCenter(on: route, from: fromOffset) else { return [] }
        var found: [FoundPlace] = []
        var lastError: Error?
        var succeeded = false
        for query in queries(for: type) {
            do {
                found += try await searcher.search(query: query, near: center, radius: searchRadius)
                succeeded = true
            } catch {
                lastError = error
            }
        }
        if !succeeded, let lastError { throw lastError }
        return rank(found, route: route, fromOffset: fromOffset)
    }
}
