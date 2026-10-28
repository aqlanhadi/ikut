import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct LobbyTests {
    private func car(_ id: String, _ name: String, lead: Bool = false, tracker: String? = nil) -> Car {
        Car.fixture(id, name: name, number: .some(nil), lead: lead, state: .joining, tracker: tracker)
    }

    private func member(_ id: String, _ name: String, car: String) -> Member {
        Member(id: id, displayName: name, carId: car, role: .member)
    }

    @Test func leadFirstThenByName() {
        let sorted = LobbyLogic.sortedCars([
            car("c", "zed"), car("a", "Bravo"), car("l", "Zulu", lead: true), car("b", "alpha"),
        ])
        #expect(sorted.map(\.id) == ["l", "b", "a", "c"])
    }

    @Test func membersGroupedByCarAndSortedByName() {
        let grouped = LobbyLogic.group(
            cars: [car("c2", "Second"), car("c1", "First", lead: true, tracker: "u1")],
            members: [
                member("u3", "Siti", car: "c2"), member("u1", "Aqlan", car: "c1"),
                member("u2", "ali", car: "c1"), member("u4", "Ghost", car: "missing"),
            ])
        #expect(grouped.map(\.id) == ["c1", "c2"])
        #expect(grouped[0].members.map(\.displayName) == ["ali", "Aqlan"])
        #expect(grouped[1].members.map(\.displayName) == ["Siti"])
        #expect(grouped[0].hasTracker)
        #expect(!grouped[1].hasTracker)
    }

    @Test func emptyInputs() {
        #expect(LobbyLogic.group(cars: [], members: [member("u", "A", car: "c")]).isEmpty)
        #expect(LobbyLogic.group(cars: [car("c", "X")], members: [])[0].members.isEmpty)
    }

    @Test func shareTextAndPayload() {
        #expect(LobbyLogic.joinURL(code: "K5G4SV") == "ikut://join/K5G4SV")
        #expect(LobbyLogic.shareText(code: "K5G4SV") == "Join my convoy on ikut: code K5G4SV ikut://join/K5G4SV")
    }

    @Test func qrCodeGeneratesImage() throws {
        let image = try #require(QRCode.image(for: LobbyLogic.joinURL(code: "K5G4SV")))
        #expect(image.size.width > 0)
        #expect(image.size.width == image.size.height)
    }

    /// #189: the route is rebuilt from where the organizer is (D25 4d), so a started trip with stops offers it too.
    @Test func changeDestinationIsTheOrganizersUntilTheTripEnds() {
        #expect(LobbyLogic.canChangeDestination(canEdit: true))
        #expect(!LobbyLogic.canChangeDestination(canEdit: false))
    }

    private func trip(status: TripStatus = .active, startedAt: Date? = nil) -> Trip {
        .fixture(name: "Trip", code: "ABC123", organizerId: "u1", status: status, startedAt: startedAt)
    }

    @Test func notStartedBeforeStartTrip() {
        #expect(!LobbyLogic.isStarted(trip: trip()))
        #expect(!LobbyLogic.isStarted(trip: nil))
    }

    @Test func startedWhenStartedAtIsSet() {
        #expect(LobbyLogic.isStarted(trip: trip(startedAt: Date())))
    }

    @Test func endedTripIsNeverStarted() {
        #expect(!LobbyLogic.isStarted(trip: trip(status: .ended, startedAt: Date())))
    }

    @Test func bottomBarByRoleAndState() {
        typealias Bar = LobbyLogic.BottomBar
        // Before the start only the organizer has a button, and it starts the trip.
        #expect(LobbyLogic.bottomBar(isOrganizer: true, started: false, organizerName: "Aqlan") == Bar.startTrip)
        #expect(LobbyLogic.bottomBar(isOrganizer: false, started: false, organizerName: "Aqlan") == Bar.waiting(organizerName: "Aqlan"))
        // Once started, everyone gets Show map.
        #expect(LobbyLogic.bottomBar(isOrganizer: true, started: true, organizerName: "Aqlan") == Bar.showMap)
        #expect(LobbyLogic.bottomBar(isOrganizer: false, started: true, organizerName: "Aqlan") == Bar.showMap)
        // An ended trip has nobody to wait for.
        #expect(LobbyLogic.bottomBar(isOrganizer: false, started: false, ended: true, organizerName: nil) == Bar.showMap)
        #expect(LobbyLogic.bottomBar(isOrganizer: true, started: false, ended: true, organizerName: nil) == Bar.showMap)
    }

    @Test func noBarWhileLoadingOrAfterBeingRemoved() {
        typealias Bar = LobbyLogic.BottomBar
        // Loading: we can't tell the organizer from a participant yet.
        #expect(LobbyLogic.bottomBar(isOrganizer: false, tripLoaded: false, started: false, organizerName: nil) == Bar.none)
        #expect(LobbyLogic.bottomBar(isOrganizer: false, tripLoaded: false, started: true, organizerName: nil) == Bar.none)
        // Removed from the trip: no waiting line, no map.
        #expect(LobbyLogic.bottomBar(isOrganizer: false, isMember: false, started: false, organizerName: "Aqlan") == Bar.none)
        #expect(LobbyLogic.bottomBar(isOrganizer: false, isMember: false, started: true, organizerName: "Aqlan") == Bar.none)
    }

    @Test func theOrganizerCanOnlyEndBeforeTheStart() {
        #expect(!LobbyLogic.canLeaveTrip(isOrganizer: true, started: false, isLiveMember: true))
        #expect(LobbyLogic.canLeaveTrip(isOrganizer: true, started: true, isLiveMember: true))
        #expect(LobbyLogic.canLeaveTrip(isOrganizer: false, started: false, isLiveMember: true))
        #expect(LobbyLogic.canLeaveTrip(isOrganizer: false, started: true, isLiveMember: true))
        #expect(!LobbyLogic.canLeaveTrip(isOrganizer: false, started: true, isLiveMember: false))
    }

    @Test func bottomBarWords() {
        #expect(LobbyLogic.BottomBar.startTrip.label == "Start trip")
        #expect(LobbyLogic.BottomBar.showMap.label == "Show map")
        #expect(LobbyLogic.BottomBar.waiting(organizerName: "Aqlan").label == "Waiting for Aqlan to start the trip")
        #expect(LobbyLogic.BottomBar.waiting(organizerName: nil).label == "Waiting for the organiser to start the trip")
    }

    @Test func organizerNameComesFromTheLoadedMembers() {
        let t = trip()
        func member(_ id: String, _ name: String) -> Member {
            Member(id: id, displayName: name, carId: "c1", role: .member)
        }
        #expect(LobbyLogic.organizerName(trip: t, members: [member("u2", "Wyna"), member("u1", "Aqlan")]) == "Aqlan")
        #expect(LobbyLogic.organizerName(trip: t, members: [member("u2", "Wyna")]) == nil)
        #expect(LobbyLogic.organizerName(trip: t, members: [member("u1", "  ")]) == nil)
        #expect(LobbyLogic.organizerName(trip: nil, members: [member("u1", "Aqlan")]) == nil)
    }

    @Test func sinceLine() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 21 * 3600 + 35 * 60)
        let line = LobbyLogic.sinceLine(startedAt: at, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(line?.hasPrefix("Since 9:35") == true)
        #expect(line?.hasSuffix("PM") == true)
        #expect(LobbyLogic.sinceLine(startedAt: nil) == nil)
    }

    @Test func title() {
        #expect(LobbyLogic.title(started: false, ended: false) == "Gathering")
        #expect(LobbyLogic.title(started: true, ended: false) == "Trip in progress")
        #expect(LobbyLogic.title(started: false, ended: true) == "Trip ended")
    }
}

@Suite(.emulator, .serialized)
@MainActor
struct LobbyEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func modelReceivesCarAndMember() async throws {
        let ids = try await EmulatorTrip.make(
            name: "Lobby test", carName: "Aqlan's Myvi", carColor: TripService.palette[0])

        let session = TripSession(tripId: ids.tripId, userId: ids.uid, tracker: FakeTrackingController())
        session.start()
        session.read(TripScreenLogic.lobbyReads(onScreen: true, mode: .lobby, pulledUp: false), by: .lobby)
        let model = LobbyModel(session: session)
        defer { session.stop() }

        await waitUntil(.seconds(10)) { model.trip != nil && !model.cars.isEmpty && !model.members.isEmpty }
        #expect(model.trip?.name == "Lobby test")
        let grouped = model.groupedCars
        #expect(grouped.count == 1)
        #expect(grouped[0].id == ids.carId)
        #expect(grouped[0].car.name == "Aqlan's Myvi")
        #expect(grouped[0].members.map(\.displayName) == ["Aqlan"])
        #expect(grouped[0].hasTracker)
    }

}
