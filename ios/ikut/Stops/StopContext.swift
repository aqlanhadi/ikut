import CoreLocation
import Foundation

/// What the host screen (map or session) gives the stop card and pill. They never read the
/// location or the session themselves.
struct StopContext: Sendable {
    var tripId: String
    var userId: String
    var carId: String
    /// The viewer is the trip's organizer. (Lead-car status is read from the cars, not passed in.)
    var isOrganizer: Bool
    /// Latest location, heading and offset, or nil while there is no fix yet.
    var snapshot: @MainActor @Sendable () -> ReportSnapshot?
    /// The trip's main route; nil until loaded. The event's offset is along this route.
    var mainRoute: RouteLine?
}

/// What the card's and the pill's buttons do. The host supplies these; `StopService.actions`
/// builds live ones. Every action names the request it is for, so two open requests each get their own.
struct StopRequestActions: Sendable {
    /// This car says OK.
    var ok: @MainActor @Sendable (_ eventId: String) -> Void
    /// Closes the request with a reason: the asker cancels it, or the asker, the lead car or the
    /// organizer says the convoy has stopped.
    var close: @MainActor @Sendable (_ eventId: String, _ reason: StopClosedReason) -> Void

    static let none = StopRequestActions(ok: { _ in }, close: { _, _ in })
}
