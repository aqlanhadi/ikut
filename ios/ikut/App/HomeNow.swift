import FirebaseFirestore
import Foundation

/// Home's "Now" section (MapFirst B1): the trips this phone is in that haven't ended, each with its live status line.
enum HomeNow {
    /// Trips not yet ended go to Now, ended ones to Past trips; each keeps its order (newest first).
    static func split(_ entries: [PastTrips.Entry]) -> (now: [PastTrips.Entry], past: [PastTrips.Entry]) {
        (entries.filter { $0.endedAt == nil }, entries.filter { $0.endedAt != nil })
    }

    /// What a Now row says while its trip hasn't loaded, or couldn't.
    static let fallbackStatus = "In progress"

    /// "Gathering · 4 of 5 cars ready · meet 12:00", or "On the move · since 12:05" once started. Cars are ready
    /// when a phone is sharing, counted as the lobby does; the meet time is the meeting point's, as the lobby shows it.
    /// A trip that didn't load says "In progress".
    static func status(trip: Trip?, cars: [Car], stops: [PlannedStop], timeZone: TimeZone = .current) -> String {
        guard let trip else { return fallbackStatus }
        if trip.status == .ended { return LobbyLogic.title(started: false, ended: true) }
        if LobbyLogic.isStarted(trip: trip) {
            guard let since = trip.startedAt else { return LobbyLogic.title(started: true, ended: false) }
            return "On the move · since \(StopFormat.clock(since, timeZone: timeZone))"
        }
        var parts = [LobbyLogic.title(started: false, ended: false)]
        let grouped = LobbyLogic.group(cars: cars, members: [])
        if !grouped.isEmpty {
            parts.append("\(grouped.filter(\.hasTracker).count) of \(grouped.count) cars ready")
        }
        if let meetAt = meetTime(stops) { parts.append("meet \(StopFormat.clock(meetAt, timeZone: timeZone))") }
        return parts.joined(separator: " · ")
    }

    /// The meeting point's time: the first stop when it is a meeting point that isn't skipped (as `TripSessionLogic.meetingPoint`).
    static func meetTime(_ stops: [PlannedStop]) -> Date? {
        guard let first = stops.min(by: { $0.order < $1.order }), first.kind == .meet, first.isActive else { return nil }
        return first.meetAt
    }

    /// What one read of a trip found.
    struct Read: Equatable {
        var line: String
        /// Set when the trip ended on the server: Home moves it to Past trips.
        var endedAt: Date?
        var name: String?
        var destination: String?
    }

    /// One read of the trip, its cars and its stops, as a member can (no listener). A trip that can't be read says
    /// "In progress"; cars or stops that can't be read are left out of the line.
    @MainActor
    static func load(tripId: String, db: Firestore = Firestore.firestore()) async -> Read {
        guard let trip = try? await db.document(FirestorePaths.trip(tripId)).getDocument(as: Trip.self) else {
            return Read(line: fallbackStatus)
        }
        let cars = (try? await db.collection(FirestorePaths.cars(tripId: tripId)).getDocuments().decoded(Car.self)) ?? []
        let stops = (try? await db.collection(FirestorePaths.stops(tripId: tripId)).getDocuments().decoded(PlannedStop.self)) ?? []
        return Read(line: status(trip: trip, cars: cars, stops: stops),
                    endedAt: trip.status == .ended ? (trip.endedAt ?? Date()) : nil,
                    name: trip.name, destination: trip.destination.name)
    }
}
