import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

/// D63 C1: the session is the one reader of the trip. The lobby and the convoy read its cars and members (rule #396),
/// and one isStarted / isEnded / isOrganizer.
@MainActor
struct TripReadsTests {
    private let trip = Trip(
        id: "t1", name: "T", code: "ABC123", organizerId: "u1", route: Fixtures.longRoute.polyline,
        destination: Destination(name: "KB", coordinate: GeoPoint(latitude: 6.1, longitude: 102.2)), status: .active)
    private let cars = [
        Car.fixture("c1", name: "Myvi", number: 1, lead: true, tracker: "u1"),
        Car.fixture("c2", name: "X70", number: 2, tracker: "u2"),
    ]
    private let members = [
        Member(id: "u1", displayName: "Aqlan", carId: "c1", role: .organizer),
        Member(id: "u2", displayName: "Wyna", carId: "c2", role: .member),
    ]

    @Test func theLobbyReadsCarsAndMembersOnlyWhereRule396Says() {
        let both: Set<TripRead> = [.cars, .members]
        #expect(TripScreenLogic.lobbyReads(onScreen: true, mode: .home, pulledUp: false) == [])
        #expect(TripScreenLogic.lobbyReads(onScreen: true, mode: .lobby, pulledUp: false) == both)
        #expect(TripScreenLogic.lobbyReads(onScreen: true, mode: .driving, pulledUp: false) == [])
        #expect(TripScreenLogic.lobbyReads(onScreen: true, mode: .driving, pulledUp: true) == both)
        // Something pushed over the trip screen: nothing.
        #expect(TripScreenLogic.lobbyReads(onScreen: false, mode: .lobby, pulledUp: false) == [])
        #expect(TripScreenLogic.lobbyReads(onScreen: false, mode: .driving, pulledUp: true) == [])
    }

    @Test func twoReadersShareOneListener() {
        #expect(TripSessionLogic.reads([:]) == [])
        #expect(TripSessionLogic.reads([.map: [.cars]]) == [.cars])
        #expect(TripSessionLogic.reads([.lobby: [.cars, .members], .map: [.cars]]) == [.cars, .members])
        #expect(TripSessionLogic.reads([.lobby: [], .map: []]) == [])
    }

    @Test func startedMeansStartedAndNotEnded() {
        var t = trip
        #expect(!TripSessionLogic.isStarted(t))
        #expect(!TripSessionLogic.isStarted(nil))
        t.startedAt = Fixtures.t0
        #expect(TripSessionLogic.isStarted(t))
        t.status = .ended
        #expect(!TripSessionLogic.isStarted(t))
    }

    @Test func theSessionAnswersStartedEndedAndOrganizerOnce() {
        let session = TripSession(tripId: "t1", userId: "u1", tracker: FakeTrackingController())
        #expect(!session.isStarted && !session.isEnded && !session.isOrganizer)
        var t = trip
        session.applyForTesting(trip: t, member: members[0], car: nil)
        #expect(!session.isStarted && !session.isEnded && session.isOrganizer)
        t.startedAt = Fixtures.t0
        session.applyForTesting(trip: t, member: members[0], car: nil)
        #expect(session.isStarted && !session.isEnded)
        t.status = .ended
        session.applyForTesting(trip: t, member: members[0], car: nil)
        #expect(!session.isStarted && session.isEnded)

        let passenger = TripSession(tripId: "t1", userId: "u2", tracker: FakeTrackingController())
        passenger.applyForTesting(trip: trip, member: members[1], car: nil)
        #expect(!passenger.isOrganizer)
        // No signed-in user is never the organizer, even of a trip with no organizer id.
        let nobody = TripSession(tripId: "t1", userId: "", tracker: FakeTrackingController())
        var noOrganizer = trip
        noOrganizer.organizerId = ""
        nobody.applyForTesting(trip: noOrganizer, member: nil, car: nil)
        #expect(!nobody.isOrganizer)
    }

    @Test func theLobbyAndTheConvoyReadTheSameTripAndCars() {
        let session = TripSession(tripId: "t1", userId: "u1", tracker: FakeTrackingController())
        var t = trip
        t.startedAt = Fixtures.t0
        session.applyForTesting(trip: t, member: members[0], car: cars[0], cars: cars, members: members)
        let lobby = LobbyModel(session: session)
        let map = TripMapModel(session: session)
        map.sync()
        #expect(lobby.trip == session.trip)
        #expect(lobby.cars == session.cars)
        #expect(map.cars == session.cars)
        #expect(lobby.members == members)
        #expect(lobby.groupedCars.map(\.id) == ["c1", "c2"])
        #expect(map.tripStarted == session.isStarted)

        // One car leaves: both see it from the same update.
        session.applyForTesting(trip: t, member: members[0], car: cars[0], cars: [cars[0]], members: [members[0]])
        map.sync()
        #expect(lobby.cars.map(\.id) == ["c1"])
        #expect(map.cars.map(\.id) == ["c1"])

        // Ended: the map's started flag follows the session's.
        t.status = .ended
        session.applyForTesting(trip: t, member: members[0], car: cars[0], cars: [cars[0]], members: [members[0]])
        map.sync()
        #expect(!map.tripStarted && map.isEnded == session.isEnded)
    }
}

/// How many listeners each mode runs, against the local emulators (`TEST_RUNNER_IKUT_EMULATOR_TESTS=1`). Before D63 C1
/// the lobby and the map each had their own: Home 0, lobby 9 (session 5 + the lobby's trip, cars, stops, members),
/// driving 7 (session 5 + the map's cars + events), pulled up 11 (driving's 7 + the lobby's 4). Now the session holds
/// the one cars and members listener: Home 0, lobby 7, driving 7, pulled up 8. (No meeting point: no answer listener.)
@Suite(.emulator, .serialized)
@MainActor
struct TripListenerCountEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private let sessionOwn = ["trip", "member", "car", "positions", "stops"]

    /// The lobby's reads as `LobbyView.updateListening` sets them, then the session settles its listeners.
    private func lobby(_ session: TripSession, mode: TripScreenMode, pulledUp: Bool = false) {
        session.read(TripScreenLogic.lobbyReads(onScreen: true, mode: mode, pulledUp: pulledUp), by: .lobby)
        session.restUnread()
    }

    private func count(_ session: TripSession, _ map: TripMapModel) -> Int {
        session.runningListeners.count + (map.listensToEvents ? 1 : 0)
    }

    @Test func eachModeRunsTheSameOrFewerListeners() async throws {
        let s = try await EmulatorTrip.make(name: "Listeners", route: Fixtures.longRoute)
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: FakeTrackingController())
        let map = TripMapModel(session: session, eventSource: { _ in AsyncStream { _ in } })
        defer {
            map.stop()
            session.stop()
        }

        // Home: no trip open, nothing listens.
        #expect(count(session, map) == 0)

        // The lobby: the session's own five, and the cars and members the lobby reads.
        session.start()
        lobby(session, mode: .lobby)
        await waitUntil(.seconds(10)) { session.runningListeners.contains("car") && !session.cars.isEmpty && !session.members.isEmpty }
        #expect(session.runningListeners == sessionOwn + ["cars", "members"])
        #expect(count(session, map) == 7)

        // Start: driving, short or tall. The map reads the cars, the lobby rests; one cars listener throughout.
        map.start()
        lobby(session, mode: .driving)
        #expect(session.runningListeners == sessionOwn + ["cars"])
        #expect(count(session, map) == 7)
        map.sync()
        #expect(map.cars.map(\.id) == [s.carId])

        // Pulled up: the lobby reads the members again, and shares the map's cars listener.
        lobby(session, mode: .driving, pulledUp: true)
        #expect(session.runningListeners == sessionOwn + ["cars", "members"])
        #expect(count(session, map) == 8)

        // Folded again, then Back to trips: Home again, nothing listens.
        lobby(session, mode: .driving)
        #expect(count(session, map) == 7)
        map.stop()
        lobby(session, mode: .home)
        #expect(session.runningListeners == sessionOwn)
        session.stop()
        #expect(count(session, map) == 0)
    }
}
