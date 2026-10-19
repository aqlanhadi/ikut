import FirebaseAuth
import Foundation
import Testing
@testable import ikut

struct LobbyTests {
    private func car(_ id: String, _ name: String, lead: Bool = false, tracker: String? = nil) -> Car {
        Car(id: id, name: name, color: "#2563EB", trackerUserId: tracker, isLead: lead, state: .joining)
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

    @Test func catchUpLineNamesCarsWithoutATracker() {
        let tracked = LobbyCar(car: car("a", "Aqlan's Myvi", tracker: "u1"), members: [member("u1", "Aqlan", car: "a")])
        let daniel = LobbyCar(car: car("d", "Daniel's City"), members: [member("u4", "Daniel", car: "d")])
        let siti = LobbyCar(car: car("s", "Siti's Axia"), members: [member("u5", "Siti", car: "s")])
        let empty = LobbyCar(car: car("e", "Spare car"), members: [])

        #expect(LobbyLogic.catchUpLine([tracked]) == nil)
        #expect(LobbyLogic.catchUpLine([tracked, daniel]) == "Daniel can catch up on the road")
        #expect(LobbyLogic.catchUpLine([daniel, siti]) == "Daniel and Siti can catch up on the road")
        #expect(LobbyLogic.catchUpLine([empty]) == "Spare car can catch up on the road")
        #expect(LobbyLogic.catchUpLine([daniel, siti, empty]) == "3 cars can catch up on the road")
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct LobbyEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func modelReceivesCarAndMember() async throws {
        let auth = AuthModel()
        try await auth.signInAsGuest(name: "Aqlan")
        let uid = try #require(Auth.auth().currentUser?.uid)
        let ids = try await TripService.createTrip(
            name: "Lobby test",
            destination: DestinationResult(
                name: "Kota Bharu", subtitle: "Kelantan",
                coordinate: .init(latitude: 6.1254, longitude: 102.2381)),
            route: BuiltRoute(distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U"),
            organizer: TripOrganizer(id: uid, displayName: "Aqlan"),
            carName: "Aqlan's Myvi", carColor: TripService.palette[0])

        let model = LobbyModel(tripId: ids.tripId)
        model.start()
        defer { model.stop() }

        for _ in 0..<100 {
            if model.trip != nil, !model.cars.isEmpty, !model.members.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.trip?.name == "Lobby test")
        let grouped = model.groupedCars
        #expect(grouped.count == 1)
        #expect(grouped[0].id == ids.carId)
        #expect(grouped[0].car.name == "Aqlan's Myvi")
        #expect(grouped[0].members.map(\.displayName) == ["Aqlan"])
        #expect(grouped[0].hasTracker)
    }

}
