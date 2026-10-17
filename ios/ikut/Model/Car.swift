import FirebaseFirestore

enum CarState: String, Codable, Sendable, Equatable {
    case joining
    case convoy
}

/// `trips/{tripId}/cars/{carId}`.
struct Car: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var name: String
    var color: String
    var trackerUserId: String?
    var isLead: Bool
    /// The car's own route as an encoded polyline; nil until computed.
    var route: String?
    /// Meters along the main route where this car joins it; nil until known.
    var mergeOffset: Double?
    var state: CarState
    /// Badge number shown on the map and in lists; 1 is the organizer's car, then highest existing + 1.
    /// Optional because cars created before numbering existed have none.
    var number: Int?
    /// When the tracker paused sharing; nil when sharing. Treat as expired after `TripSessionLogic.pauseExpiry`.
    var pausedAt: Date?
}
