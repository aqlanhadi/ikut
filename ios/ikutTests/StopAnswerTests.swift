import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("A car's skip answer")
struct StopAnswerTests {
    private func answer(_ carId: String, _ kind: StopAnswerKind = .skip) -> StopAnswer {
        StopAnswer(id: carId, answer: kind, userId: "u-\(carId)", at: nil)
    }

    private func stop(_ offset: Double = 62_000, skipped: Bool = false, kind: PlannedStopKind = .fuel) -> PlannedStop {
        PlannedStop.fixture(offset: offset, kind: kind, skipped: skipped ? true : nil)
    }

    @Test func theAnswerDecodesWithTheCarIdFromTheDocument() throws {
        let at = Fixtures.t0
        let decoded = try firestoreDecode(StopAnswer.self, from: ["answer": "skip", "userId": "u2", "at": Timestamp(date: at)],
            path: "trips/t/stops/s1/answers/carB")
        #expect(decoded.id == "carB")
        #expect(decoded.answer == .skip)
        #expect(decoded.userId == "u2")
        #expect(decoded.at == at)
    }

    @Test func exactly150MetersShortIsAlreadyThere() {
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_850, tripStarted: true, isJoining: false))
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_849.5, tripStarted: true, isJoining: false))
    }

    @Test func aMeetingPointIsDecidedByTheCarsStateAlone() {
        func meet(_ offset: Double) -> PlannedStop {
            PlannedStop.fixture(
                "m", name: "Petronas", offset: offset, coordinate: GeoPoint(latitude: 3.2, longitude: 101.6),
                kind: .meet, minutes: nil)
        }
        // A car with no way in of its own sits at offset about 0, the meeting point's own offset: joining still skips.
        #expect(SkipAnswers.canSkip(stop: meet(0), isLeadCar: false, carOffset: 0, tripStarted: true, isJoining: true))
        #expect(!SkipAnswers.canSkip(stop: meet(0), isLeadCar: false, carOffset: 0, tripStarted: true, isJoining: false))
        #expect(SkipAnswers.canSkip(stop: meet(5_000), isLeadCar: false, carOffset: nil, tripStarted: true, isJoining: true))
        #expect(!SkipAnswers.canSkip(stop: meet(5_000), isLeadCar: false, carOffset: 100, tripStarted: true, isJoining: false))
        // Once the meeting point was left there is nothing to meet at: no button, even for a joining car.
        var left = meet(0)
        left.leftAt = Date(timeIntervalSince1970: 1_000)
        left.leftBy = "u1"
        #expect(!SkipAnswers.canSkip(stop: left, isLeadCar: false, carOffset: nil, tripStarted: true, isJoining: true))
        // Any other stop goes by the offset, whatever the state.
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 100, tripStarted: true, isJoining: false))
    }

    @Test func skippingCarsAreNamedOneLineEachUpToTwo() {
        func car(_ id: String, _ name: String, _ n: Int) -> Car {
            Car.fixture(id, name: name, number: n)
        }
        let a = car("a", "Daniel’s Myvi", 2), b = car("b", "Wyna’s X70", 3), c = car("c", "Hafiz’s Axia", 4)
        #expect(SkipAnswers.lines(skippingCars: [], stopName: "R&R Tapah").isEmpty)
        #expect(SkipAnswers.lines(skippingCars: [a], stopName: "R&R Tapah") == ["Daniel’s car is skipping R&R Tapah"])
        #expect(SkipAnswers.lines(skippingCars: [b, a], stopName: "R&R Tapah")
            == ["Daniel’s car is skipping R&R Tapah", "Wyna’s car is skipping R&R Tapah"])
        #expect(SkipAnswers.lines(skippingCars: [a, b, c], stopName: "R&R Tapah") == ["3 cars are skipping R&R Tapah"])
        // No owner name: the car's own name. The viewer's own car: "You’re skipping".
        let myvi = car("d", "Myvi", 5)
        #expect(SkipAnswers.lines(skippingCars: [myvi], stopName: "R&R Tapah") == ["Myvi is skipping R&R Tapah"])
        #expect(SkipAnswers.lines(skippingCars: [a], stopName: "R&R Tapah", viewerCarId: "a") == ["You’re skipping R&R Tapah"])
        // At a meeting point.
        #expect(SkipAnswers.lines(skippingCars: [a], stopName: "Petronas", meeting: true) == ["Daniel will meet you along the way"])
        #expect(SkipAnswers.lines(skippingCars: [a, b, c], stopName: "Petronas", meeting: true) == ["3 cars will meet you along the way"])
    }

    @Test func theCarsSkippingAreTheOnesWhoAnswered() {
        #expect(SkipAnswers.skipping([]).isEmpty)
        #expect(SkipAnswers.skipping([answer("a"), answer("b")]) == ["a", "b"])
        // One document per car, so a second phone changes nothing.
        #expect(SkipAnswers.skipping([answer("a"), answer("a")]) == ["a"])
        #expect(SkipAnswers.isSkipping(carId: "a", in: [answer("a")]))
        #expect(!SkipAnswers.isSkipping(carId: "b", in: [answer("a")]))
    }

    @Test func carsThatAreGoneAreLeftOut() {
        #expect(SkipAnswers.skipping([answer("a"), answer("b")], among: ["b", "c"]) == ["b"])
        #expect(SkipAnswers.skipping([answer("a")], among: []).isEmpty)
    }

    @Test func aCarCanSkipBeforeItIsAtTheStop() {
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 30_000, tripStarted: true, isJoining: false))
        // Not merged onto the main route yet: nothing reached.
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: nil, tripStarted: true, isJoining: false))
        // Just outside the 150 m "here" radius.
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_849, tripStarted: true, isJoining: false))
    }

    @Test func aCarCannotSkipOnceAtOrPastTheStop() {
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_851, tripStarted: true, isJoining: false))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 62_000, tripStarted: true, isJoining: false))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 70_000, tripStarted: true, isJoining: false))
    }

    @Test func theLeadCarAFinishedTripStartOrASkippedStopGetNoSkip() {
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: true, carOffset: 1_000, tripStarted: true, isJoining: false))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 1_000, tripStarted: false, isJoining: false))
        #expect(!SkipAnswers.canSkip(stop: stop(skipped: true), isLeadCar: false, carOffset: 1_000, tripStarted: true, isJoining: false))
    }
}

/// Runs against the local emulators with this branch's rules (`tools/with-rules.mjs`). Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct StopAnswerEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    /// Before the organizer starts the trip nobody can answer, the joiner's own car included, and a joiner cannot start it.
    @Test func nobodyAnswersBeforeTheStart() async throws {
        let trip = try await EmulatorTrip.make(name: "Early", route: Fixtures.longRoute, stops: [Fixtures.tapah])
        let code = try await trip.code()
        let (joiner, joinedCar) = try await EmulatorTrip.joinAsGuest(
            code: code, name: "Wyna", carName: "Wyna's X70", tracker: true)
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joinedCar, userId: joiner)
        }
        // Only the organizer starts the trip: the joiner's Start is refused.
        await TripService.markStarted(tripId: trip.tripId)
        let doc = try await Firestore.firestore().document(FirestorePaths.trip(trip.tripId)).getDocument(as: Trip.self)
        #expect(doc.startedAt == nil)
    }

    /// A started trip with one stop; a second car joined. A car skips, undoes, skips again; the lead car, another
    /// car's answer and a skipped stop are refused.
    @Test func aCarSkipsAStopAndUndoesIt() async throws {
        let trip = try await EmulatorTrip.make(name: "Skips", route: Fixtures.longRoute, stops: [Fixtures.tapah])
        let code = try await trip.code()

        // Only the organizer starts the trip (rules), so start it before the joiner signs in.
        await TripService.markStarted(tripId: trip.tripId)
        let started = try await Firestore.firestore().document(FirestorePaths.trip(trip.tripId)).getDocument(as: Trip.self)
        #expect(started.startedAt != nil)

        let (joiner, joinedCar) = try await EmulatorTrip.joinAsGuest(
            code: code, name: "Wyna", carName: "Wyna's X70", tracker: true)
        let stream = StopAnswerService.listen(tripId: trip.tripId, stopId: "tapah")

        let sent = try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joinedCar, userId: joiner)
        #expect(sent)
        let said = try #require(await firstValue(of: stream, within: 15) { $0.count == 1 && $0[0].at != nil })
        #expect(SkipAnswers.skipping(said) == [joinedCar])
        #expect(said[0].userId == joiner)
        #expect(said[0].at != nil)
        // A second phone in the car says it again: still one answer.
        try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joinedCar, userId: joiner)

        // Nobody answers for another car.
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: trip.carId, userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: trip.carId)
        }

        let undone = try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: joinedCar)
        #expect(undone)
        let gone = try #require(await firstValue(of: stream, within: 15) { $0.isEmpty })
        #expect(SkipAnswers.skipping(gone).isEmpty)
        // Undo with nothing there is harmless; and the car can change its mind again.
        try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: joinedCar)
        try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joinedCar, userId: joiner)
    }

    private func tripWithStop(_ name: String) async throws -> EmulatorTrip {
        try await EmulatorTrip.make(name: name, route: Fixtures.longRoute, stops: [Fixtures.tapah])
    }

    /// The organizer's own (lead) car takes no skip answer, on a started trip.
    @Test func theLeadCarCannotSkipOnAStartedTrip() async throws {
        let trip = try await tripWithStop("Lead")
        await TripService.markStarted(tripId: trip.tripId)
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: trip.carId, userId: trip.uid)
        }
    }

    /// A listener the rules refuse (a non-member's) ends its stream instead of waiting forever.
    @Test func listenFinishesWhenTheRulesRefuseIt() async throws {
        let trip = try await tripWithStop("Listen")
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let stream = StopAnswerService.listen(tripId: trip.tripId, stopId: "tapah")
        #expect(await finishes(stream, within: 15))
    }
}
