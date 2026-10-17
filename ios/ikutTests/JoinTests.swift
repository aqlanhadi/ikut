import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing
@testable import ikut

struct JoinServiceTests {
    @Test func codeIsUppercasedAndStripped() {
        #expect(JoinService.normalizeCode("abc234") == "ABC234")
        #expect(JoinService.normalizeCode(" abc-234 ") == "ABC234")
        #expect(JoinService.normalizeCode("AB C2\n34") == "ABC234")
    }

    @Test func codeDropsCharactersOutsideAlphabetAndCaps() {
        #expect(JoinService.normalizeCode("O0I1L") == "")
        #expect(JoinService.normalizeCode("ABCDEFGHJK") == "ABCDEF")
        #expect(JoinService.isCompleteCode("ABCDEF"))
        #expect(!JoinService.isCompleteCode("ABCDE"))
    }

    private func car(_ id: String, _ color: String) -> PreviewCar {
        PreviewCar(id: id, name: id, color: color, hasTracker: false)
    }

    @Test func colorPrefersUnusedPaletteEntry() {
        #expect(JoinService.chooseColor(existing: []) == TripService.palette[0])
        let cars = [car("a", TripService.palette[0]), car("b", TripService.palette[2])]
        #expect(JoinService.chooseColor(existing: cars) == TripService.palette[1])
        #expect(JoinService.chooseColor(existing: [car("a", TripService.palette[0].lowercased())]) == TripService.palette[1])
    }

    @Test func colorCyclesWhenAllUsed() {
        let cars = TripService.palette.map { car($0, $0) } + [car("x", "#000000")]
        #expect(JoinService.chooseColor(existing: cars) == TripService.palette[1])
    }

    @Test func errorMessagesAreFriendly() {
        #expect(JoinService.message(code: .notFound, serverMessage: "").contains("No active trip"))
        #expect(JoinService.message(code: .resourceExhausted, serverMessage: "This trip is full (20 people).") == "This trip is full.")
        #expect(JoinService.message(code: .resourceExhausted, serverMessage: "This trip already has 10 cars.").contains("cars"))
        #expect(JoinService.message(code: .invalidArgument, serverMessage: "That car is not part of this trip.").contains("no longer part"))
        #expect(JoinService.message(code: .invalidArgument, serverMessage: "x").contains("6 letters"))
        #expect(JoinService.message(code: .unavailable, serverMessage: "").contains("connection"))
        #expect(JoinService.message(code: .unauthenticated, serverMessage: "").contains("signed out"))
        #expect(JoinService.message(code: nil, serverMessage: "").contains("Something went wrong"))
    }

    @Test func mapsFunctionsAndUrlErrors() {
        let notFound = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.notFound.rawValue)
        #expect(JoinService.map(notFound).message.contains("No active trip"))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(JoinService.map(offline).message.contains("connection"))
        #expect(JoinService.map(JoinError(message: "hi")).message == "hi")
    }

    @Test func payloadShapes() {
        let existing = JoinService.joinPayload(code: "ABC234", displayName: "Sam", car: .existing(id: "c1"), tracker: false)
        #expect((existing["car"] as? [String: String]) == ["existingCarId": "c1"])
        #expect(existing["tracker"] as? Bool == false)
        let new = JoinService.joinPayload(code: "ABC234", displayName: "Sam", car: .new(name: "Myvi", color: "#2563EB"), tracker: true)
        let newCar = (new["car"] as? [String: Any])?["newCar"] as? [String: String]
        #expect(newCar == ["name": "Myvi", "color": "#2563EB"])
        #expect(new["code"] as? String == "ABC234")
        #expect(new["displayName"] as? String == "Sam")
    }

    @Test func parsesResponses() throws {
        let preview = try JoinService.parsePreview([
            "tripId": "t1", "name": "Raya", "destinationName": "Ipoh",
            "cars": [["id": "c1", "name": "Myvi", "color": "#2563EB", "hasTracker": true]],
        ] as [String: Any])
        #expect(preview.cars == [PreviewCar(id: "c1", name: "Myvi", color: "#2563EB", hasTracker: true)])
        #expect(preview.destinationName == "Ipoh")
        #expect(throws: JoinError.self) { try JoinService.parsePreview(["tripId": "t1"]) }
        let result = try JoinService.parseJoinResult(["tripId": "t1", "carId": "c1", "trackerTaken": true])
        #expect(result == JoinResult(tripId: "t1", carId: "c1", trackerTaken: true))
    }
}

private struct FakeJoinAPI: JoinAPI {
    var preview: TripPreview
    var joinResult = JoinResult(tripId: "t1", carId: "c9", trackerTaken: false)
    func preview(code: String) async throws -> TripPreview { preview }
    func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
        joinResult
    }
}

@MainActor
struct JoinModelTests {
    private let trip = TripPreview(
        tripId: "t1", name: "Raya", destinationName: "Ipoh",
        cars: [PreviewCar(id: "c1", name: "Myvi", color: TripService.palette[0], hasTracker: true)])

    private func settle(_ model: JoinModel) async {
        for _ in 0..<50 where model.preview == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func previewLoadsOnlyWhenCodeIsComplete() async {
        let model = JoinModel(displayName: "Sam", api: FakeJoinAPI(preview: trip))
        model.codeChanged("abc")
        #expect(model.preview == nil && !model.isLoadingPreview)
        model.codeChanged("abc-234")
        #expect(model.code == "ABC234")
        await settle(model)
        #expect(model.preview == trip)
    }

    @Test func newCarDefaultsAndTrackerFollowsSelection() async {
        let model = JoinModel(displayName: "Sam", api: FakeJoinAPI(preview: trip))
        model.codeChanged("ABC234")
        await settle(model)
        #expect(!model.canJoin)
        model.select(trip.cars[0])
        #expect(model.canJoin && !model.tracker && model.selectedCarHasTracker)
        model.selectNewCar()
        #expect(model.tracker)
        #expect(model.newCarName == "Sam's car")
        #expect(model.newCarColor == TripService.palette[1])
    }

    @Test func trackerTakenHoldsBackNavigation() async {
        let api = FakeJoinAPI(
            preview: trip, joinResult: JoinResult(tripId: "t1", carId: "c1", trackerTaken: true))
        let model = JoinModel(displayName: "Sam", api: api)
        model.codeChanged("ABC234")
        await settle(model)
        model.select(trip.cars[0])
        model.tracker = true
        #expect(await model.join() == nil)
        #expect(model.trackerTakenResult?.carId == "c1")
    }

    @Test func successReturnsResult() async {
        let model = JoinModel(displayName: "Sam", api: FakeJoinAPI(preview: trip))
        model.codeChanged("ABC234")
        await settle(model)
        model.selectNewCar()
        #expect(await model.join() == JoinResult(tripId: "t1", carId: "c9", trackerTaken: false))
    }
}

/// Runs against the local emulators; see TripServiceEmulatorTests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct JoinEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func previewThenJoinWithNewCar() async throws {
        let organizer = AuthModel()
        try await organizer.signInAsGuest(name: "Aqlan")
        let orgUid = try #require(Auth.auth().currentUser?.uid)
        let ids = try await TripService.createTrip(
            name: "Join test \(UUID().uuidString.prefix(8))",
            destination: DestinationResult(name: "Ipoh", subtitle: "", coordinate: .init(latitude: 4.6, longitude: 101.1)),
            route: BuiltRoute(distance: 1000, travelTime: 60, name: "", polyline: "_p~iF~ps|U"),
            organizer: TripOrganizer(id: orgUid, displayName: "Aqlan"),
            carName: "Aqlan's Myvi", carColor: TripService.palette[0])
        let code = try await Firestore.firestore().document(FirestorePaths.trip(ids.tripId))
            .getDocument(as: Trip.self).code

        // A different user previews and joins.
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joinerUid = try #require(Auth.auth().currentUser?.uid)

        let api = LiveJoinAPI()
        let preview = try await api.preview(code: code.lowercased())
        #expect(preview.tripId == ids.tripId)
        #expect(preview.destinationName == "Ipoh")
        #expect(preview.cars == [
            PreviewCar(id: ids.carId, name: "Aqlan's Myvi", color: TripService.palette[0], hasTracker: true)
        ])

        let result = try await api.join(
            code: code, displayName: "Daniel",
            car: .new(name: "Daniel's City", color: JoinService.chooseColor(existing: preview.cars)),
            tracker: true)
        #expect(result.tripId == ids.tripId)
        #expect(!result.trackerTaken)
        #expect(result.carId != ids.carId)

        let second = try await api.join(
            code: code, displayName: "Daniel", car: .existing(id: ids.carId), tracker: true)
        #expect(second.carId == ids.carId)
        #expect(second.trackerTaken)
        _ = joinerUid
    }

    @Test func unknownCodeMapsToFriendlyError() async throws {
        try await Auth.auth().signInAnonymously()
        do {
            _ = try await LiveJoinAPI().preview(code: "ZZZZZZ")
            Issue.record("expected failure")
        } catch let error as JoinError {
            #expect(error.message.contains("No active trip"))
        }
    }
}
