import CoreLocation
import Foundation

/// The drive from where the person is to the trip's destination, for the Join ticket's quiet line.
struct TicketDrive: Sendable, Equatable {
    /// Meters.
    var distance: Double
    /// Seconds.
    var travelTime: Double

    /// "About 2 h 10 min from you · 185 km": the big destination above it already says where, so no "To".
    var line: String {
        "About \(ConvoyFormat.duration(travelTime)) from you · \(RouteFormat.distance(distance))"
    }

    /// One MapKit request from the phone's location; nil when location is off or denied, or there's no road.
    @MainActor
    static func fromHere(to destination: CLLocationCoordinate2D) async -> TicketDrive? {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways,
            let here = try? await RouteBuilder.currentLocation(),
            let drive = try? await RouteBuilder.drive(from: here, to: destination)
        else { return nil }
        return TicketDrive(distance: drive.distance, travelTime: drive.travelTime)
    }
}
