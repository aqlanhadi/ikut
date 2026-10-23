import FirebaseFirestore

enum TripStatus: String, Codable, Sendable, Equatable {
    case active
    case ended
}

/// Where the convoy is headed.
struct Destination: Codable, Sendable, Equatable {
    var name: String
    var coordinate: GeoPoint
}

/// `trips/{tripId}`.
struct Trip: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var name: String
    /// 6-character join code.
    var code: String
    var organizerId: String
    /// Main route as an encoded polyline (precision 5).
    var route: String
    var destination: Destination
    /// Driving time in seconds along `route` (the legs added up when it goes through stops); nil on trips
    /// made before it was stored, which then ask MapKit for the time.
    var routeSeconds: Double?
    var status: TripStatus
    @ServerTimestamp var createdAt: Date?
    /// Bumped on activity; trips idle for 12 hours are ended.
    var lastActivityAt: Date?
    /// When a member first tapped Start Trip (server time); nil until the trip is underway.
    var startedAt: Date?
    var endedAt: Date?
}
