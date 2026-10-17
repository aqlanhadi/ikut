import CoreLocation
import FirebaseFirestore
import Foundation

/// The signed-in user creating a trip.
struct TripOrganizer: Sendable, Equatable {
    var id: String
    var displayName: String
}

/// Writes new trips to Firestore.
enum TripService {
    /// A–Z and 2–9 without O, I, L (0 and 1 are already excluded).
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let codeLength = 6

    /// Fixed car colors (hex); the organizer's car takes the first.
    static let palette = ["#2563EB", "#D9480F", "#0F766E", "#7C3AED", "#BE185D", "#A16207"]

    static func generateCode<G: RandomNumberGenerator>(using generator: inout G) -> String {
        String((0..<codeLength).map { _ in codeAlphabet.randomElement(using: &generator)! })
    }

    static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return generateCode(using: &generator)
    }

    static func carName(for displayName: String) -> String { "\(displayName)'s car" }

    static func defaultTripName(for displayName: String?) -> String {
        guard let displayName, !displayName.isEmpty else { return "My trip" }
        return "\(displayName)'s trip"
    }

    static func makeTrip(
        name: String, code: String, organizerId: String,
        destination: DestinationResult, route: BuiltRoute
    ) -> Trip {
        Trip(
            name: name, code: code, organizerId: organizerId, route: route.polyline,
            destination: Destination(
                name: destination.name,
                coordinate: GeoPoint(
                    latitude: destination.coordinate.latitude,
                    longitude: destination.coordinate.longitude)),
            status: .active, createdAt: nil)
    }

    static func makeOrganizerMember(organizer: TripOrganizer, carId: String) -> Member {
        Member(displayName: organizer.displayName, carId: carId, role: .organizer)
    }

    static func makeOrganizerCar(organizer: TripOrganizer, name: String, color: String) -> Car {
        Car(
            name: name, color: color, trackerUserId: organizer.id, isLead: true,
            state: .convoy, number: 1)
    }

    /// Creates the trip and the organizer's member doc in one batch, then the organizer's car.
    ///
    /// The car goes in a second write because the rules only let existing members create cars,
    /// and `exists()` can't see documents from the same batch.
    @MainActor
    static func createTrip(
        name: String,
        destination: DestinationResult,
        route: BuiltRoute,
        organizer: TripOrganizer,
        carName: String? = nil,
        carColor: String? = nil
    ) async throws -> (tripId: String, carId: String) {
        let db = Firestore.firestore()
        let tripRef = db.collection(FirestorePaths.trips).document()
        let carRef = tripRef.collection("cars").document()

        let trip = makeTrip(
            name: name, code: generateCode(), organizerId: organizer.id,
            destination: destination, route: route)
        let member = makeOrganizerMember(organizer: organizer, carId: carRef.documentID)
        let car = makeOrganizerCar(
            organizer: organizer, name: carName ?? Self.carName(for: organizer.displayName),
            color: carColor ?? palette[0])

        let batch = db.batch()
        try batch.setData(from: trip, forDocument: tripRef)
        try batch.setData(
            from: member, forDocument: tripRef.collection("members").document(organizer.id))
        try await batch.commit()

        // Encode first: `setData(from:)` has no async overload, so awaiting it wouldn't wait for the server.
        try await carRef.setData(Firestore.Encoder().encode(car))
        return (tripRef.documentID, carRef.documentID)
    }
}

/// Display formatting for route summaries.
enum RouteFormat {
    /// "205 km"
    static func distance(_ meters: Double) -> String {
        "\(Int((meters / 1000).rounded())) km"
    }

    /// "2 hr 25 min", "2 hr", "45 min"
    static func duration(_ seconds: Double) -> String {
        let totalMinutes = max(1, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(minutes) min"
        }
    }

    /// "205 km · 2 hr 25 min via E1"
    static func summary(_ route: BuiltRoute) -> String {
        let base = "\(distance(route.distance)) · \(duration(route.travelTime))"
        return route.name.isEmpty ? base : "\(base) via \(route.name)"
    }
}
