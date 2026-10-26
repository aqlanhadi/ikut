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
        /// The trip has started (`LobbyLogic.isStarted`): opening it goes to the driving map.
        var started = false
        /// The server said this phone can't read the trip: it left, was removed, or the trip is gone. Home moves it to
        /// Past trips and the app no longer opens into it. A read that failed for any other reason (no signal) is not
        /// this: the trip stays in Now.
        var gone = false
    }

    /// When a trip read from Now moves to Past trips, with the date it is listed under: it ended (its end), or this
    /// phone is no longer in it (now, when it found out). Signed out every read is refused, so that says nothing.
    static func movesToPast(_ read: Read, signedIn: Bool, now: Date = Date()) -> Date? {
        if let endedAt = read.endedAt { return endedAt }
        return read.gone && signedIn ? now : nil
    }

    /// Whether a failed read means this phone is no longer in the trip: the rules refuse a trip to anyone not a member
    /// (or a trip that doesn't exist), so a refusal or a missing trip is "gone"; anything else (offline) is not known.
    static func isGone(_ error: Error?) -> Bool {
        guard let error = error as NSError?, error.domain == FirestoreErrorDomain else { return false }
        return error.code == FirestoreErrorCode.permissionDenied.rawValue || error.code == FirestoreErrorCode.notFound.rawValue
    }

    /// One read of the trip, its cars and its stops, as a member can (no listener). A trip that can't be read says
    /// "In progress" (and is `gone` when the server refused it); cars or stops that can't be read are left out of the
    /// line. `line: false` reads the trip alone (the app's launch only needs whether it ended or started).
    @MainActor
    static func load(tripId: String, line: Bool = true, db: Firestore = Firestore.firestore()) async -> Read {
        let trip: Trip
        do {
            let snapshot = try await db.document(FirestorePaths.trip(tripId)).getDocument()
            guard snapshot.exists else { return Read(line: fallbackStatus, gone: true) }
            trip = try snapshot.data(as: Trip.self)
        } catch {
            return Read(line: fallbackStatus, gone: isGone(error))
        }
        var cars: [Car] = []
        var stops: [PlannedStop] = []
        if line {
            cars = (try? await db.collection(FirestorePaths.cars(tripId: tripId)).getDocuments().decoded(Car.self)) ?? []
            stops = (try? await db.collection(FirestorePaths.stops(tripId: tripId)).getDocuments().decoded(PlannedStop.self)) ?? []
        }
        return Read(line: line ? status(trip: trip, cars: cars, stops: stops) : fallbackStatus,
                    endedAt: trip.status == .ended ? (trip.endedAt ?? Date()) : nil,
                    name: trip.name, destination: trip.destination.name, started: LobbyLogic.isStarted(trip: trip))
    }
}
