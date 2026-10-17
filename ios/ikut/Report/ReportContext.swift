import CoreLocation
import Foundation

/// Where the reporter was at one moment. Taken when the sheet opens, so the pin lands where the
/// passenger tapped Report rather than where the car is when they finish choosing.
struct ReportSnapshot: Sendable {
    var coordinate: CLLocationCoordinate2D
    /// Degrees; CoreLocation reports -1 when unknown (`EventService` normalizes it).
    var heading: Double
    var route: RouteLine?
    /// The car's last known offset along `route`, used to pick the right segment on a route that doubles back.
    var previousOffset: CLLocationDistance?
    var capturedAt: Date
}

/// What the host screen (map or session) gives the report sheet. The sheet never reads the
/// location itself.
struct ReportContext: Sendable {
    var tripId: String
    var carId: String
    var authorId: String
    /// Latest location, heading, route and offset, or nil while there is no fix yet.
    var snapshot: @MainActor @Sendable () -> ReportSnapshot?
}

/// One report to send: who, what and where.
struct ReportRequest: Sendable {
    var type: EventType
    var tripId: String
    var carId: String
    var authorId: String
    var snapshot: ReportSnapshot
}

/// Sends and retracts reports. A protocol so previews and tests can fake it.
protocol ReportService: Sendable {
    /// Returns the new event's id.
    func report(_ request: ReportRequest) async throws -> String
    func undo(tripId: String, eventId: String) async throws
}

/// The real thing, backed by `EventService`.
struct LiveReportService: ReportService {
    func report(_ request: ReportRequest) async throws -> String {
        try await EventService.report(
            type: request.type, tripId: request.tripId, carId: request.carId,
            authorId: request.authorId, location: request.snapshot.coordinate,
            heading: request.snapshot.heading, route: request.snapshot.route,
            previousOffset: request.snapshot.previousOffset)
    }

    func undo(tripId: String, eventId: String) async throws {
        try await EventService.undo(tripId: tripId, eventId: eventId)
    }
}
