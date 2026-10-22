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
        // A stop request closes itself this long after it was asked; no phone has to write anything.
        case .stopRequest: 30 * 60
        case .status: nil
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

/// Where a stop request stands. A missing status (an event from an old build) reads as `.open`.
enum StopStatus: String, Codable, Sendable, Equatable {
    case open
    case closed

    /// Anything else (an old build's `pinned`) is still open.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopStatus(rawValue: raw) ?? .open
    }
}

/// Why a stop request closed; set only together with `StopStatus.closed`.
enum StopClosedReason: String, Codable, Sendable, Equatable {
    /// The asker, the lead car or the organizer said the convoy has stopped.
    case stopped
    /// The asker withdrew the request.
    case cancelled

    /// An old build's `left` or `noAnswer` reads as stopped.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StopClosedReason(rawValue: raw) ?? .stopped
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
    /// A stop request's optional note from a passenger (0 to 280 characters).
    var message: String?
    /// Stop requests only. Nil on events written before states existed: read as open.
    var status: StopStatus?
    /// Set only when the request closes (with `closedBy` and `expiresAt` = now).
    var closedReason: StopClosedReason?
    var closedBy: String?

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
