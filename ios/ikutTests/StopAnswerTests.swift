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
        PlannedStop(
            id: "s1", name: "R&R Tapah", coordinate: GeoPoint(latitude: 4.2, longitude: 101.2), routeOffset: offset,
            kind: kind, minutes: 20, order: 0, skipped: skipped ? true : nil)
    }

    private func firestoreDecode<T: Decodable>(_ type: T.Type, from data: [String: Any]) throws -> T {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure(options: FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1"))
        }
        let decoder = Firestore.Decoder()
        decoder.userInfo[CodingUserInfoKey(rawValue: "DocumentRefUserInfoKey")!] = Firestore.firestore()
            .document("trips/t/stops/s1/answers/carB")
        return try decoder.decode(type, from: data)
    }

    @Test func theAnswerDecodesWithTheCarIdFromTheDocument() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let decoded = try firestoreDecode(StopAnswer.self, from: ["answer": "skip", "userId": "u2", "at": Timestamp(date: at)])
        #expect(decoded.id == "carB")
        #expect(decoded.answer == .skip)
        #expect(decoded.userId == "u2")
        #expect(decoded.at == at)
    }

    @Test func pathsPutTheAnswerUnderTheStopByCarId() {
        #expect(FirestorePaths.answers(tripId: "t", stopId: "s1") == "trips/t/stops/s1/answers")
        #expect(FirestorePaths.answer(tripId: "t", stopId: "s1", carId: "carB") == "trips/t/stops/s1/answers/carB")
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
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 30_000, tripStarted: true))
        // Not merged onto the main route yet: nothing reached.
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: nil, tripStarted: true))
        // Just outside the 150 m "here" radius.
        #expect(SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_849, tripStarted: true))
    }

    @Test func aCarCannotSkipOnceAtOrPastTheStop() {
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 61_851, tripStarted: true))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 62_000, tripStarted: true))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 70_000, tripStarted: true))
    }

    @Test func theLeadCarAFinishedTripStartOrASkippedStopGetNoSkip() {
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: true, carOffset: 1_000, tripStarted: true))
        #expect(!SkipAnswers.canSkip(stop: stop(), isLeadCar: false, carOffset: 1_000, tripStarted: false))
        #expect(!SkipAnswers.canSkip(stop: stop(skipped: true), isLeadCar: false, carOffset: 1_000, tripStarted: true))
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

    private func firstValue(_ stream: AsyncStream<[StopAnswer]>, where match: @escaping @Sendable ([StopAnswer]) -> Bool) async throws -> [StopAnswer] {
        try await withThrowingTaskGroup(of: [StopAnswer]?.self) { group in
            group.addTask {
                for await value in stream where match(value) { return value }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return try #require(first)
        }
    }

    /// A started trip with one stop; a second car joined. A car skips, undoes, skips again; the lead car, another
    /// car's answer and a skipped stop are refused.
    @Test func aCarSkipsAStopAndUndoesIt() async throws {
        let trip = try await EmulatorTrip.make(name: "Skips", route: Fixtures.longRoute)
        let code = try await trip.code()
        let route = BuiltRoute(distance: 205_000, travelTime: 9_600, name: "E1", polyline: Fixtures.longRoute.polyline)
        let tapah = PlannedStop(
            id: "tapah", name: "R&R Tapah", coordinate: GeoPoint(latitude: 4.2, longitude: 101.2), routeOffset: 62_000,
            kind: .fuel, minutes: 20, order: 0)
        try await TripService.saveStops(tripId: trip.tripId, plan: StopPlanSave(route: route, stops: [tapah], removedIds: []))

        // Before the trip starts nobody can answer.
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: trip.carId, userId: trip.uid)
        }
        await TripService.markStarted(tripId: trip.tripId)
        // The lead car (the organizer's) cannot skip.
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: trip.carId, userId: trip.uid)
        }

        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joiner = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: code, displayName: "Wyna", car: .new(name: "Wyna's X70", color: TripService.palette[1]), tracker: true)
        let stream = StopAnswerService.listen(tripId: trip.tripId, stopId: "tapah")

        try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joined.carId, userId: joiner)
        let said = try await firstValue(stream) { $0.count == 1 && $0[0].at != nil }
        #expect(SkipAnswers.skipping(said) == [joined.carId])
        #expect(said[0].userId == joiner)
        #expect(said[0].at != nil)
        // A second phone in the car says it again: still one answer.
        try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joined.carId, userId: joiner)

        // Nobody answers for another car.
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: trip.carId, userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: trip.carId)
        }

        try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: joined.carId)
        let gone = try await firstValue(stream) { $0.isEmpty }
        #expect(SkipAnswers.skipping(gone).isEmpty)
        // Undo with nothing there is harmless; and the car can change its mind again.
        try await StopAnswerService.undo(tripId: trip.tripId, stopId: "tapah", carId: joined.carId)
        try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joined.carId, userId: joiner)
    }
}
