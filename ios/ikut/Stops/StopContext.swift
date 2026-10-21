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
    /// The trip's main route; nil until loaded. Offsets in events and places are along this route.
    var mainRoute: RouteLine?
    /// Offset of the front car along the main route, when the host knows it. Suggestions start
    /// ahead of this, so they are ahead of every car.
    var frontOffset: @MainActor @Sendable () -> Double? = { nil }
    /// Where every car is now, by car id, from the positions the phone already has. Works out who is
    /// here and how far the others are; nothing is written for it.
    var carFixes: @MainActor @Sendable () -> [String: StopCarFix] = { [:] }
}

/// What the card's and the pill's buttons do. The host supplies these; `StopService.actions`
/// builds live ones. Every action names the request it is for, so two open requests each get their own.
struct StopRequestActions: Sendable {
    var answer: @MainActor @Sendable (_ eventId: String, _ answer: StopAnswer) -> Void
    /// Pin `place` (lead car or organizer).
    var pin: @MainActor @Sendable (_ eventId: String, _ place: StopPlace) -> Void
    /// Closes the request with a reason: cancelled by the asker, left by the lead or organizer.
    var close: @MainActor @Sendable (_ eventId: String, _ reason: StopClosedReason) -> Void

    static let none = StopRequestActions(answer: { _, _ in }, pin: { _, _ in }, close: { _, _ in })
}
