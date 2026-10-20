import FirebaseAuth
import FirebaseFirestore
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

    @Test func onTheRoadLine() {
        let utc = TimeZone(identifier: "UTC")!
        let at = Date(timeIntervalSince1970: 21 * 3600 + 35 * 60)
        let line = LobbyLogic.onTheRoadLine(startedAt: at, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(line?.hasPrefix("On the road since 9:35") == true)
        #expect(line?.hasSuffix("PM") == true)
        #expect(LobbyLogic.onTheRoadLine(startedAt: nil) == nil)
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

        let model = LobbyModel(tripId: ids.tripId)
        model.start()
        defer { model.stop() }

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
