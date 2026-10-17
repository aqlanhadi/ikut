import FirebaseFirestore

enum EventCategory: String, Codable, Sendable, Equatable {
    case hazard
    case condition
    case stopRequest
    case status
    case message

    var severity: Severity {
        switch self {
        case .hazard, .status: .high
        case .condition, .stopRequest: .medium
        case .message: .low
        }
    }

    /// Time until an event of this category expires; nil means it lasts until resolved or cleared.
    var defaultExpiry: TimeInterval? {
        switch self {
        case .hazard: 45 * 60
        case .condition: 60 * 60
        case .message: 30 * 60
        case .stopRequest, .status: nil
        }
    }
}

enum Severity: String, Codable, Sendable, Equatable {
    case high
    case medium
    case low
}

/// What was reported. Unknown strings (types added via config later) decode as `.other`.
enum EventType: Sendable, Equatable, Hashable {
    case debris, accident, pothole, animal, stoppedVehicle, roadworks
    case heavyRain, trafficJam
    case stopRest, stopFuel, stopFood, stopToilet
    case pullingOver, carTrouble, runningLate
    case message
    case other(String)

    private static let known: [String: EventType] = [
        "debris": .debris, "accident": .accident, "pothole": .pothole, "animal": .animal,
        "stoppedVehicle": .stoppedVehicle, "roadworks": .roadworks,
        "heavyRain": .heavyRain, "trafficJam": .trafficJam,
        "stopRest": .stopRest, "stopFuel": .stopFuel, "stopFood": .stopFood, "stopToilet": .stopToilet,
        "pullingOver": .pullingOver, "carTrouble": .carTrouble, "runningLate": .runningLate,
        "message": .message,
    ]

    var rawValue: String {
        if case .other(let raw) = self { return raw }
        return Self.known.first { $0.value == self }!.key
    }

    init(rawValue: String) {
        self = Self.known[rawValue] ?? .other(rawValue)
    }

    /// Category for known types; unknown types fall back to `.message`.
    var category: EventCategory {
        switch self {
        case .debris, .accident, .pothole, .animal, .stoppedVehicle, .roadworks: .hazard
        case .heavyRain, .trafficJam: .condition
        case .stopRest, .stopFuel, .stopFood, .stopToilet: .stopRequest
        case .pullingOver, .carTrouble, .runningLate: .status
        case .message, .other: .message
        }
    }
}

extension EventType: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `trips/{tripId}/events/{eventId}`.
struct TripEvent: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var type: EventType
    var category: EventCategory
    var severity: Severity
    var location: GeoPoint
    var heading: Double
    /// Meters along the reporting car's route.
    var routeOffset: Double
    var authorId: String
    var carId: String
    @ServerTimestamp var createdAt: Date?
    /// nil means the event stays until resolved or cleared.
    var expiresAt: Date?
    var message: String?

    /// Builds an event with category, severity and expiry derived from its type.
    init(
        type: EventType, location: GeoPoint, heading: Double, routeOffset: Double,
        authorId: String, carId: String, createdAt: Date = Date(), message: String? = nil
    ) {
        self.type = type
        self.category = type.category
        self.severity = type.category.severity
        self.location = location
        self.heading = heading
        self.routeOffset = routeOffset
        self.authorId = authorId
        self.carId = carId
        self.createdAt = createdAt
        self.expiresAt = type.category.defaultExpiry.map { createdAt.addingTimeInterval($0) }
        self.message = message
    }
}
