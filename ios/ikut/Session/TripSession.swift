import FirebaseFirestore
import Foundation
import Observation

/// Live state of the trip this user is in, plus the tracker duty that follows from it.
///
/// Every member listens to the trip, their own member doc and `positions`. Only the car's tracker
/// (while the trip is active) runs the `TrackingService`; it stops the moment that stops being true.
@Observable @MainActor
final class TripSession {
    let tripId: String
    let userId: String

    private(set) var trip: Trip?
    private(set) var member: Member?
    private(set) var car: Car?
    /// Latest position per car id.
    private(set) var positions: [String: Position] = [:]
    private(set) var errorMessage: String?
    /// True once the member doc snapshot says this user is not in the trip (any more).
    private(set) var membershipLost = false
    /// True while leaving or ending; tracking is not restarted meanwhile.
    private(set) var isClosing = false
    private(set) var isTracking = false

    var isEnded: Bool { trip?.status == .ended }
    var isOrganizer: Bool { trip?.organizerId == userId && !userId.isEmpty }

    @ObservationIgnored private let tracker: TrackingControlling
    @ObservationIgnored private let db: Firestore
    @ObservationIgnored private var tripListener: ListenerRegistration?
    @ObservationIgnored private var memberListener: ListenerRegistration?
    @ObservationIgnored private var carListener: ListenerRegistration?
    @ObservationIgnored private var positionsListener: ListenerRegistration?
    @ObservationIgnored private var listeningCarId: String?
    @ObservationIgnored private var trackingKey: TrackingKey?
    @ObservationIgnored private var explainerShown = false

    private struct TrackingKey: Equatable {
        var carId: String
        var tripRoute: String
        var carRoute: String?
    }

    init(tripId: String, userId: String, tracker: TrackingControlling? = nil, db: Firestore? = nil) {
        self.tripId = tripId
        self.userId = userId
        self.tracker = tracker ?? TrackingService()
        self.db = db ?? Firestore.firestore()
    }

    isolated deinit {
        tracker.stop()
        removeListeners()
    }

    /// Attaches the listeners; calling it again while running does nothing.
    func start() {
        guard tripListener == nil else { return }

        tripListener = db.document(FirestorePaths.trip(tripId)).addSnapshotListener { [weak self] snapshot, error in
            let trip = try? snapshot?.data(as: Trip.self)
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let trip { self.trip = trip }
                if let message { self.errorMessage = message }
                self.reevaluate()
            }
        }

        memberListener = db.document(FirestorePaths.member(tripId: tripId, userId: userId))
            .addSnapshotListener { [weak self] snapshot, error in
                let exists = snapshot?.exists
                let member = try? snapshot?.data(as: Member.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let message { self.errorMessage = message }
                    if let exists { self.applyMember(exists ? member : nil) }
                }
            }

        positionsListener = db.collection(FirestorePaths.positions(tripId: tripId))
            .addSnapshotListener { [weak self] snapshot, error in
                let positions = snapshot?.documents.compactMap { try? $0.data(as: Position.self) }
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let positions {
                        self.positions = Dictionary(
                            positions.compactMap { p in p.id.map { ($0, p) } },
                            uniquingKeysWith: { _, new in new })
                    }
                    if let message { self.errorMessage = message }
                }
            }
    }

    /// Stops tracking and detaches every listener.
    func stop() {
        tracker.stop()
        isTracking = false
        trackingKey = nil
        removeListeners()
    }

    // MARK: - Leave and end

    /// Stops tracking right away (before any network call), releases tracker duty, then deletes the member doc.
    func leave() async throws {
        stopTrackingNow()
        isClosing = true
        do {
            if car?.trackerUserId == userId, let carId = member?.carId ?? car?.id {
                try await db.document(FirestorePaths.car(tripId: tripId, carId: carId))
                    .updateData(["trackerUserId": FieldValue.delete()])
            }
            try await db.document(FirestorePaths.member(tripId: tripId, userId: userId)).delete()
        } catch {
            isClosing = false
            reevaluate()
            throw error
        }
        stop()
    }

    /// Organizer only: stops tracking right away, then marks the trip ended.
    func endTrip() async throws {
        guard isOrganizer else { return }
        stopTrackingNow()
        isClosing = true
        do {
            try await db.document(FirestorePaths.trip(tripId))
                .updateData(["status": TripStatus.ended.rawValue, "endedAt": FieldValue.serverTimestamp()])
        } catch {
            isClosing = false
            reevaluate()
            throw error
        }
    }

    /// True the first time it is asked with an action that wants the Always explainer.
    func consumeAlwaysExplainer(action: LocationAction) -> Bool {
        guard TripSessionLogic.shouldPresentAlwaysExplainer(action: action, alreadyShown: explainerShown) else {
            return false
        }
        explainerShown = true
        return true
    }

    // MARK: - Private

    private func stopTrackingNow() {
        tracker.stop()
        isTracking = false
        trackingKey = nil
    }

    private func applyMember(_ member: Member?) {
        self.member = member
        membershipLost = member == nil
        guard let member else {
            carListener?.remove()
            carListener = nil
            listeningCarId = nil
            car = nil
            reevaluate()
            return
        }
        if listeningCarId != member.carId { listenToCar(member.carId) }
        reevaluate()
    }

    private func listenToCar(_ carId: String) {
        carListener?.remove()
        listeningCarId = carId
        car = nil
        carListener = db.document(FirestorePaths.car(tripId: tripId, carId: carId))
            .addSnapshotListener { [weak self] snapshot, error in
                let exists = snapshot?.exists
                let car = try? snapshot?.data(as: Car.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.listeningCarId == carId else { return }
                    if let message { self.errorMessage = message }
                    if let exists {
                        self.car = exists ? car : nil
                        self.reevaluate()
                    }
                }
            }
    }

    /// Starts, restarts (route changed) or stops tracking to match the current state.
    private func reevaluate() {
        guard !isClosing else { return }
        let wants = TripSessionLogic.shouldTrack(
            userId: userId, tripStatus: trip?.status, isMember: member != nil,
            trackerUserId: car?.trackerUserId)
        if wants, let trip, let car, let carId = car.id {
            let key = TrackingKey(carId: carId, tripRoute: trip.route, carRoute: car.route)
            if tracker.isTracking, key == trackingKey { return }
            trackingKey = key
            tracker.start(
                tripId: tripId, carId: carId,
                mainRoute: TripSessionLogic.routeLine(from: trip.route) ?? RouteLine([]),
                carRoute: TripSessionLogic.routeLine(from: car.route))
        } else if tracker.isTracking || trackingKey != nil {
            stopTrackingNow()
        }
        isTracking = tracker.isTracking
    }

    private func removeListeners() {
        tripListener?.remove()
        memberListener?.remove()
        carListener?.remove()
        positionsListener?.remove()
        tripListener = nil
        memberListener = nil
        carListener = nil
        positionsListener = nil
        listeningCarId = nil
    }
}
