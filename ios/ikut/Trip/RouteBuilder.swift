import CoreLocation
import MapKit

/// A destination candidate from a place search.
struct DestinationResult: Sendable, Equatable, Identifiable {
    var name: String
    var subtitle: String
    var coordinate: CLLocationCoordinate2D
    /// `MKPointOfInterestCategory` raw value; nil for addresses, towns and other non-POI results.
    var category: String? = nil

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
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .locationUnavailable: "Can't find your location. Check that location is on, then try again."
        case .noRoute: "No driving route found to that destination."
        case .timedOut: "Getting the route took too long. Check your connection and try again."
        case .failed(let message): message
        }
    }
}

/// One MapKit request for a leg, no retry.
struct MapKitDirectionsRouter: LegRouting {
    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        try await RouteBuilder.requestLeg(from: from, to: to)
    }
}

/// Asks `base` again, once, after `wait`, when it answers that MapKit is throttling (about 50 requests a minute).
/// A second throttle is passed on. The wait is injectable so tests don't sit through it.
struct ThrottleRetryRouter: LegRouting {
    var base: LegRouting
    var wait: Duration = RouteBuilder.throttleWait
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        do {
            return try await base.leg(from: from, to: to)
        } catch let error as MKError where error.code == .loadingThrottled {
            try await sleep(wait)
            return try await base.leg(from: from, to: to)
        }
    }
}

/// The real leg router: a MapKit request, retried once when throttled.
struct MapKitLegRouter: LegRouting {
    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        try await ThrottleRetryRouter(base: MapKitDirectionsRouter()).leg(from: from, to: to)
    }
}

/// Destination search and main-route building on top of MapKit.
///
/// Never asks for location permission; the caller is expected to have done that.
enum RouteBuilder {
    /// Every match for `query` in `region` (MapKit gives up to about 25), nearest the region first as MapKit ranks them.
    @MainActor
    static func searchDestinations(query: String, region: MKCoordinateRegion = SearchRegion.malaysia) async throws -> [DestinationResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        request.region = region
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.compactMap(destination)
    }

    /// A map item as a destination; nil without a name.
    static func destination(_ item: MKMapItem) -> DestinationResult? {
        guard let name = item.name else { return nil }
        return DestinationResult(
            name: name,
            subtitle: item.placemark.title ?? "",
            coordinate: item.placemark.coordinate,
            category: item.pointOfInterestCategory?.rawValue
        )
    }

    static let locationTimeout: Duration = .seconds(10)
    static let directionsTimeout: Duration = .seconds(20)

    /// Fastest driving route from the current location to `destination`.
    ///
    /// Gets the fix itself rather than using `MKMapItem.forCurrentLocation()`, which waits
    /// forever without one (indoors, before GPS locks, a simulator with no location set).
    @MainActor
    static func buildRoute(to destination: CLLocationCoordinate2D) async throws -> BuiltRoute {
        let here: CLLocationCoordinate2D
        do {
            here = try await currentLocation()
        } catch let error as RouteError {
            throw error
        } catch let error as NSError where isLocationError(error) {
            throw RouteError.locationUnavailable
        }
        let leg = try await leg(from: here, to: destination)
        return BuiltRoute(distance: leg.distance, travelTime: leg.travelTime, name: leg.name, polyline: Polyline.encode(leg.coordinates))
    }

    /// One driving leg from `source` to `destination`: the MapKit request, with the timeout every request here gets,
    /// and one more try after a wait when MapKit says it is throttling (`ThrottleRetryRouter`).
    @MainActor
    static func leg(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> RouteLeg {
        try await MapKitLegRouter().leg(from: source, to: destination)
    }

    static let throttleWait: Duration = .seconds(4)

    @MainActor
    static func requestLeg(from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> RouteLeg {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false

        nonisolated(unsafe) let directions = MKDirections(request: request)
        do {
            return try await withTimeout(directionsTimeout, error: RouteError.timedOut) {
                let response = try await directions.calculate()
                guard let route = response.routes.first else { throw RouteError.noRoute }
                return RouteLeg(
                    coordinates: coordinates(of: route.polyline), distance: route.distance,
                    travelTime: route.expectedTravelTime, name: route.name)
            } onTimeout: {
                directions.cancel()
            }
        } catch let error as RouteError {
            throw error
        } catch let error as MKError where error.code == .directionsNotFound {
            throw RouteError.noRoute
        } catch let error as MKError where error.code == .loadingThrottled {
            throw error
        } catch let error as NSError where isLocationError(error) {
            throw RouteError.locationUnavailable
        } catch {
            throw RouteError.failed(error.localizedDescription)
        }
    }

    /// A recent fix: the cached one if it's under a minute old, else the first live update.
    @MainActor
    static func currentLocation() async throws -> CLLocationCoordinate2D {
        if let cached = CLLocationManager().location, -cached.timestamp.timeIntervalSinceNow < 60 {
            return cached.coordinate
        }
        return try await withTimeout(locationTimeout, error: RouteError.locationUnavailable) {
            for try await update in CLLocationUpdate.liveUpdates(.automotiveNavigation) {
                if let location = update.location { return location.coordinate }
            }
            throw RouteError.locationUnavailable
        }
    }

    /// Runs `work`, throwing `error` (after calling `onTimeout`) if it hasn't finished within `limit`.
    @MainActor
    static func withTimeout<T: Sendable>(
        _ limit: Duration, error: RouteError,
        _ work: @escaping @MainActor @Sendable () async throws -> T,
        onTimeout: @escaping @MainActor @Sendable () -> Void = {}
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                await onTimeout()
                throw error
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Town or city name for a coordinate ("Kuala Lumpur"); nil when the lookup fails.
    @MainActor
    static func placeName(at coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.locality ?? placemark?.subAdministrativeArea ?? placemark?.name
    }

    /// Driving distance, time and road name between two points, without the polyline.
    @MainActor
    static func drive(
        from source: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D
    ) async throws -> (distance: Double, travelTime: Double, name: String) {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: source))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw RouteError.noRoute }
        return (route.distance, route.expectedTravelTime, route.name)
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
