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
    private(set) var errorMessage: String?

    var groupedCars: [LobbyCar] { LobbyLogic.group(cars: cars, members: members) }

    // Handles aren't Sendable; they're written on the main actor and removed in stop() or deinit.
    @ObservationIgnored nonisolated(unsafe) private var listeners: [ListenerRegistration] = []

    init(tripId: String) {
        self.tripId = tripId
    }

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
                let cars = snapshot?.documents.compactMap { try? $0.data(as: Car.self) }
                let message = error?.localizedDescription
                Task { @MainActor in
                    if let cars { self?.cars = cars }
                    if let message { self?.errorMessage = message }
                }
            })

        listeners.append(
            db.collection(FirestorePaths.members(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let members = snapshot?.documents.compactMap { try? $0.data(as: Member.self) }
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
