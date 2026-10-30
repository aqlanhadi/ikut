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
    static let palette = ["#2563EB", "#CC450D", "#0F766E", "#7C3AED", "#BE185D", "#A16207"]

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
    /// A long place name is cut (with an ellipsis) so the name never passes `nameMaxLength`.
    static func defaultTripName(destination: String) -> String {
        let prefix = "Trip to "
        let room = nameMaxLength - prefix.count
        let place = destination.count <= room ? destination : String(destination.prefix(room - 1)) + "…"
        return prefix + place
    }

    /// Longest trip name the app accepts. The rules refuse over 200; 60 is what fits a title on the screens.
    static let nameMaxLength = 60

    /// What to say when a typed trip name (already trimmed) is too long; nil when it is fine. Empty is not a problem on
    /// New trip (it gets the default), so callers that need a name check emptiness themselves.
    static func nameProblem(_ trimmed: String) -> String? {
        trimmed.count > nameMaxLength ? "Use 1 to \(nameMaxLength) characters." : nil
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

    /// How many codes `createTrip` tries before giving up (D103).
    static let codeAttempts = 5

    /// Raised when every code tried was turned away.
    struct CodeUnavailable: LocalizedError {
        var errorDescription: String? { "Couldn’t set up your trip just now. Please try again." }
    }

    /// The rules turn a trip away when its code is already claimed, and say only "permission denied" (a client can't
    /// read the claims). That is the one error a fresh code can fix, so it is the one retried.
    static func isCodeCollision(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == FirestoreErrorDomain && ns.code == FirestoreErrorCode.permissionDenied.rawValue
    }

    /// Runs `attempt` with a fresh code until one is accepted, at most `attempts` times; returns the accepted code.
    /// Only a collision (`isCodeCollision`) moves on to the next code; any other error, and an offline write, goes
    /// straight to the caller. After the last collision it throws `CodeUnavailable`.
    static func claimingCode(
        isolation: isolated (any Actor)? = #isolation,
        attempts: Int = codeAttempts,
        nextCode: () -> String = { generateCode() },
        collision: (Error) -> Bool = { isCodeCollision($0) },
        _ attempt: (String) async throws -> Void
    ) async throws -> String {
        for _ in 0..<attempts {
            let code = nextCode()
            do {
                try await attempt(code)
                return code
            } catch where collision(error) {
                continue
            }
        }
        throw CodeUnavailable()
    }

    /// Creates the trip, its code claim and the organizer's member doc in one batch, then the organizer's car.
    ///
    /// The claim (`codes/{code}`) is what keeps two trips from sharing a code: the rules only accept it while no one
    /// holds the code. On a collision the whole batch is refused and the next try uses a new code.
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

        let tripId = tripRef.documentID
        let member = makeOrganizerMember(organizer: organizer, carId: carRef.documentID)
        let car = makeOrganizerCar(
            organizer: organizer, name: carName ?? Self.carName(for: organizer.displayName),
            color: carColor ?? palette[0])

        _ = try await claimingCode { code in
            let trip = makeTrip(
                name: name, code: code, organizerId: organizer.id,
                destination: destination, route: route)
            nonisolated(unsafe) let batch = db.batch()
            try batch.setData(from: trip, forDocument: tripRef)
            batch.setData(
                ["tripId": tripId, "organizerId": organizer.id, "createdAt": FieldValue.serverTimestamp()],
                forDocument: db.document(FirestorePaths.code(code)))
            try batch.setData(
                from: member, forDocument: db.document(FirestorePaths.member(tripId: tripId, userId: organizer.id)))
            // A trip the server hasn't seen can't be joined, so a queued create is a failure here.
            guard try await ServerWrite.commit(within: createTimeout, { try await batch.commit() }) else {
                throw ServerWrite.Offline()
            }
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
