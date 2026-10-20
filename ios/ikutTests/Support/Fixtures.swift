import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// Shared by every test file. Keep builders here when two files would otherwise copy them.

// MARK: - Clock

enum Fixtures {
    /// The instant the pure-logic tests treat as "now" (2027-01-15 08:00 UTC).
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let kotaBharu = DestinationResult(
        name: "Kota Bharu", subtitle: "Kelantan", coordinate: .init(latitude: 6.1254, longitude: 102.2381))

    static let ipoh = DestinationResult(name: "Ipoh", subtitle: "", coordinate: .init(latitude: 4.6, longitude: 101.1))

    /// A two-point route; enough for anything that only needs a valid polyline.
    static let shortRoute = BuiltRoute(distance: 1_000, travelTime: 600, name: "E1", polyline: "_p~iF~ps|U")
    /// The same two points plus a third (a real, longer drive).
    static let longRoute = BuiltRoute(
        distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U_ulLnnqC")
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

// MARK: - Waiting

/// Polls until `condition` holds or `timeout` passes (for work that runs on a task). It does not fail on
/// timeout: the `#expect` after it does, with the real values in the message.
@MainActor
func waitUntil(_ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
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
        carName: String? = nil, carColor: String? = nil
    ) async throws -> EmulatorTrip {
        try await AuthModel().signInAsGuest(name: organizer)
        let uid = try #require(Auth.auth().currentUser?.uid)
        let ids = try await TripService.createTrip(
            name: name, destination: destination, route: route,
            organizer: TripOrganizer(id: uid, displayName: organizer), carName: carName, carColor: carColor)
        return EmulatorTrip(tripId: ids.tripId, carId: ids.carId, uid: uid)
    }

    /// The trip's join code.
    func code() async throws -> String {
        try await Firestore.firestore().document(FirestorePaths.trip(tripId)).getDocument(as: Trip.self).code
    }
}
