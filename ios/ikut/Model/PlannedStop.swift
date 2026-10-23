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
/// through them; after the start only `skipped` (with `skippedBy`, `skippedAt`) changes. The same
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

    /// Not skipped.
    var isActive: Bool { skipped != true }
    var isMeeting: Bool { kind == .meet }

    static let maxCount = 8
    static let allowedMinutes = [10, 20, 30, 60]
}
