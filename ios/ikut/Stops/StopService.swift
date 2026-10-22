import CoreLocation
import FirebaseFirestore
import Foundation

/// What the stop card needs from the backend. A protocol so previews and tests can fake it.
protocol StopServing: Sendable {
    /// Asks for a stop and returns the new event's id. `place` is the requester's proposed stop.
    func request(type: EventType, place: StopPlace?, context: StopContext, snapshot: ReportSnapshot) async throws -> String
    /// Names another place for an open request: pins it for the lead car or organizer, otherwise
    /// records it as the viewer's car's suggestion (a "Not now" that carries a place).
    func suggest(place: StopPlace, eventId: String, canPin: Bool, context: StopContext) async throws
}

/// Requests, votes on, pins and closes stops (`trips/{id}/events` and their `votes`).
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
                answer: .yes, suggestion: place)
        }
        return id
    }

    func suggest(place: StopPlace, eventId: String, canPin: Bool, context: StopContext) async throws {
        if canPin {
            try await pin(tripId: context.tripId, eventId: eventId, place: place, userId: context.userId)
        } else {
            try await vote(
                tripId: context.tripId, eventId: eventId, carId: context.carId, userId: context.userId,
                answer: .notNow, suggestion: place)
        }
    }

    /// The viewer's car answers. `suggestion` names another place (a "Not now" that carries a place)
    /// or the requester's own proposal. Replaces the car's earlier vote. `agree` is written next to
    /// `answer` so phones on an older build still count it.
    func vote(
        tripId: String, eventId: String, carId: String, userId: String, answer: StopAnswer,
        suggestion: StopPlace? = nil
    ) async throws {
        nonisolated(unsafe) var data: [String: Any] = [
            "userId": userId, "agree": answer.agree, "answer": answer.rawValue, "at": FieldValue.serverTimestamp(),
        ]
        if let suggestion { data["suggestion"] = Self.suggestionData(suggestion) }
        nonisolated(unsafe) let payload = data
        let ref = Firestore.firestore().document("\(Self.votes(tripId: tripId, eventId: eventId))/\(carId)")
        try await ServerWrite.commit { try await ref.setData(payload) }
    }

    /// Pins `place` and marks the request pinned. Lead car's tracker or organizer only; anyone else
    /// is rejected by the rules.
    func pin(tripId: String, eventId: String, place: StopPlace, userId: String) async throws {
        nonisolated(unsafe) let data: [String: Any] = [
            "place": [
                "name": place.name, "coordinate": place.coordinate, "routeOffset": place.routeOffset,
                "pinnedBy": userId,
            ] as [String: Any],
            "status": StopStatus.pinned.rawValue,
        ]
        let ref = Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
        try await ServerWrite.commit { try await ref.updateData(data) }
    }

    /// Closes the request: `status`, why and by whom, and `expiresAt` = now (phones on an older build,
    /// and the QA scripts, read "no expiresAt" as open). The asker may only cancel; the lead car or
    /// organizer closes it as left or no answer.
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

    static func suggestionData(_ place: StopPlace) -> [String: Any] {
        ["name": place.name, "coordinate": place.coordinate, "routeOffset": place.routeOffset]
    }

    // MARK: Actions for the card and the pill

    /// Live actions. Failures are reported to `onError`.
    @MainActor
    static func actions(
        context: StopContext, service: StopService = StopService(),
        onError: @escaping @MainActor @Sendable (Error) -> Void = { _ in }
    ) -> StopRequestActions {
        StopRequestActions(
            answer: { eventId, answer in
                Task {
                    do {
                        try await service.vote(
                            tripId: context.tripId, eventId: eventId, carId: context.carId,
                            userId: context.userId, answer: answer)
                    } catch { onError(error) }
                }
            },
            pin: { eventId, place in
                Task {
                    do {
                        try await service.pin(
                            tripId: context.tripId, eventId: eventId, place: place, userId: context.userId)
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

    /// Every open stop request with its votes, the cars and the viewer's progress along the route,
    /// re-emitted on every change and every `refresh` seconds (distances, "here" and the ten minute
    /// "No answer" move with time). When this phone is the lead car's or the organizer's, it also
    /// closes requests nobody answered in ten minutes (there is no cloud job, that needs the Blaze plan).
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
    /// Requests this phone already asked to close as "No answer".
    private var closing: Set<String> = []

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
            let snapshot = context.snapshot()
            let offset = snapshot.map {
                EventService.routeOffset(
                    for: $0.coordinate, route: context.mainRoute ?? $0.route, previousOffset: $0.previousOffset)
            }
            let fixes = context.carFixes()
            func state(_ event: TripEvent, votes: [StopVote]) -> StopRequestState? {
                StopLogic.tally(
                    event: event, votes: votes, cars: cars, myUserId: context.userId, myCarId: context.carId,
                    isOrganizer: context.isOrganizer, viewerOffset: offset, now: now, fixes: fixes)
            }
            let requests = StopLogic.openStops(in: events, now: now).compactMap { event in
                event.id.flatMap { id in state(event, votes: votes[id] ?? []) }
            }
            let missed = StopLogic.missedAsk(in: events, myCarId: context.carId, now: now)
                .flatMap { state($0, votes: []) }
            closeUnanswered(events: events, cars: cars, now: now)
            if recordIfChanged(StopBoard(requests: requests, missed: missed)) {
                continuation.yield(StopBoard(requests: requests, missed: missed))
            }
        }
    }

    /// The lead car's tracker or the organizer closes a request nobody pinned in ten minutes.
    @MainActor
    private func closeUnanswered(events: [TripEvent], cars: [Car], now: Date) {
        guard context.isOrganizer || StopLogic.isLeadTracker(cars: cars, myCarId: context.carId, myUserId: context.userId)
        else { return }
        for event in StopLogic.noAnswerToClose(in: events, now: now) {
            guard let id = event.id, markClosing(id) else { continue }
            let context = self.context
            Task {
                try? await StopService().close(
                    tripId: context.tripId, eventId: id, reason: .noAnswer, userId: context.userId)
            }
        }
    }

    private func markClosing(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return closing.insert(id).inserted
    }

    private func recordIfChanged(_ board: StopBoard) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = lastEmitted != board
        lastEmitted = board
        return changed
    }
}
