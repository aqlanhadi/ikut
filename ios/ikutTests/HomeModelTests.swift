import CoreLocation
import MapKit
import SwiftUI
import Testing

@testable import ikut

/// Home's flows as units (D63 B4): the picked trip and Back, Where to? and Close, Join and Close, a link mid-join, the
/// hand-off to the lobby, and the list when a trip ends. Each reads what the person would see: which sheet, and where
/// the camera goes back to.
@MainActor
struct HomeModelTests {
    private let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
    private let ipoh = DestinationResult(name: "Ipoh", subtitle: "City in Perak, Malaysia", coordinate: .init(latitude: 4.5975, longitude: 101.0901))
    private let route = BuiltRoute(distance: 205_400, travelTime: 9_600, name: "E1", polyline: "")

    /// A camera the person can tell apart from another, by how far out it is.
    private func camera(_ span: Double) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: kl, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }

    private func entry(_ id: String, ended: Bool = true, left: Bool = false) -> PastTrips.Entry {
        PastTrips.Entry(id: id, name: "Trip \(id)", destination: "Ipoh", endedAt: ended ? Date() : nil, seenAt: Date(),
                        others: nil, leftAt: left ? Date() : nil)
    }

    private func drawn(_ id: String) -> PastTripRoute {
        PastTripRoute(id: id, name: id, destinationName: "Ipoh", destinationLatitude: 4.6, destinationLongitude: 101.1,
                      points: [[3.1, 101.6], [4.6, 101.1]])
    }

    private func readyFlow() -> NewTripFlow {
        let flow = NewTripFlow(search: CreateTripModel(route: { _ in BuiltRoute(distance: 1, travelTime: 1, name: "", polyline: "") }))
        flow.showReadyForDemo(place: ipoh, route: route)
        return flow
    }

    private func preview() -> TripPreview {
        TripPreview(tripId: "t1", name: "Balik kampung raya", destinationName: "Ipoh", cars: [])
    }

    private func begin(_ model: HomeModel, code: String? = "K7M2QX", camera: MapCameraPosition, api: any JoinAPI) {
        model.beginJoin(JoinStart(code: code), camera: camera, displayName: "Sam", signedIn: true, location: .whenInUse, api: api)
    }

    // MARK: Picked trip

    @Test func pickingATripThenBackPutsTheCameraBackWhereItWas() {
        let list = entry("a")
        let model = HomeModel(past: [list], routes: [drawn("a")])
        model.expanded = true
        model.pick(list, camera: camera(3))
        #expect(model.picked?.entry.id == "a")
        #expect(!model.expanded, "a pick opens the short sheet")
        #expect(model.closePicked(camera: camera(0.5)) == .saved(camera(3)))
        #expect(model.picked == nil && !model.expanded)
        #expect(model.closePicked(camera: camera(3)) == nil, "Back with nothing picked does nothing")
    }

    @Test func backWithNoRoutesGoesToTheViewAroundYouWhileTheCameraShowedYou() {
        let model = HomeModel(past: [entry("a")])
        model.here = kl
        model.pick(entry("a"), camera: camera(3))
        #expect(model.closePicked(camera: camera(0.5)) == .here)
    }

    @Test func tappingARunningTripOpensItAndAnEndedOneIsPicked() {
        let model = HomeModel(past: [entry("now", ended: false), entry("old")])
        #expect(model.opening(entry("old")) == .pick(entry("old")))
        let running = entry("now", ended: false)
        #expect(model.opening(running) == .trip(running, started: false))
        model.nowStarted = ["now"]
        #expect(model.opening(running) == .trip(running, started: true))
    }

    // MARK: Where to? and New trip

    @Test func whereToThenCloseReturnsTheCameraAndNothingIsWritten() {
        let model = HomeModel(routes: [drawn("a")])
        model.creating = true
        model.expanded = true
        var moved: [HomeModel.CameraReturn] = []
        model.beginCreate(camera: camera(3), goBack: { moved.append($0) })
        #expect(model.mode == .whereTo && !model.expanded)
        #expect(moved.isEmpty)
        #expect(model.closeCreate(camera: camera(0.1)) == .saved(camera(3)))
        #expect(model.flow == nil && !model.creating && model.mode == .list)
    }

    @Test func whereToFromAPickedTripPutsThePickAwayFirstAndRemembersTheCameraBeforeWhereTo() {
        let model = HomeModel(past: [entry("a")], routes: [drawn("a")])
        model.pick(entry("a"), camera: camera(3))
        var moved: [HomeModel.CameraReturn] = []
        model.beginCreate(camera: camera(0.2), goBack: { moved.append($0) })
        #expect(model.picked == nil && model.flow != nil)
        #expect(moved == [.saved(camera(3))], "the picked trip's camera returns first")
        #expect(model.closeCreate(camera: camera(0.1)) == .saved(camera(0.2)))
    }

    @Test func aSecondWhereToWhileOneIsOpenChangesNothing() {
        let model = HomeModel(routes: [drawn("a")])
        model.beginCreate(camera: camera(3), goBack: { _ in })
        let first = model.flow
        model.beginCreate(camera: camera(0.1), goBack: { _ in })
        #expect(model.flow === first)
        #expect(model.closeCreate(camera: camera(1)) == .saved(camera(3)), "Close returns to before the first one")
    }

    // MARK: Join

    @Test func joinThenCloseReturnsTheCameraAndNothingIsWritten() {
        let model = HomeModel(routes: [drawn("a")])
        model.joining = JoinStart(code: nil)
        begin(model, code: nil, camera: camera(3), api: FakeJoinAPI(preview: preview()))
        #expect(model.joinFlow != nil && model.mode == .join)
        #expect(model.closeJoin(camera: camera(0.1)) == .saved(camera(3)))
        #expect(model.joinFlow == nil && model.joining == nil && model.mode == .list)
    }

    @Test func aLinkDuringWhereToLeavesItAndCloseGoesBackToBeforeWhereTo() {
        let model = HomeModel(routes: [drawn("a")])
        model.beginCreate(camera: camera(3), goBack: { _ in })
        model.creating = true
        begin(model, camera: camera(0.2), api: FakeJoinAPI(preview: preview()))
        #expect(model.flow == nil && !model.creating && model.joinFlow != nil)
        #expect(model.closeJoin(camera: camera(0.1)) == .saved(camera(3)))
    }

    @Test func aLinkMidJoinDoesNotSwapTheStepsButAnotherWhileBrowsingDoes() async {
        let model = HomeModel(routes: [drawn("a")])
        let api = FakeJoinAPI(preview: preview(), joinResult: JoinResult(tripId: "t1", carId: "c9", trackerTaken: true))
        begin(model, camera: camera(3), api: api)
        let first = model.joinFlow
        await waitUntil { first?.model.preview != nil }
        // Still browsing: a new link replaces the steps, and Close still returns to the camera before the first.
        begin(model, code: "ZZZ999", camera: camera(0.2), api: api)
        let second = model.joinFlow
        #expect(second !== first)
        await waitUntil { second?.model.preview != nil }
        // Joined: the steps stay, whatever arrives.
        second?.model.selectNewCar()
        await second?.model.join()
        #expect(second?.model.trackerTakenResult != nil)
        begin(model, code: "AAA111", camera: camera(0.1), api: api)
        #expect(model.joinFlow === second)
        #expect(model.closeJoin(camera: camera(0.05)) == .saved(camera(3)))
    }

    // MARK: Hand-off to the lobby

    @Test func makingATripKeepsWhereToUntilTheLobbyCoversTheSheet() async {
        let model = HomeModel()
        model.beginCreate(camera: camera(3), flow: readyFlow(), goBack: { _ in })
        model.creating = true
        let id = await model.createTrip(userID: "u1", displayName: "Sam", covered: false) { organizer, name, place, _ in
            #expect(organizer == TripOrganizer(id: "u1", displayName: "Sam"))
            #expect(name == "Trip to Ipoh" && place == self.ipoh)
            return "trip-1"
        }
        #expect(id == "trip-1")
        #expect(model.finishingCreate && !model.creating)
        #expect(model.flow != nil, "the list must not flash before the lobby arrives")
        model.coverSheet()
        #expect(model.flow == nil && !model.finishingCreate && model.cameraBeforeCreate == nil)
    }

    @Test func aTripThatCouldNotBeMadeKeepsNewTripForAnotherTry() async {
        let model = HomeModel()
        model.beginCreate(camera: camera(3), flow: readyFlow(), goBack: { _ in })
        struct Down: Error {}
        let id = await model.createTrip(userID: "u1", displayName: nil, covered: false) { _, _, _, _ in throw Down() }
        #expect(id == nil && !model.finishingCreate && model.flow?.createError != nil)
        let signedOut = await model.createTrip(userID: nil, displayName: nil, covered: false) { _, _, _, _ in "never" }
        #expect(signedOut == nil && model.flow?.createError == "Couldn’t sign you in. Check your signal and try again.")
    }

    @Test func aDemoWithNoParentLetsTheFlowGoAtOnce() async {
        let model = HomeModel()
        model.isDemo = true
        model.beginCreate(camera: camera(3), flow: readyFlow(), goBack: { _ in })
        _ = await model.createTrip(userID: "u1", displayName: "Sam", covered: false) { _, _, _, _ in "t" }
        #expect(model.flow == nil && !model.finishingCreate)
    }

    @Test func joiningKeepsTheStepsUntilTheLobbyCoversTheSheet() {
        let model = HomeModel()
        begin(model, camera: camera(3), api: FakeJoinAPI(preview: preview()))
        model.joining = JoinStart(code: "K7M2QX")
        model.joined(covered: false)
        #expect(model.finishingJoin && model.joining == nil)
        #expect(model.joinFlow != nil, "the list must not flash before the lobby arrives")
        model.coverSheet()
        #expect(model.joinFlow == nil && !model.finishingJoin && model.cameraBeforeJoin == nil)
    }

    // MARK: The list

    @Test func aTripThatEndedWhileAwayMovesToPastTripsAndIsPickedNotOpened() async throws {
        let suite = "HomeModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PastTrips.record(tripId: "ended", name: "Makan trip", destination: "Melaka", endedAt: nil, defaults: defaults)
        PastTrips.record(tripId: "running", name: "Balik kampung", destination: "Ipoh", endedAt: nil, defaults: defaults)
        PastTrips.record(tripId: "kicked", name: "Cameron", destination: "Tanah Rata", endedAt: nil, defaults: defaults)
        let model = HomeModel()
        model.reloadPast(defaults: defaults)
        #expect(HomeNow.split(model.past).now.count == 3)

        let endedAt = Date(timeIntervalSince1970: 1_800_000_000)
        await model.readNow(signedIn: true, load: { id in
            switch id {
            case "ended": HomeNow.Read(line: "Trip ended", endedAt: endedAt, name: "Makan trip!", destination: "Melaka")
            case "kicked": HomeNow.Read(line: HomeNow.fallbackStatus, gone: true)
            default: HomeNow.Read(line: "On the move · since 12:05", started: true)
            }
        }, defaults: defaults)

        let parts = HomeNow.split(model.past)
        #expect(parts.now.map(\.id) == ["running"])
        #expect(Set(parts.past.map(\.id)) == ["ended", "kicked"])
        let ended = try #require(model.past.first { $0.id == "ended" })
        #expect(ended.name == "Makan trip!" && ended.endedAt == endedAt && ended.leftAt == nil)
        #expect(model.past.first { $0.id == "kicked" }?.leftAt != nil, "a trip this phone was removed from is listed as left")
        #expect(model.nowStatus["running"] == "On the move · since 12:05" && model.nowStarted == ["running"])
        #expect(model.opening(ended) == .pick(ended))
    }

    @Test func signedOutReadsMoveNothing() async throws {
        let suite = "HomeModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        PastTrips.record(tripId: "t", name: "Trip", destination: "Ipoh", endedAt: nil, defaults: defaults)
        let model = HomeModel()
        model.reloadPast(defaults: defaults)
        await model.readNow(signedIn: false, load: { _ in HomeNow.Read(line: HomeNow.fallbackStatus, gone: true) }, defaults: defaults)
        #expect(HomeNow.split(model.past).now.map(\.id) == ["t"])
    }
}
