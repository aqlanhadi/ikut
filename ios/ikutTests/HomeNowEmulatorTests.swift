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
    }

    @Test func someoneWhoIsNotAMemberAndAnUnknownTripGetInProgress() async throws {
        let trip = try await EmulatorTrip.make(name: "Now")
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        #expect(await HomeNow.load(tripId: trip.tripId).line == "In progress")
        #expect(await HomeNow.load(tripId: "no-such-trip").line == "In progress")
    }
}
