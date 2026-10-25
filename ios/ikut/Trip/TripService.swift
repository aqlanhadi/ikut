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

    /// "Trip to Ipoh": the name a trip gets when created from Where to?; the organizer can rename it.
    static func defaultTripName(destination: String) -> String { "Trip to \(destination)" }

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
            routeSeconds: route.travelTime,
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

    /// Longer than `ServerWrite.defaultTimeout`: the first write also opens the connection.
    static let createTimeout: Duration = .seconds(15)

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
        let carRef = db.collection(FirestorePaths.cars(tripId: tripRef.documentID)).document()

        let trip = makeTrip(
            name: name, code: generateCode(), organizerId: organizer.id,
            destination: destination, route: route)
        let member = makeOrganizerMember(organizer: organizer, carId: carRef.documentID)
        let car = makeOrganizerCar(
            organizer: organizer, name: carName ?? Self.carName(for: organizer.displayName),
            color: carColor ?? palette[0])

        nonisolated(unsafe) let batch = db.batch()
        try batch.setData(from: trip, forDocument: tripRef)
        try batch.setData(
            from: member, forDocument: db.document(FirestorePaths.member(tripId: tripRef.documentID, userId: organizer.id)))
        // A trip the server hasn't seen can't be joined, so a queued create is a failure here.
        guard try await ServerWrite.commit(within: createTimeout, { try await batch.commit() }) else {
            throw ServerWrite.Offline()
        }

        // Encode first: `setData(from:)` has no async overload, so awaiting it wouldn't wait for the server.
        nonisolated(unsafe) let carData = try Firestore.Encoder().encode(car)
        guard try await ServerWrite.commit(within: createTimeout, { try await carRef.setData(carData) }) else {
            throw ServerWrite.Offline()
        }
        return (tripRef.documentID, carRef.documentID)
    }
}

extension TripService {
    /// Organizer only (rules): renames the trip.
    @MainActor
    static func rename(tripId: String, to name: String) async throws {
        let ref = Firestore.firestore().collection(FirestorePaths.trips).document(tripId)
        guard try await ServerWrite.commit({ try await ref.updateData(["name": name]) }) else {
            throw ServerWrite.Offline()
        }
    }

    /// The organizer only (rules): records when the trip first started. Write-once; fails harmlessly if already set.
    @MainActor
    static func markStarted(tripId: String) async {
        let ref = Firestore.firestore().collection(FirestorePaths.trips).document(tripId)
        _ = try? await ServerWrite.commit({ try await ref.updateData(["startedAt": FieldValue.serverTimestamp()]) })
    }

    /// Organizer only (rules): points the trip at a new destination and main route. With planned stops, `stops`
    /// are the same stops with their offsets on the new route; they are written in the same batch.
    @MainActor
    static func changeDestination(
        tripId: String, to destination: DestinationResult, route: BuiltRoute, stops: [PlannedStop] = []
    ) async throws {
        try await write(
            tripId: tripId, destination: destination, plan: StopPlanSave(route: route, stops: stops, removedIds: []))
    }

    /// Organizer only (rules), before the trip starts: the route through the stops and the stops themselves in
    /// one batch, so nobody reads a route without its stops. Stops no longer in the plan are deleted.
    @MainActor
    static func saveStops(tripId: String, plan: StopPlanSave) async throws {
        try await write(tripId: tripId, destination: nil, plan: plan)
    }

    /// Organizer only (rules), mid-trip (D25 4d): the rebuilt route, the new destination when there is one, and the
    /// new offsets of the stops ahead, in one batch. The stop count stays. Offline the batch is queued and false comes
    /// back.
    @MainActor
    @discardableResult
    static func rebuildRoute(tripId: String, result: RouteRebuild.Result, destination: DestinationResult?) async throws -> Bool {
        let db = Firestore.firestore()
        let tripRef = db.collection(FirestorePaths.trips).document(tripId)
        var fields: [String: Any] = ["route": result.route.polyline, "routeSeconds": result.route.travelTime]
        if let destination {
            fields["destination"] = [
                "name": destination.name,
                "coordinate": GeoPoint(
                    latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude),
            ]
        }
        nonisolated(unsafe) let payload = fields
        nonisolated(unsafe) let batch = db.batch()
        batch.updateData(payload, forDocument: tripRef)
        for (id, offset) in result.offsets {
            batch.updateData(["routeOffset": offset], forDocument: db.document(FirestorePaths.stop(tripId: tripId, stopId: id)))
        }
        return try await ServerWrite.commit { try await batch.commit() }
    }

    @MainActor
    private static func write(tripId: String, destination: DestinationResult?, plan: StopPlanSave) async throws {
        let db = Firestore.firestore()
        let tripRef = db.collection(FirestorePaths.trips).document(tripId)
        var fields: [String: Any] = [
            "route": plan.route.polyline, "routeSeconds": plan.route.travelTime, "stopCount": plan.stops.count,
        ]
        if let destination {
            fields["destination"] = [
                "name": destination.name,
                "coordinate": GeoPoint(
                    latitude: destination.coordinate.latitude, longitude: destination.coordinate.longitude),
            ]
        }
        nonisolated(unsafe) let payload = fields
        nonisolated(unsafe) let batch = db.batch()
        batch.updateData(payload, forDocument: tripRef)
        for stop in plan.stops {
            let ref = stop.id.map { db.document(FirestorePaths.stop(tripId: tripId, stopId: $0)) }
                ?? db.collection(FirestorePaths.stops(tripId: tripId)).document()
            try batch.setData(from: stop, forDocument: ref)
        }
        for id in plan.removedIds {
            batch.deleteDocument(db.document(FirestorePaths.stop(tripId: tripId, stopId: id)))
        }
        guard try await ServerWrite.commit({ try await batch.commit() }) else { throw ServerWrite.Offline() }
    }
}

/// Display formatting for route summaries.
enum RouteFormat {
    /// "205 km"
    static func distance(_ meters: Double) -> String {
        "\(kilometres(meters)) km"
    }

    /// The whole kilometres `distance` prints, for a line that adds its own words ("18 km ahead").
    static func kilometres(_ meters: Double) -> Int { Int((meters / 1000).rounded()) }
}
