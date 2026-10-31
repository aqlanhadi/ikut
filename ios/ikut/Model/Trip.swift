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
    /// How many planned stops the trip has; the rules use it to lock the route once a trip with stops has started.
    var stopCount: Int?
    var status: TripStatus
    @ServerTimestamp var createdAt: Date?
    /// Bumped on activity; trips idle for 12 hours are ended.
    var lastActivityAt: Date?
    /// When a member first tapped Start Trip (server time); nil until the trip is underway.
    var startedAt: Date?
    var endedAt: Date?
    /// Written by the server when the trip ends (D107) and kept until the trip is deleted 90 days after it ended;
    /// nil on trips that ended before it existed. Never written by the app.
    var summary: TripSummary?
    /// The convoy's stopped phase (D122): set when the lead car's tracker or the organizer taps We’ve stopped on a
    /// stop request (server time), cleared by Continue. No place is kept, only when, who and which request.
    /// `ConvoyStop` reads it; a phase older than `ConvoyStop.cap` counts as over even while the fields stay.
    var stoppedAt: Date?
    var stoppedBy: String?
    var stoppedEventId: String?
}

/// What is left of a trip once its events and positions are gone (`trips/{id}.summary`): no names, no places. A number
/// the server could not work out is nil, and any nil leaves the rest readable.
struct TripSummary: Codable, Sendable, Equatable {
    /// Meters along the planned main route.
    var distanceMeters: Double?
    /// Seconds from the first Start Trip (from creation if it never started) to the end.
    var durationSeconds: Double?
    var peopleCount: Int?
    var carCount: Int?
    /// Planned stops the lead car reached.
    var stopCount: Int?
    /// Hazard and condition reports still stored when the trip ended.
    var roadReportCount: Int?
    var summarisedAt: Date?
}
