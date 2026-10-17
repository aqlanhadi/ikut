import CoreLocation
import MapKit

/// A destination candidate from a place search.
struct DestinationResult: Sendable, Equatable, Identifiable {
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D

    var id: String { "\(name)|\(coordinate.latitude)|\(coordinate.longitude)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.subtitle == rhs.subtitle
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// The main route for a trip, ready to store.
struct BuiltRoute: Sendable, Equatable {
    /// Meters.
    var distance: Double
    /// Seconds.
    var travelTime: Double
    /// The road's name as reported by MapKit (e.g. "E1"); empty when unknown.
    var name: String
    /// Encoded polyline (precision 5).
    var polyline: String
}

enum RouteError: LocalizedError, Equatable {
    case locationUnavailable
    case noRoute
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .locationUnavailable: "Turn on location to build the route."
        case .noRoute: "No driving route found to that destination."
        case .failed(let message): message
        }
    }
}

/// Destination search and main-route building on top of MapKit.
///
/// Never asks for location permission; the caller is expected to have done that.
enum RouteBuilder {
    @MainActor
    static func searchDestinations(query: String) async throws -> [DestinationResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap { item in
            guard let name = item.name else { return nil }
            return DestinationResult(
                name: name,
                subtitle: item.placemark.title ?? "",
                coordinate: item.placemark.coordinate
            )
        }
    }

    /// Fastest driving route from the current location to `destination`.
    @MainActor
    static func buildRoute(to destination: CLLocationCoordinate2D) async throws -> BuiltRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError where error.code == .directionsNotFound {
            throw RouteError.noRoute
        } catch let error as NSError where isLocationError(error) {
            throw RouteError.locationUnavailable
        } catch {
            throw RouteError.failed(error.localizedDescription)
        }
        guard let route = response.routes.first else { throw RouteError.noRoute }
        return BuiltRoute(
            distance: route.distance,
            travelTime: route.expectedTravelTime,
            name: route.name,
            polyline: Polyline.encode(coordinates(of: route.polyline))
        )
    }

    private static func isLocationError(_ error: NSError) -> Bool {
        if error.domain == kCLErrorDomain { return true }
        // MapKit reports an unknown current location as a placemark/load failure.
        return error.domain == MKErrorDomain && error.code == MKError.placemarkNotFound.rawValue
    }

    private static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }
}
