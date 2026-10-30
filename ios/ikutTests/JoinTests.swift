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
        #expect(JoinService.message(code: .notFound, serverMessage: "").contains("No trip has that code"))
        #expect(JoinService.message(code: .resourceExhausted, serverMessage: "This trip is full (20 people).") == "This trip is full.")
        #expect(JoinService.message(code: .resourceExhausted, serverMessage: "This trip already has 10 cars.").contains("cars"))
        #expect(JoinService.message(code: .resourceExhausted, serverMessage: "Too many tries with that code. Wait 4 minutes and try again.")
            == "Too many tries. Wait a few minutes and try again.")
        #expect(JoinService.message(code: .invalidArgument, serverMessage: "That car is not part of this trip.").contains("no longer part"))
        #expect(JoinService.message(code: .invalidArgument, serverMessage: "x").contains("6 letters"))
        #expect(JoinService.message(code: .unavailable, serverMessage: "").contains("signal"))
        #expect(JoinService.message(code: .unauthenticated, serverMessage: "").contains("signed out"))
        #expect(JoinService.message(code: nil, serverMessage: "").contains("That didn’t go through"))
    }

    @Test func mapsFunctionsAndUrlErrors() {
        let notFound = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.notFound.rawValue)
        #expect(JoinService.map(notFound).message.contains("No trip has that code"))
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(JoinService.map(offline).message.contains("signal"))
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
        #expect(preview.stops.isEmpty)
        let result = try JoinService.parseJoinResult(["tripId": "t1", "carId": "c1", "trackerTaken": true])
        #expect(result == JoinResult(tripId: "t1", carId: "c1", trackerTaken: true))
    }
}

struct JoinStopsTests {
    private let base: [String: Any] = [
        "tripId": "t1", "name": "Raya", "destinationName": "Ipoh",
        "cars": [["id": "c1", "name": "Myvi", "color": "#2563EB", "hasTracker": true]],
    ]

    @Test func decodesStopsInOrder() throws {
        var data = base
        data["stops"] = [
            ["name": "R&R Tapah", "kind": "fuel", "minutes": 20],
            ["name": "Kuala Kangsar", "kind": "food"],
            ["name": "Odd", "kind": "teleport"],
        ] as [[String: Any]]
        let preview = try JoinService.parsePreview(data)
        #expect(preview.stops == [
            PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20),
            PreviewStop(name: "Kuala Kangsar", kind: .food),
        ])
    }

    @Test func decodesOrganiserRouteAndMeetingPoint() throws {
        var data = base
        data["organizerName"] = "Aqlan"
        data["route"] = "_p~iF~ps|U_ulLnnqC"
        data["stops"] = [
            ["name": "Petronas Jalan Duta", "kind": "meet", "coordinate": ["latitude": 3.17, "longitude": 101.68], "meetAt": 1_800_000_000_000],
            ["name": "R&R Tapah", "kind": "fuel", "minutes": 20, "coordinate": ["latitude": 4.2, "longitude": 101.2]],
            ["name": "Nowhere", "kind": "food", "coordinate": ["latitude": 999, "longitude": 0]],
        ] as [[String: Any]]
        let preview = try JoinService.parsePreview(data)
        #expect(preview.organizerName == "Aqlan")
        #expect(preview.route == "_p~iF~ps|U_ulLnnqC")
        let meet = try #require(preview.meetingPoint)
        #expect(meet.name == "Petronas Jalan Duta")
        #expect(meet.meetAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(meet.coordinate == PreviewCoordinate(latitude: 3.17, longitude: 101.68))
        #expect(preview.stops[1].coordinate?.longitude == 101.2 && preview.stops[1].meetAt == nil)
        #expect(preview.stops[2].coordinate == nil)
    }

    @Test func olderServerWithoutTheNewFieldsStillDecodes() throws {
        let preview = try JoinService.parsePreview(base)
        #expect(preview.organizerName == nil && preview.route == nil && preview.meetingPoint == nil)
        var blank = base
        blank["organizerName"] = "  "
        blank["route"] = ""
        let p = try JoinService.parsePreview(blank)
        #expect(p.organizerName == nil && p.route == nil)
    }

    @Test func previewWithoutStopsFieldStillDecodes() throws {
        #expect(try JoinService.parsePreview(base).stops.isEmpty)
        var empty = base
        empty["stops"] = [] as [[String: Any]]
        #expect(try JoinService.parsePreview(empty).stops.isEmpty)
    }

    @Test func ticketLineText() {
        #expect(PreviewStop(name: "R&R Tapah", kind: .fuel, minutes: 20).line == "R&R Tapah · fuel · 20 min")
        #expect(PreviewStop(name: "R&R Tapah", kind: .fuel).line == "R&R Tapah · fuel")
        #expect(PreviewStop(name: "A", kind: .food, minutes: 60).line == "A · food · 1 h")
        let words = PlannedStopKind.allCases.map { PreviewStop(name: "A", kind: $0).line }
        #expect(words == ["A · meeting point", "A · fuel", "A · food", "A · rest", "A · toilet", "A · sight"])
    }
}

@MainActor
struct JoinModelTests {
    private let trip = TripPreview(
        tripId: "t1", name: "Raya", destinationName: "Ipoh",
        cars: [PreviewCar(id: "c1", name: "Myvi", color: TripService.palette[0], hasTracker: true)])

    private func settle(_ model: JoinModel) async {
        await waitUntil(.milliseconds(500)) { model.preview != nil }
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

    @Test func prefilledCodeLoadsPreviewOnStart() async {
        let model = JoinModel(displayName: "Sam", initialCode: "y5r-efn", api: FakeJoinAPI(preview: trip))
        #expect(model.code == "Y5REFN")
        #expect(model.preview == nil && !model.isLoadingPreview)
        model.start()
        #expect(model.isLoadingPreview)
        await settle(model)
        #expect(model.preview == trip)
        model.start()
        #expect(model.preview == trip)
    }

    @Test func incompleteOrMissingPrefillDoesNotLoad() {
        let partial = JoinModel(displayName: "Sam", initialCode: "Y5R", api: FakeJoinAPI(preview: trip))
        partial.start()
        #expect(partial.code == "Y5R" && !partial.isLoadingPreview)
        let none = JoinModel(displayName: "Sam", api: FakeJoinAPI(preview: trip))
        none.start()
        #expect(none.code.isEmpty && !none.isLoadingPreview)
    }

    // MARK: Whether this phone tracks the car it joined (asks for Always before the lobby, #497)

    private let x70 = PreviewCar(id: "c2", name: "X70", color: TripService.palette[1], hasTracker: false)

    /// Joins as the sheet does: `sharing` is `JoinSteps.tracker` for what iOS said on the tap.
    private func joined(_ pick: (JoinModel) -> Void, authorization: LocationAccess.Status = .whenInUse,
                        trackerTaken: Bool = false) async -> JoinModel {
        let preview = TripPreview(tripId: "t1", name: "Raya", destinationName: "Ipoh", cars: trip.cars + [x70])
        let model = JoinModel(displayName: "Sam", api: FakeJoinAPI(
            preview: preview, joinResult: JoinResult(tripId: "t1", carId: "c9", trackerTaken: trackerTaken)))
        model.codeChanged("ABC234")
        await waitUntil(.milliseconds(500)) { model.preview != nil }
        pick(model)
        let wantsToShare = model.selection == .newCar || model.tracker
        let sharing = JoinSteps.tracker(wantsToShare: wantsToShare, authorization: authorization).tracker
        _ = await model.join(sharing: sharing)
        return model
    }

    @Test func aNewCarWhileSharingTracks() async {
        #expect(await joined { $0.selectNewCar() }.tracks)
    }

    @Test func anExistingCarWithNoTrackerTracks() async {
        #expect(await joined { $0.select(self.x70) }.tracks)
    }

    @Test func ridingInACarThatHasATrackerDoesNotTrack() async {
        #expect(await !joined { $0.select(self.trip.cars[0]) }.tracks)
    }

    @Test func aTrackerTakenJoinThenContinueDoesNotTrack() async {
        let model = await joined({ $0.select(self.x70) }, trackerTaken: true)
        #expect(model.trackerTakenResult != nil)
        #expect(!model.tracks)
    }

    @Test func locationRefusedOnTheTapJoinsAsCoPilotAndDoesNotTrack() async {
        #expect(await !joined({ $0.selectNewCar() }, authorization: .denied).tracks)
        #expect(!JoinSteps.tracks(asked: true, sharing: false, trackerTaken: false))
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
@Suite(.emulator, .serialized)
@MainActor
struct JoinEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func previewThenJoinWithNewCar() async throws {
        let ids = try await EmulatorTrip.make(name: "Join test", destination: Fixtures.ipoh, carName: "Aqlan's Myvi", carColor: TripService.palette[0])
        let code = try await ids.code()

        // A different user previews and joins.
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joinerUid = try #require(Auth.auth().currentUser?.uid)

        let api = LiveJoinAPI()
        let preview = try await api.preview(code: code.lowercased())
        #expect(preview.tripId == ids.tripId)
        #expect(preview.destinationName == "Ipoh")
        #expect(preview.cars == [
            PreviewCar(id: ids.carId, name: "Aqlan's Myvi", color: TripService.palette[0], hasTracker: true, number: 1)
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
            #expect(error.message.contains("No trip has that code"))
        }
    }
}
