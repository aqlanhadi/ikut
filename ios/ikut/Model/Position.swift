import FirebaseFirestore

/// `trips/{tripId}/positions/{carId}`, overwritten on each update.
struct Position: Codable, Sendable, Equatable, Identifiable {
    @DocumentID var id: String?
    var location: GeoPoint
    /// Meters per second.
    var speed: Double
    /// Degrees clockwise from north.
    var heading: Double
    /// Meters along the car's own route.
    var routeOffset: Double
    /// Meters along the main route; nil until the car has merged.
    var convoyOffset: Double?
    /// 0...1.
    var battery: Double?
    @ServerTimestamp var updatedAt: Date?
}
