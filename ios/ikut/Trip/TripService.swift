import CoreLocation
import FirebaseFirestore
import FirebaseFunctions
import Foundation

/// The signed-in user creating a trip.
struct TripOrganizer: Sendable, Equatable {
    var id: String
    var displayName: String
}

/// Creates trips (through the server) and edits them (to Firestore).
enum TripService {
    /// A–Z and 2–9 without O, I, L (0 and 1 are already excluded).
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let codeLength = 6

    /// Fixed car colors (hex); the organizer's car takes the first.
    static let palette = ["#2563EB", "#CC450D", "#0F766E", "#7C3AED", "#BE185D", "#A16207"]

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

    static func makeOrganizerCar(organizer: TripOrganizer, name: String, color: String) -> Car {
        Car(
            name: name, color: color, trackerUserId: organizer.id, isLead: true,
            state: .convoy, number: 1)
    }

    /// Longer than `ServerWrite.defaultTimeout`: the first write also opens the connection.
    static let createTimeout: Duration = .seconds(15)

    /// What the person reads when the create call fails. A rate-limited call says how long to wait (the server sends
    /// `details.retryAfterSeconds`, like the join limit); a code collision never reaches the app (the server retries).
    struct CreateFailure: LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    static func createFailureMessage(code: FunctionsErrorCode?, retryAfterSeconds: Int?) -> String {
        switch code {
        case .resourceExhausted:
            guard let seconds = retryAfterSeconds else { return "You’ve made a lot of trips lately. Try again in a little while." }
            if seconds > 12 * 3600 { return "You’ve made a lot of trips today. Try again tomorrow." }
            return "You’ve made a lot of trips lately. Wait \(JoinService.waitPhrase(seconds: seconds)) and try again."
        case .unauthenticated, .permissionDenied:
            return "You’re signed out. Close ikut, open it again and try again."
        case .unavailable, .deadlineExceeded:
            return "Can’t reach the server. Check your signal and try again."
        default:
            return "Couldn’t set up your trip just now. Please try again."
        }
    }

    /// The failure `createTrip` throws for an error from the callable.
    static func createFailure(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == FunctionsErrorDomain else {
            return ns.domain == NSURLErrorDomain
                ? CreateFailure(message: createFailureMessage(code: .unavailable, retryAfterSeconds: nil)) : error
        }
        let details = ns.userInfo[FunctionsErrorDetailsKey] as? [String: Any]
        let wait = details?["reason"] as? String == "too-many-trips" ? (details?["retryAfterSeconds"] as? NSNumber)?.intValue : nil
        return CreateFailure(message: createFailureMessage(code: FunctionsErrorCode(rawValue: ns.code), retryAfterSeconds: wait))
    }

    /// What the `createTrip` callable is sent (functions/src/createTrip.ts, `parseCreateInput`).
    static func createPayload(
        name: String, destination: DestinationResult, route: BuiltRoute, organizerName: String, carId: String
    ) -> [String: Any] {
        [
            "name": name,
            "destination": [
                "name": destination.name,
                "latitude": destination.coordinate.latitude,
                "longitude": destination.coordinate.longitude,
            ],
            "route": route.polyline,
            "routeSeconds": route.travelTime,
            "organizerName": organizerName,
            "carId": carId,
        ]
    }

    /// Creates the trip through the `createTrip` callable (D108), then the organizer's car.
    ///
    /// The server picks the code and writes the trip, the organizer's member doc and the code claim in one go; the app
    /// only learns the trip id (and the code, which it reads from the trip like everyone else). The rules refuse any
    /// client create of a trip, so nobody can probe codes by creating.
    ///
    /// The car goes in a second write because the rules only let existing members create cars. Its id is chosen here
    /// and sent with the call, so the organizer's member doc names it.
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
        let carId = db.collection(FirestorePaths.trips).document().documentID
        let car = makeOrganizerCar(
            organizer: organizer, name: carName ?? Self.carName(for: organizer.displayName),
            color: carColor ?? palette[0])

        nonisolated(unsafe) let payload = createPayload(
            name: name, destination: destination, route: route, organizerName: organizer.displayName, carId: carId)
        let tripId: String
        do {
            let result = try await Backend.functions.httpsCallable("createTrip").call(payload)
            guard let data = result.data as? [String: Any], let id = data["tripId"] as? String, !id.isEmpty else {
                throw CreateFailure(message: createFailureMessage(code: nil, retryAfterSeconds: nil))
            }
            tripId = id
        } catch {
            throw createFailure(error)
        }

        // Encode first: `setData(from:)` has no async overload, so awaiting it wouldn't wait for the server.
        nonisolated(unsafe) let carData = try Firestore.Encoder().encode(car)
        let carRef = db.document(FirestorePaths.car(tripId: tripId, carId: carId))
        guard try await ServerWrite.commit(within: createTimeout, { try await carRef.setData(carData) }) else {
            throw ServerWrite.Offline()
        }
        return (tripId, carId)
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
