import FirebaseAuth
import Foundation
import Testing
@testable import ikut

/// Home's Now line read from the emulator: a member gets the real status, anyone else "In progress".
@Suite(.emulator, .serialized)
@MainActor
struct HomeNowEmulatorTests {
    @Test func aMemberGetsTheGatheringLine() async throws {
        let trip = try await EmulatorTrip.make(name: "Now")
        let read = await HomeNow.load(tripId: trip.tripId)
        #expect(read.line == "Gathering · 1 of 1 cars ready")
        #expect(read.endedAt == nil)
        #expect(!read.gone)
        #expect(!read.started)
    }

    @Test func someoneWhoIsNotAMemberAndAnUnknownTripGetInProgress() async throws {
        let trip = try await EmulatorTrip.make(name: "Now")
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let notMine = await HomeNow.load(tripId: trip.tripId)
        #expect(notMine.line == "In progress")
        // Refused: this phone is no longer in it (D54), so Home moves it to Past trips and the app won't open into it.
        #expect(notMine.gone)
        let unknown = await HomeNow.load(tripId: "no-such-trip")
        #expect(unknown.line == "In progress")
        #expect(unknown.gone)
    }
}
