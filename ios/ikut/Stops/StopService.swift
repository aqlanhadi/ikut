import CoreLocation
import FirebaseFirestore
import Foundation

/// What `RequestStopSheet` needs from the backend. A protocol so previews and tests can fake it.
protocol StopServing: Sendable {
    /// Asks for a stop and returns the new event's id. `place` is the requester's proposed stop.
    func request(type: EventType, place: StopPlace?, context: StopContext, snapshot: ReportSnapshot) async throws -> String
    /// Names another place for an open request: pins it for the lead car or organizer, otherwise
    /// records it as the viewer's car's suggestion (a "no" vote).
    func suggest(place: StopPlace, eventId: String, canPin: Bool, context: StopContext) async throws
}

/// Requests, votes on, pins and resolves stops (`trips/{id}/events` and their `votes`).
///
/// Writes wait for the server's verdict so a rule rejection throws; if the server hasn't answered
/// within `EventService.writeTimeout` (offline) they return and Firestore keeps the write queued.
struct StopService: StopServing {
    static func votes(tripId: String, eventId: String) -> String {
        "\(FirestorePaths.event(tripId: tripId, eventId: eventId))/votes"
    }

    // MARK: Writes

    /// Writes a stop event through `EventService.report`. A `place` becomes the requesting car's
    /// suggestion (an agreeing vote carrying the place); the lead car or organizer pins it.
    func request(type: EventType, place: StopPlace?, context: StopContext, snapshot: ReportSnapshot) async throws -> String {
        let id = try await EventService.report(
            type: type, tripId: context.tripId, carId: context.carId, authorId: context.userId,
            location: snapshot.coordinate, heading: snapshot.heading,
            route: context.mainRoute ?? snapshot.route, previousOffset: snapshot.previousOffset)
        if let place {
            try await vote(
                tripId: context.tripId, eventId: id, carId: context.carId, userId: context.userId,
                agree: true, suggestion: place)
        }
        return id
    }

    func suggest(place: StopPlace, eventId: String, canPin: Bool, context: StopContext) async throws {
        if canPin {
            try await pin(tripId: context.tripId, eventId: eventId, place: place, userId: context.userId)
        } else {
            try await vote(
                tripId: context.tripId, eventId: eventId, carId: context.carId, userId: context.userId,
                agree: false, suggestion: place)
        }
    }

    /// The viewer's car votes. `suggestion` names another place (with `agree: false`) or the
    /// requester's own proposal. Replaces the car's earlier vote.
    func vote(
        tripId: String, eventId: String, carId: String, userId: String, agree: Bool,
        suggestion: StopPlace? = nil
    ) async throws {
        nonisolated(unsafe) var data: [String: Any] = ["userId": userId, "agree": agree, "at": FieldValue.serverTimestamp()]
        if let suggestion { data["suggestion"] = Self.suggestionData(suggestion) }
        nonisolated(unsafe) let payload = data
        let ref = Firestore.firestore().document("\(Self.votes(tripId: tripId, eventId: eventId))/\(carId)")
        try await ServerWrite.commit { try await ref.setData(payload) }
    }

    /// Pins `place`. Lead car's tracker or organizer only; anyone else is rejected by the rules.
    func pin(tripId: String, eventId: String, place: StopPlace, userId: String) async throws {
        nonisolated(unsafe) let data: [String: Any] = [
            "place": [
                "name": place.name, "coordinate": place.coordinate, "routeOffset": place.routeOffset,
                "pinnedBy": userId,
            ] as [String: Any]
        ]
        let ref = Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
        try await ServerWrite.commit { try await ref.updateData(data) }
    }

    /// Ends the request (everyone arrived, or it was cancelled) by expiring it now.
    func resolve(tripId: String, eventId: String, now: Date = Date()) async throws {
        let ref = Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
        try await ServerWrite.commit { try await ref.updateData(["expiresAt": Timestamp(date: now)]) }
    }

    static func suggestionData(_ place: StopPlace) -> [String: Any] {
        ["name": place.name, "coordinate": place.coordinate, "routeOffset": place.routeOffset]
    }

    // MARK: Actions for the card

    /// Live card actions for `state`'s request. Failures are reported to `onError`.
    @MainActor
    static func actions(
        context: StopContext, state: StopRequestState, service: StopService = StopService(),
        suggestAnother: @escaping @MainActor @Sendable () -> Void,
        onError: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) -> StopRequestActions {
        let eventId = state.eventId
        return StopRequestActions(
            vote: { agree in
                Task {
                    do {
                        try await service.vote(
                            tripId: context.tripId, eventId: eventId, carId: context.carId,
                            userId: context.userId, agree: agree)
                    } catch { onError(error) }
                }
            },
            suggestAnother: suggestAnother,
            pin: { place in
                Task {
                    do {
                        try await service.pin(
                            tripId: context.tripId, eventId: eventId, place: place, userId: context.userId)
                    } catch { onError(error) }
                }
            },
            resolve: {
                Task {
                    do { try await service.resolve(tripId: context.tripId, eventId: eventId) } catch { onError(error) }
                }
            })
    }

    // MARK: Listening

    /// The latest open stop request with its votes, the cars and the viewer's progress along the
    /// route, re-emitted on every change and every `refresh` seconds (distance and expiry move
    /// with time). Emits nil when no stop request is open.
    static func listen(context: StopContext, refresh: Duration = .seconds(10)) -> AsyncStream<StopRequestState?> {
        AsyncStream { continuation in
            let hub = StopHub(context: context, continuation: continuation)
            hub.start(refresh: refresh)
            continuation.onTermination = { _ in hub.stop() }
        }
    }
}

/// Joins the events, votes and cars listeners into one state stream.
private final class StopHub: @unchecked Sendable {
    private let context: StopContext
    private let continuation: AsyncStream<StopRequestState?>.Continuation
    private let lock = NSLock()
    private var events: [TripEvent] = []
    private var votes: [StopVote] = []
    private var cars: [Car] = []
    private var votesEventId: String?
    private var registrations: [ListenerRegistration] = []
    private var votesRegistration: ListenerRegistration?
    private var ticker: Task<Void, Never>?
    private var lastEmitted: StopRequestState??

    init(context: StopContext, continuation: AsyncStream<StopRequestState?>.Continuation) {
        self.context = context
        self.continuation = continuation
    }

    func start(refresh: Duration) {
        let db = Firestore.firestore()
        let eventsReg = db.collection(FirestorePaths.events(tripId: context.tripId)).addSnapshotListener { [self] snapshot, _ in
            guard let snapshot else { return }
            let decoded = snapshot.documents.compactMap { try? $0.data(as: TripEvent.self) }
            lock.lock()
            events = decoded
            lock.unlock()
            watchVotes()
            emit()
        }
        let carsReg = db.collection(FirestorePaths.cars(tripId: context.tripId)).addSnapshotListener { [self] snapshot, _ in
            guard let snapshot else { return }
            let decoded = snapshot.documents.compactMap { try? $0.data(as: Car.self) }
            lock.lock()
            cars = decoded
            lock.unlock()
            emit()
        }
        lock.lock()
        registrations = [eventsReg, carsReg]
        lock.unlock()
        ticker = Task { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: refresh)
                if Task.isCancelled { break }
                emit()
            }
        }
    }

    func stop() {
        lock.lock()
        let all = registrations + (votesRegistration.map { [$0] } ?? [])
        registrations = []
        votesRegistration = nil
        lock.unlock()
        all.forEach { $0.remove() }
        ticker?.cancel()
    }

    /// Re-points the votes listener at the current open stop request.
    private func watchVotes() {
        lock.lock()
        let eventId = StopLogic.activeStop(in: events, now: Date())?.id
        guard eventId != votesEventId else { lock.unlock(); return }
        votesEventId = eventId
        let old = votesRegistration
        votesRegistration = nil
        votes = []
        lock.unlock()
        old?.remove()
        guard let eventId else { return }
        let reg = Firestore.firestore().collection(StopService.votes(tripId: context.tripId, eventId: eventId))
            .addSnapshotListener { [self] snapshot, _ in
                guard let snapshot else { return }
                let decoded = snapshot.documents.compactMap { try? $0.data(as: StopVote.self) }
                lock.lock()
                votes = decoded
                lock.unlock()
                emit()
            }
        lock.lock()
        if votesEventId == eventId { votesRegistration = reg } else { lock.unlock(); reg.remove(); return }
        lock.unlock()
    }

    private func emit() {
        let context = self.context
        lock.lock()
        let (events, votes, cars) = (self.events, self.votes, self.cars)
        lock.unlock()
        Task { @MainActor [self] in
            let now = Date()
            var state: StopRequestState?
            if let stop = StopLogic.activeStop(in: events, now: now) {
                let snapshot = context.snapshot()
                let offset = snapshot.map {
                    EventService.routeOffset(
                        for: $0.coordinate, route: context.mainRoute ?? $0.route, previousOffset: $0.previousOffset)
                }
                state = StopLogic.tally(
                    event: stop, votes: votes, cars: cars, myUserId: context.userId, myCarId: context.carId,
                    isOrganizer: context.isOrganizer, viewerOffset: offset, now: now)
            }
            if recordIfChanged(state) { continuation.yield(state) }
        }
    }

    private func recordIfChanged(_ state: StopRequestState?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = lastEmitted == nil || lastEmitted! != state
        lastEmitted = .some(state)
        return changed
    }
}
