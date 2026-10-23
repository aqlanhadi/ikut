import FirebaseFirestore
import Foundation
import Observation

/// Fetches what a recap needs once (members can still read an ended trip and its subcollections),
/// merges it with the copy cached on the phone, and caches the result.
enum RecapService {
    @MainActor static func fetch(tripId: String, db: Firestore = Firestore.firestore()) async throws -> RecapSnapshot {
        let trip = try await db.document(FirestorePaths.trip(tripId)).getDocument(as: Trip.self)
        let cars = try await db.collection(FirestorePaths.cars(tripId: tripId)).getDocuments().decoded(Car.self)
        let members = try await db.collection(FirestorePaths.members(tripId: tripId)).getDocuments().decoded(Member.self)
        // Positions and events may already be purged (7 days after the end); an empty list is fine.
        let positions = (try? await db.collection(FirestorePaths.positions(tripId: tripId)).getDocuments().decoded(Position.self)) ?? []
        let events = (try? await db.collection(FirestorePaths.events(tripId: tripId)).getDocuments().decoded(TripEvent.self)) ?? []

        return RecapSnapshot(
            tripId: tripId, name: trip.name, destinationName: trip.destination.name,
            destinationLatitude: trip.destination.coordinate.latitude,
            destinationLongitude: trip.destination.coordinate.longitude,
            route: trip.route, createdAt: trip.createdAt, endedAt: trip.endedAt,
            cars: cars.compactMap { c in
                c.id.map { RecapCar(id: $0, name: c.name, color: c.color, number: c.number, isLead: c.isLead) }
            },
            memberNames: members.keyedByID { $0.displayName },
            memberCars: members.keyedByID { $0.carId },
            positions: positions.compactMap { p in
                p.id.map {
                    RecapPosition(carId: $0, latitude: p.location.latitude, longitude: p.location.longitude,
                                  convoyOffset: p.convoyOffset, updatedAt: p.updatedAt)
                }
            },
            events: events.compactMap { e in
                e.id.map {
                    RecapEvent(id: $0, type: e.type.rawValue, carId: e.carId, authorId: e.authorId,
                               latitude: e.location.latitude, longitude: e.location.longitude,
                               createdAt: e.createdAt, expiresAt: e.expiresAt, message: e.message)
                }
            }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) })
    }

    // MARK: Cache

    private static func cacheURL(_ tripId: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = dir.appendingPathComponent("recaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = tripId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return folder.appendingPathComponent("\(safe).json")
    }

    static func cached(tripId: String) -> RecapSnapshot? {
        guard let url = cacheURL(tripId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecapSnapshot.self, from: data)
    }

    static func save(_ snapshot: RecapSnapshot) {
        guard let url = cacheURL(snapshot.tripId), let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Loads a recap: the cached copy straight away, then the merged fresh one.
@Observable @MainActor
final class RecapModel {
    let tripId: String
    private(set) var snapshot: RecapSnapshot?
    private(set) var recap: Recap?
    private(set) var originName: String?
    private(set) var errorMessage: String?

    /// Plain words, without the system's message.
    static let couldntLoad = "Couldn’t load this recap. Check your connection and try again."

    /// For tests: a failed load.
    init(failedTripId: String) {
        tripId = failedTripId
        errorMessage = Self.couldntLoad
    }

    init(tripId: String) {
        self.tripId = tripId
        if let cached = RecapService.cached(tripId: tripId) { apply(cached) }
    }

    /// For previews and the screenshot test.
    init(snapshot: RecapSnapshot, originName: String? = nil) {
        tripId = snapshot.tripId
        self.originName = originName
        apply(snapshot)
    }

    /// Nothing to show yet: not loaded and not failed.
    var isLoading: Bool { snapshot == nil && errorMessage == nil }

    /// Try again after a load that couldn't finish: back to loading, then the same load.
    func retry(myUserId: String?) async {
        guard snapshot == nil else { return }
        errorMessage = nil
        await load(myUserId: myUserId)
    }

    func load(myUserId: String?) async {
        do {
            let fresh = try await RecapService.fetch(tripId: tripId)
            let merged = RecapLogic.merge(cached: RecapService.cached(tripId: tripId), fresh: fresh)
            RecapService.save(merged)
            PastTrips.record(tripId: tripId, name: merged.name, destination: merged.destinationName, endedAt: merged.endedAt,
                             others: merged.memberNames.isEmpty ? nil : PastTrips.others(from: merged.memberNames, excluding: myUserId))
            apply(merged)
            errorMessage = nil
        } catch {
            if snapshot == nil { errorMessage = Self.couldntLoad }
        }
        if originName == nil, let first = snapshot.flatMap({ Polyline.decode($0.route).first }) {
            originName = await RouteBuilder.placeName(at: first)
            if let snapshot { apply(snapshot) }
        }
    }

    private func apply(_ s: RecapSnapshot) {
        snapshot = s
        recap = RecapLogic.recap(s, originName: originName)
    }
}

/// Trips this phone has been in, newest first (UserDefaults). The server has no per-user trip
/// list (trips can't be listed), so Home's "Past trips" is built from this.
enum PastTrips {
    struct Entry: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var destination: String
        var endedAt: Date?
        var seenAt: Date
        /// The other members' display names (nil for entries saved before this was kept, or not known yet).
        var others: [String]?
    }

    private static let key = "ikut.pastTrips"
    private static let limit = 30

    static func all(defaults: UserDefaults = .standard) -> [Entry] {
        guard let data = defaults.data(forKey: key), let list = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return list
    }

    static func record(tripId: String, name: String, destination: String, endedAt: Date?, others: [String]? = nil, now: Date = Date(), defaults: UserDefaults = .standard) {
        var list = all(defaults: defaults)
        list = upsert(list, Entry(id: tripId, name: name, destination: destination, endedAt: endedAt, seenAt: now, others: others))
        if let data = try? JSONEncoder().encode(list) { defaults.set(data, forKey: key) }
    }

    /// Replaces or inserts at the front; an ended trip stays ended and known others are kept when the new record has none; keeps at most `limit`.
    static func upsert(_ list: [Entry], _ entry: Entry) -> [Entry] {
        var entry = entry
        if let old = list.first(where: { $0.id == entry.id }) {
            if entry.endedAt == nil { entry.endedAt = old.endedAt }
            if entry.others == nil { entry.others = old.others }
        }
        return Array(([entry] + list.filter { $0.id != entry.id }).prefix(limit))
    }

    /// The other members' names (everyone in `names` except `userId`), for `Entry.others`.
    static func others(from names: [String: String], excluding userId: String?) -> [String] {
        names.filter { $0.key != userId }.map(\.value).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// "With Ali", "With Ali and Sara", "With Ali and 2 others": the first name alphabetically (ignoring case);
    /// nil when nobody else is known.
    static func withPhrase(_ names: [String]?) -> String? {
        let sorted = (names ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        switch sorted.count {
        case 0: return nil
        case 1: return "With \(sorted[0])"
        case 2: return "With \(sorted[0]) and \(sorted[1])"
        default: return "With \(sorted[0]) and \(sorted.count - 1) others"
        }
    }
}
