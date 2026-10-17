import CoreLocation
import Foundation

/// What the host screen (map or session) gives the stop sheet and card. They never read the
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
}

/// What the card's buttons do. The host supplies these; `StopService.actions` builds live ones.
struct StopRequestActions: Sendable {
    var vote: @MainActor @Sendable (_ agree: Bool) -> Void
    /// Opens the suggestions so the viewer can name another place.
    var suggestAnother: @MainActor @Sendable () -> Void
    /// Pin `place` (lead car or organizer).
    var pin: @MainActor @Sendable (_ place: StopPlace) -> Void
    var resolve: @MainActor @Sendable () -> Void

    static let none = StopRequestActions(
        vote: { _ in }, suggestAnother: {}, pin: { _ in }, resolve: {})
}
