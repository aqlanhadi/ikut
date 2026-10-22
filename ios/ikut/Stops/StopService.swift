import CoreLocation
import FirebaseFirestore
import Foundation

/// What the stop card needs from the backend. A protocol so previews and tests can fake it.
protocol StopServing: Sendable {
    /// Asks for a stop and returns the new event's id. `message` is a passenger's optional note.
    func request(type: EventType, message: String?, context: StopContext, snapshot: ReportSnapshot) async throws -> String
}

/// Requests, OKs and closes stops (`trips/{id}/events` and their `votes`).
///
/// Writes wait for the server's verdict so a rule rejection throws; if the server hasn't answered
/// within `EventService.writeTimeout` (offline) they return and Firestore keeps the write queued.
struct StopService: StopServing {
    static func votes(tripId: String, eventId: String) -> String {
        "\(FirestorePaths.event(tripId: tripId, eventId: eventId))/votes"
    }

    // MARK: Writes

    /// Writes a stop event through `EventService.report`: the reason in `type`, the optional message,
    /// and `expiresAt` = 30 minutes after it was asked (set by the event's category), so it closes
    /// itself if nobody does.
    func request(type: EventType, message: String?, context: StopContext, snapshot: ReportSnapshot) async throws -> String {
        try await EventService.report(
            type: type, tripId: context.tripId, carId: context.carId, authorId: context.userId,
            location: snapshot.coordinate, heading: snapshot.heading,
            route: context.mainRoute ?? snapshot.route, previousOffset: snapshot.previousOffset,
            message: StopLogic.cleanedMessage(message))
    }

    /// The viewer's car says OK. Replaces the car's earlier OK (a second phone in the car writes the same document).
    func ok(tripId: String, eventId: String, carId: String, userId: String) async throws {
        nonisolated(unsafe) let payload: [String: Any] = ["userId": userId, "at": FieldValue.serverTimestamp()]
        let ref = Firestore.firestore().document("\(Self.votes(tripId: tripId, eventId: eventId))/\(carId)")
        try await ServerWrite.commit { try await ref.setData(payload) }
    }

    /// Closes the request: `status`, why and by whom, and `expiresAt` = now (phones on an older build,
    /// and the QA scripts, read "no expiresAt" as open). The asker may cancel or say the convoy has
    /// stopped; the lead car or organizer says it has stopped.
    func close(
        tripId: String, eventId: String, reason: StopClosedReason, userId: String, now: Date = Date()
    ) async throws {
        nonisolated(unsafe) let data: [String: Any] = [
            "status": StopStatus.closed.rawValue, "closedReason": reason.rawValue, "closedBy": userId,
            "expiresAt": Timestamp(date: now),
        ]
        let ref = Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
        try await ServerWrite.commit { try await ref.updateData(data) }
    }

    // MARK: Actions for the card and the pill

    /// Live actions. Failures are reported to `onError`.
    @MainActor
    static func actions(
        context: StopContext, service: StopService = StopService(),
        onError: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) -> StopRequestActions {
        StopRequestActions(
            ok: { eventId in
                Task {
                    do {
                        try await service.ok(
                            tripId: context.tripId, eventId: eventId, carId: context.carId, userId: context.userId)
                    } catch { onError(error) }
                }
            },
            close: { eventId, reason in
                Task {
                    do {
                        try await service.close(
                            tripId: context.tripId, eventId: eventId, reason: reason, userId: context.userId)
                    } catch { onError(error) }
                }
            })
    }

    // MARK: Listening

    /// Every open stop request with its votes and the cars, re-emitted on every change and every
    /// `refresh` seconds (a request closes itself 30 minutes after it was asked, and nothing is written
    /// for that, so the clock has to be looked at).
    static func listen(context: StopContext, refresh: Duration = .seconds(10)) -> AsyncStream<StopBoard> {
        AsyncStream { continuation in
            let hub = StopHub(context: context, continuation: continuation)
            hub.start(refresh: refresh)
            continuation.onTermination = { _ in hub.stop() }
        }
    }
}

/// Joins the events, votes and cars listeners into one board stream.
private final class StopHub: @unchecked Sendable {
    private let context: StopContext
    private let continuation: AsyncStream<StopBoard>.Continuation
    private let lock = NSLock()
    private var events: [TripEvent] = []
    private var votes: [String: [StopVote]] = [:]
    private var cars: [Car] = []
    private var registrations: [ListenerRegistration] = []
    private var votesRegistrations: [String: ListenerRegistration] = [:]
    private var ticker: Task<Void, Never>?
    private var lastEmitted: StopBoard?

    init(context: StopContext, continuation: AsyncStream<StopBoard>.Continuation) {
        self.context = context
        self.continuation = continuation
    }

    func start(refresh: Duration) {
        let db = Firestore.firestore()
        let eventsReg = db.collection(FirestorePaths.events(tripId: context.tripId)).addSnapshotListener { [self] snapshot, _ in
            guard let snapshot else { return }
            let decoded = snapshot.decoded(TripEvent.self)
            lock.lock()
            events = decoded
            lock.unlock()
            watchVotes()
            emit()
        }
        let carsReg = db.collection(FirestorePaths.cars(tripId: context.tripId)).addSnapshotListener { [self] snapshot, _ in
            guard let snapshot else { return }
            let decoded = snapshot.decoded(Car.self)
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
                watchVotes()
                emit()
            }
        }
    }

    func stop() {
        lock.lock()
        let all = registrations + Array(votesRegistrations.values)
        registrations = []
        votesRegistrations = [:]
        lock.unlock()
        all.forEach { $0.remove() }
        ticker?.cancel()
    }

    /// Keeps one votes listener per open request.
    private func watchVotes() {
        lock.lock()
        let open = Set(StopLogic.openStops(in: events, now: Date()).compactMap(\.id))
        let gone = votesRegistrations.keys.filter { !open.contains($0) }
        let removed = gone.compactMap { votesRegistrations.removeValue(forKey: $0) }
        gone.forEach { votes[$0] = nil }
        let added = open.filter { votesRegistrations[$0] == nil && !watching.contains($0) }
        watching.formUnion(added)
        lock.unlock()
        removed.forEach { $0.remove() }
        for eventId in added {
            let reg = Firestore.firestore().collection(StopService.votes(tripId: context.tripId, eventId: eventId))
                .addSnapshotListener { [self] snapshot, _ in
                    guard let snapshot else { return }
                    let decoded = snapshot.decoded(StopVote.self)
                    lock.lock()
                    votes[eventId] = decoded
                    lock.unlock()
                    emit()
                }
            lock.lock()
            watching.remove(eventId)
            if open.contains(eventId) { votesRegistrations[eventId] = reg } else { lock.unlock(); reg.remove(); continue }
            lock.unlock()
        }
    }

    /// Request ids whose votes listener is being set up.
    private var watching: Set<String> = []

    private func emit() {
        let context = self.context
        lock.lock()
        let (events, votes, cars) = (self.events, self.votes, self.cars)
        lock.unlock()
        Task { @MainActor [self] in
            let now = Date()
            let requests = StopLogic.openStops(in: events, now: now).compactMap { event in
                event.id.flatMap { id in
                    StopLogic.tally(
                        event: event, votes: votes[id] ?? [], cars: cars, myUserId: context.userId,
                        myCarId: context.carId, isOrganizer: context.isOrganizer)
                }
            }
            let board = StopBoard(requests: requests)
            if recordIfChanged(board) { continuation.yield(board) }
        }
    }

    private func recordIfChanged(_ board: StopBoard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = lastEmitted != board
        lastEmitted = board
        return changed
    }
}
