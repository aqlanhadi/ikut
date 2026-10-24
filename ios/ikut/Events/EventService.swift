import CoreLocation
import FirebaseFirestore
import Foundation

/// Reports, clears, undoes and listens to trip events (`trips/{tripId}/events`).
enum EventService {
    // MARK: Pure helpers

    /// Trims whitespace and newlines, caps the length, and returns nil when nothing is left.
    ///
    /// The rules' `size()` counts UTF-16 code units (verified on the emulator: 140 emoji pass, 141
    /// fail), so the cap is applied in UTF-16 units, dropping whole characters so none is split.
    static func sanitizedMessage(_ message: String?) -> String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var capped = ""
        var units = 0
        for character in trimmed {
            units += character.utf16.count
            if units > StopLogic.maxMessageLength { break }
            capped.append(character)
        }
        capped = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// Meters along `route` for `location`. `previousOffset` picks the segment to search near, so a
    /// route that doubles back resolves to the part the car is on. Without a usable route the
    /// previous offset (or 0) is returned.
    static func routeOffset(
        for location: CLLocationCoordinate2D, route: RouteLine?, previousOffset: CLLocationDistance?
    ) -> CLLocationDistance {
        guard let route, let projection = route.project(location, hint: previousOffset.map { segmentIndex(in: route, atOffset: $0) })
        else { return max(0, previousOffset ?? 0) }
        return projection.offset
    }

    /// Index of the segment that contains `offset` (clamped to the route).
    static func segmentIndex(in route: RouteLine, atOffset offset: CLLocationDistance) -> Int {
        guard route.segmentCount > 0 else { return 0 }
        var lo = 0
        var hi = route.segmentCount - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if route.cumulative[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Builds the event to write. Heading is normalised to 0..<360 (CoreLocation reports -1 when unknown).
    static func makeEvent(
        type: EventType, authorId: String, carId: String, location: CLLocationCoordinate2D,
        heading: Double, routeOffset: Double, message: String?, now: Date = Date()
    ) -> TripEvent {
        let normalized = heading.isFinite && heading >= 0 ? heading.truncatingRemainder(dividingBy: 360) : 0
        return TripEvent(
            type: type, location: GeoPoint(latitude: location.latitude, longitude: location.longitude),
            heading: normalized, routeOffset: routeOffset, authorId: authorId, carId: carId,
            createdAt: now, message: sanitizedMessage(message))
    }

    /// Events that have not expired at `now`. A nil `expiresAt` never expires. Newest first.
    static func activeEvents(_ events: [TripEvent], now: Date) -> [TripEvent] {
        events
            .filter { event in event.expiresAt.map { $0 > now } ?? true }
            .sorted { ($0.createdAt ?? .distantFuture) > ($1.createdAt ?? .distantFuture) }
    }

    // MARK: Firestore

    /// Writes a new event and returns its id.
    ///
    /// `createdAt` is the client clock (the rules accept ±5 min of request time) rather than a
    /// server timestamp, so `expiresAt` derived from it always satisfies `expiresAt > createdAt`.
    @discardableResult
    static func report(
        type: EventType,
        tripId: String,
        carId: String,
        authorId: String,
        location: CLLocationCoordinate2D,
        heading: Double,
        route: RouteLine?,
        previousOffset: CLLocationDistance?,
        message: String? = nil
    ) async throws -> String {
        let offset = routeOffset(for: location, route: route, previousOffset: previousOffset)
        let event = makeEvent(
            type: type, authorId: authorId, carId: carId, location: location, heading: heading,
            routeOffset: offset, message: message)
        let ref = Firestore.firestore().collection(FirestorePaths.events(tripId: tripId)).document()
        try await write(event, to: ref)
        return ref.documentID
    }

    /// How long `report` waits for the server to accept the write before treating it as queued offline.
    static let writeTimeout: Duration = .seconds(8)

    /// Writes `event` and waits for the server's verdict, so rule rejections surface as errors.
    ///
    /// `try await ref.setData(from:)` does not wait: it resolves to the synchronous overload whose
    /// completion is optional, so errors would be lost. If the server hasn't answered within
    /// `writeTimeout` (offline), this returns and Firestore keeps the write queued.
    private static func write(_ event: TripEvent, to ref: DocumentReference) async throws {
        let outcome = WriteOutcome<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                outcome.install(continuation)
                do {
                    try ref.setData(from: event) { error in outcome.finish(error) }
                } catch {
                    outcome.finish(error)
                    return
                }
                Task {
                    try? await Task.sleep(for: writeTimeout)
                    outcome.finish(nil)
                }
            }
        } onCancel: {
            outcome.finish(CancellationError())
        }
    }

    /// Deletes an event: the author, or the organizer, while the trip is active.
    static func undo(tripId: String, eventId: String) async throws {
        try await Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId)).delete()
    }

    /// Expires an event now. Author only.
    static func clear(tripId: String, eventId: String, now: Date = Date()) async throws {
        try await Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
            .updateData(["expiresAt": Timestamp(date: now)])
    }

    /// Active events, newest first, re-emitted on every change. Expiry is evaluated when a
    /// snapshot arrives, so callers that need events to disappear on time should re-filter with
    /// `activeEvents(_:now:)` on a timer. Undecodable documents are skipped.
    static func listen(tripId: String) -> AsyncStream<[TripEvent]> {
        AsyncStream { continuation in
            let registration = Firestore.firestore().collection(FirestorePaths.events(tripId: tripId))
                .addSnapshotListener { snapshot, _ in
                    guard let snapshot else { return }
                    let events = snapshot.decoded(TripEvent.self)
                    continuation.yield(activeEvents(events, now: Date()))
                }
            nonisolated(unsafe) let handle = registration
            continuation.onTermination = { _ in handle.remove() }
        }
    }
}
