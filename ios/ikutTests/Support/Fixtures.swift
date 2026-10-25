import FirebaseAuth
import FirebaseCore
import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// Shared by every test file. Keep builders here when two files would otherwise copy them.

// MARK: - Clock

enum Fixtures {
    /// The instant the pure-logic tests treat as "now" (2027-01-15 08:00 UTC).
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// The locale and zone the time-of-day wording is tested in.
    static let gb = Locale(identifier: "en_GB")
    static let utc = TimeZone(identifier: "UTC")!

    static let kotaBharu = DestinationResult(
        name: "Kota Bharu", subtitle: "Kelantan", coordinate: .init(latitude: 6.1254, longitude: 102.2381))

    static let ipoh = DestinationResult(name: "Ipoh", subtitle: "", coordinate: .init(latitude: 4.6, longitude: 101.1))

    /// A two-point route; enough for anything that only needs a valid polyline.
    static let shortRoute = BuiltRoute(distance: 1_000, travelTime: 600, name: "E1", polyline: "_p~iF~ps|U")
    /// The same two points plus a third (a real, longer drive).
    static let longRoute = BuiltRoute(
        distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U_ulLnnqC")

    /// R&R Tapah, a fuel stop of 20 minutes 62 km along `longRoute`, as the emulator tests save it.
    static let tapah = PlannedStop.fixture("tapah")
}

// MARK: - Models

extension Trip {
    /// An active trip to Ipoh unless told otherwise; the id is "t".
    static func fixture(
        name: String = "Balik kampung", code: String = "K7M2QX", organizerId: String = "u", route: String = "",
        destination: Destination = Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 4.6, longitude: 101.1)),
        status: TripStatus = .active, startedAt: Date? = nil
    ) -> Trip {
        Trip(
            id: "t", name: name, code: code, organizerId: organizerId, route: route, destination: destination,
            status: status, startedAt: startedAt)
    }
}

extension Car {
    /// A car in the convoy named "Car <id>", not the lead, with no tracker, unless told otherwise.
    /// `number` defaults to the id read as a number (nil when it isn't one); pass `.some(nil)`, or any `Int?`
    /// variable, to say "no number".
    static func fixture(
        _ id: String, name: String? = nil, number: Int?? = nil, lead: Bool = false, state: CarState = .convoy,
        color: String = "#2563EB", tracker: String? = nil, route: String? = nil, mergeOffset: Double? = nil,
        pausedAt: Date? = nil
    ) -> Car {
        Car(
            id: id, name: name ?? "Car \(id)", color: color, trackerUserId: tracker, isLead: lead, route: route,
            mergeOffset: mergeOffset, state: state, number: number ?? Int(id), pausedAt: pausedAt)
    }
}

extension Position {
    /// A position at (0, 0) doing 25 m/s due east, reported a second before `Fixtures.t0`, unless told otherwise.
    static func fixture(
        location: GeoPoint = GeoPoint(latitude: 0, longitude: 0), speed: Double = 25, heading: Double = 90,
        routeOffset: Double = 0, convoyOffset: Double? = nil, battery: Double? = nil,
        updatedAt: Date? = Fixtures.t0.addingTimeInterval(-1)
    ) -> Position {
        Position(
            location: location, speed: speed, heading: heading, routeOffset: routeOffset, convoyOffset: convoyOffset,
            battery: battery, updatedAt: updatedAt)
    }
}

extension PlannedStop {
    /// R&R Tapah, a fuel stop of 20 minutes at 62 km, first in the list, unless told otherwise.
    static func fixture(
        _ id: String = "s1", name: String = "R&R Tapah", offset: Double = 62_000,
        coordinate: GeoPoint = GeoPoint(latitude: 4.2, longitude: 101.2), kind: PlannedStopKind = .fuel,
        minutes: Int? = 20, meetAt: Date? = nil, order: Int = 0, skipped: Bool? = nil, arrivedAt: Date? = nil,
        leftAt: Date? = nil, leftBy: String? = nil
    ) -> PlannedStop {
        var s = PlannedStop(
            id: nil, name: name, coordinate: coordinate, routeOffset: offset, kind: kind, minutes: minutes,
            meetAt: meetAt, order: order, skipped: skipped, arrivedAt: arrivedAt, leftAt: leftAt, leftBy: leftBy)
        // Set the id after init: passing a non-nil @DocumentID to the initializer logs a Firestore warning.
        s.id = id
        return s
    }
}

extension ConvoyModel {
    /// A model on `route`, in en_GB and UTC with the clock at `Fixtures.t0` unless told otherwise.
    @MainActor
    static func fixture(
        provider: any ETAProviding = StubETA(), route: RouteLine, locale: Locale = Fixtures.gb,
        timeZone: TimeZone = Fixtures.utc, clock: @escaping @MainActor () -> Date = { Fixtures.t0 },
        placeNamer: (@MainActor (CLLocationCoordinate2D) async -> String?)? = nil
    ) -> ConvoyModel {
        let m =
            placeNamer.map {
                ConvoyModel(provider: provider, locale: locale, timeZone: timeZone, clock: clock, placeNamer: $0)
            } ?? ConvoyModel(provider: provider, locale: locale, timeZone: timeZone, clock: clock)
        m.setMainRoute(route)
        return m
    }
}

// MARK: - Auth emulator

/// Deletes one user from the Auth emulator, as if the server had lost them (never touches anyone else).
func deleteUserFromAuthEmulator(_ uid: String) async throws {
    guard case .emulators(let host) = Backend.current else { return }
    let url = URL(string: "http://\(host):9099/identitytoolkit.googleapis.com/v1/projects/ikut-b1083/accounts:delete")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(["localId": uid])
    _ = try await URLSession.shared.data(for: request)
}

// MARK: - Waiting

/// Polls until `condition` holds or `timeout` passes (for work that runs on a task). It does not fail on
/// timeout: the `#expect` after it does, with the real values in the message.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
}

/// The first value from `stream` that satisfies `match`, or nil after `seconds` (for the emulator tests, which wait on
/// a real listener).
func firstValue<T: Sendable>(
    of stream: AsyncStream<T>, within seconds: Double = 10, where match: @escaping @Sendable (T) -> Bool = { _ in true }
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await value in stream where match(value) { return value }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// True when `stream` ends within `seconds` (a listener the rules refuse ends instead of waiting forever).
func finishes<T: Sendable>(_ stream: AsyncStream<T>, within seconds: Double = 15) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in stream {}
            return true
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

// MARK: - Decoding

/// Decodes `data` the way the app reads a Firestore document. `@DocumentID` can only be decoded with a document
/// reference, which needs a (never contacted) Firestore instance; `path` is that document.
func firestoreDecode<T: Decodable>(_ type: T.Type, from data: [String: Any], path: String = "trips/doc") throws -> T {
    if FirebaseApp.app() == nil {
        FirebaseApp.configure(options: FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1"))
    }
    let decoder = Firestore.Decoder()
    decoder.userInfo[CodingUserInfoKey(rawValue: "DocumentRefUserInfoKey")!] = Firestore.firestore().document(path)
    return try decoder.decode(type, from: data)
}

// MARK: - Emulator trips

extension Trait where Self == ConditionTrait {
    /// For suites that talk to the local Firebase emulators:
    /// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
    static var emulator: Self {
        .enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1")
    }
}

/// A trip made through the real `TripService.createTrip`, organised by a freshly signed-in guest.
struct EmulatorTrip {
    let tripId: String
    let carId: String
    let uid: String

    /// Signs in a new guest ("Aqlan" by default) and creates a trip they organise.
    static func make(
        name: String = "Trip", destination: DestinationResult = Fixtures.kotaBharu,
        route: BuiltRoute = Fixtures.shortRoute, organizer: String = "Aqlan",
        carName: String? = nil, carColor: String? = nil, stops: [PlannedStop] = []
    ) async throws -> EmulatorTrip {
        try await AuthModel().signInAsGuest(name: organizer)
        let uid = try #require(Auth.auth().currentUser?.uid)
        let ids = try await TripService.createTrip(
            name: name, destination: destination, route: route,
            organizer: TripOrganizer(id: uid, displayName: organizer), carName: carName, carColor: carColor)
        if !stops.isEmpty {
            let saved = BuiltRoute(distance: 205_000, travelTime: 9_600, name: "E1", polyline: route.polyline)
            try await TripService.saveStops(tripId: ids.tripId, plan: StopPlanSave(route: saved, stops: stops, removedIds: []))
        }
        return EmulatorTrip(tripId: ids.tripId, carId: ids.carId, uid: uid)
    }

    /// Signs out the current user, signs in a new guest and joins the trip with `code` in a new car. The guest is
    /// anonymous unless `viaAuthModel` (then `AuthModel.signInAsGuest`, as the app does).
    @discardableResult
    static func joinAsGuest(
        code: String, name: String, carName: String, color: String = TripService.palette[1], tracker: Bool,
        viaAuthModel: Bool = false
    ) async throws -> (uid: String, carId: String) {
        try Auth.auth().signOut()
        if viaAuthModel {
            try await AuthModel().signInAsGuest(name: name)
        } else {
            try await Auth.auth().signInAnonymously()
        }
        let uid = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: code, displayName: name, car: .new(name: carName, color: color), tracker: tracker)
        return (uid, joined.carId)
    }

    /// The trip's join code.
    func code() async throws -> String {
        try await Firestore.firestore().document(FirestorePaths.trip(tripId)).getDocument(as: Trip.self).code
    }
}
