import FirebaseFirestore
import Foundation
import Observation

/// Live trip, cars and members for the lobby, from Firestore snapshot listeners.
@Observable @MainActor
final class LobbyModel {
    let tripId: String
    private(set) var trip: Trip?
    private(set) var cars: [Car] = []
    private(set) var members: [Member] = []
    /// The planned stops, in driving order.
    private(set) var stops: [PlannedStop] = []
    private(set) var errorMessage: String?

    var groupedCars: [LobbyCar] { LobbyLogic.group(cars: cars, members: members) }

    // Handles aren't Sendable; they're written on the main actor and removed in stop() or deinit.
    @ObservationIgnored nonisolated(unsafe) private var listeners: [ListenerRegistration] = []

    init(tripId: String) {
        self.tripId = tripId
    }

    #if DEBUG
    /// A lobby on sample data, for previews. Don't `start()` it: the listeners would replace the data.
    init(sampleTrip trip: Trip, cars: [Car], members: [Member], stops: [PlannedStop] = []) {
        tripId = trip.id ?? "sample"
        self.trip = trip
        self.cars = cars
        self.members = members
        self.stops = stops
    }

    /// KL to Ipoh with four cars, Hafiz's still waiting for a tracker; `started` puts it on the road.
    static func sample(started: Bool, now: Date = Date(), seconds: Double? = nil, stops: [PlannedStop] = []) -> LobbyModel {
        func car(_ id: String, _ name: String, _ color: String, _ number: Int, tracker: String?, lead: Bool = false) -> Car {
            Car(id: id, name: name, color: color, trackerUserId: tracker, isLead: lead, route: nil, mergeOffset: nil,
                state: .convoy, number: number)
        }
        func member(_ id: String, _ name: String, _ carId: String, organizer: Bool = false) -> Member {
            Member(id: id, displayName: name, carId: carId, role: organizer ? .organizer : .member)
        }
        let trip = Trip(
            id: "sample", name: "Balik kampung raya", code: "K7M2QX", organizerId: "u1",
            route: Polyline.encode(MapDemo.densify(MapDemo.mainWaypoints)),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 4.6, longitude: 101.09)),
            routeSeconds: seconds,
            status: .active, createdAt: now.addingTimeInterval(-900), lastActivityAt: now,
            startedAt: started ? now.addingTimeInterval(-600) : nil, endedAt: nil)
        return LobbyModel(
            sampleTrip: trip,
            cars: [
                car("c1", "Aqlan’s Myvi", "#2563EB", 1, tracker: "u1", lead: true),
                car("c2", "Wyna’s X70", "#D9480F", 2, tracker: "u2"),
                car("c3", "Hafiz’s Hilux", "#0F766E", 3, tracker: started ? "u3" : nil),
                car("c4", "Daniel’s City", "#7C3AED", 4, tracker: "u4"),
            ],
            members: [
                member("u1", "Aqlan", "c1", organizer: true), member("u5", "Faiz", "c1"),
                member("u2", "Wyna", "c2"), member("u3", "Hafiz", "c3"),
                member("u4", "Daniel", "c4"), member("u6", "Siti", "c4"), member("u7", "Aisha", "c4"),
            ],
            stops: stops)
    }
    #endif

    deinit {
        for listener in listeners { listener.remove() }
    }

    /// Attaches the listeners; calling it again while running does nothing.
    func start() {
        guard listeners.isEmpty else { return }
        let db = Firestore.firestore()

        listeners.append(
            db.document(FirestorePaths.trip(tripId)).addSnapshotListener { [weak self] snapshot, error in
                let trip = try? snapshot?.data(as: Trip.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let trip { self?.trip = trip }
                    if let message { self?.errorMessage = message }
                }
            })

        listeners.append(
            db.collection(FirestorePaths.cars(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let cars = snapshot?.decoded(Car.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let cars { self?.cars = cars }
                    if let message { self?.errorMessage = message }
                }
            })

        listeners.append(
            db.collection(FirestorePaths.stops(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let stops = snapshot?.decoded(PlannedStop.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let stops { self?.stops = stops.sorted { $0.order < $1.order } }
                    if let message { self?.errorMessage = message }
                }
            })

        listeners.append(
            db.collection(FirestorePaths.members(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let members = snapshot?.decoded(Member.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let members { self?.members = members }
                    if let message { self?.errorMessage = message }
                }
            })
    }

    func stop() {
        for listener in listeners { listener.remove() }
        listeners = []
    }
}
