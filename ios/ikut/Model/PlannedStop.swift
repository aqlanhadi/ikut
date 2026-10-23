import FirebaseFirestore

enum PlannedStopKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Where the convoy gathers before it sets off; first stop only.
    case meet
    case fuel
    case food
    case rest
    case toilet
    case sight
}

/// `trips/{tripId}/stops/{stopId}`: a place on the main route that cars arrive at and leave.
///
/// The organizer writes them in the lobby, before `startedAt`, together with the route that goes
/// through them; after the start only `skipped` (with `skippedBy`, `skippedAt`), `arrivedAt` and the leave fields change. The same
/// shape is meant for a stop chosen mid-trip (D4): a stop request would carry the id of one of
/// these documents, and arrival and leave work on a stop whatever put it on the route.
struct PlannedStop: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var coordinate: GeoPoint
    /// Meters along the trip's main route where the route reaches this stop.
    var routeOffset: Double
    var kind: PlannedStopKind
    /// Planned length of the stop; nil when the organizer gave none. Never set on a meeting point.
    var minutes: Int?
    /// When to meet; only on a `meet` stop, and optional there.
    var meetAt: Date?
    var note: String?
    /// 0-based place in the list. A `meet` stop is always 0.
    var order: Int
    /// Set once by the organizer after the start; nil until then.
    var skipped: Bool?
    var skippedBy: String?
    var skippedAt: Date?
    /// Server time when the lead car's phone first counted its car at the stop (written once); "Leaving at" counts
    /// `minutes` from it, so every phone shows the same time.
    var arrivedAt: Date?
    /// Set once when the lead car or the organizer taps Leave: the stop is done for everyone.
    var leftAt: Date?
    var leftBy: String?

    /// Not skipped.
    var isActive: Bool { skipped != true }
    var isLeft: Bool { leftAt != nil }
    /// Still to be done: not skipped and not left. Next stop, the card and the approach alert look at this.
    var isOpen: Bool { isActive && !isLeft }
    var isMeeting: Bool { kind == .meet }

    static let maxCount = 8
    static let allowedMinutes = [10, 20, 30, 60]
}
