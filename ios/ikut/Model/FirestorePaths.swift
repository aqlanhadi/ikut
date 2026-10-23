/// Firestore collection and document paths, kept in one place.
enum FirestorePaths {
    static let trips = "trips"

    static func trip(_ tripId: String) -> String { "trips/\(tripId)" }

    static func cars(tripId: String) -> String { "\(trip(tripId))/cars" }
    static func car(tripId: String, carId: String) -> String { "\(cars(tripId: tripId))/\(carId)" }

    static func members(tripId: String) -> String { "\(trip(tripId))/members" }
    static func member(tripId: String, userId: String) -> String { "\(members(tripId: tripId))/\(userId)" }

    static func stops(tripId: String) -> String { "\(trip(tripId))/stops" }
    static func stop(tripId: String, stopId: String) -> String { "\(stops(tripId: tripId))/\(stopId)" }

    static func positions(tripId: String) -> String { "\(trip(tripId))/positions" }
    /// One position document per car, keyed by car id and overwritten on each update.
    static func position(tripId: String, carId: String) -> String { "\(positions(tripId: tripId))/\(carId)" }

    static func events(tripId: String) -> String { "\(trip(tripId))/events" }
    static func event(tripId: String, eventId: String) -> String { "\(events(tripId: tripId))/\(eventId)" }
}
