import FirebaseFirestore
import MapKit
import SwiftUI
import Testing
@testable import ikut

/// The trip screen's modes over its one map (D53): what switches them, which layer draws, where the camera goes and
/// the one sheet's sizes.
struct TripScreenTests {
    // MARK: Mode

    @Test func startAndShowMapSwitchTheLobbyToDriving() {
        #expect(TripScreenLogic.mode(after: .start, from: .lobby) == .driving)
        #expect(TripScreenLogic.mode(after: .showMap, from: .lobby) == .driving)
    }

    @Test func aSwitchToTheModeAlreadyOnIsNoChange() {
        #expect(TripScreenLogic.mode(after: .showMap, from: .driving) == .driving)
        #expect(TripScreenLogic.mode(after: .start, from: .driving) == .driving)
    }

    // MARK: Who draws

    @Test func oneLayerDrawsTheMapAndFillsTheSheetInEachMode() {
        #expect(TripScreenLogic.layer(in: .lobby) == .lobby)
        #expect(TripScreenLogic.layer(in: .driving) == .driving)
    }

    @Test func theLastLayerToPublishWinsSoOnlyTheOneOnScreenIsDrawn() {
        var value: TripMapSpec? = TripMapSpec(bottomPadding: 1)
        TripMapSpecKey.reduce(value: &value) { TripMapSpec(bottomPadding: 2) }
        #expect(value?.bottomPadding == 2)
        // A sibling that publishes nothing leaves the one that did.
        TripMapSpecKey.reduce(value: &value) { nil }
        #expect(value?.bottomPadding == 2)
    }

    @Test func eachLayerAsksForItsOwnMapLayers() {
        let route = [CLLocationCoordinate2D(latitude: 3.1, longitude: 101.6), .init(latitude: 4.6, longitude: 101.1)]
        let lobby = TripMapInput.lobby(route: route, pins: [], ownRoute: [], ownColorHex: "#000000")
        let driving = TripMapInput.driving(route: route, overlays: [], hazards: [], cars: [])
        #expect(lobby.layers == [.user, .route])
        #expect(driving.layers == [.route])
    }

    // MARK: Camera

    @Test func theLobbyFitsTheWholeTripAndDrivingFollowsYourCar() {
        #expect(TripScreenLogic.entryCamera(.lobby) == .wholeTrip)
        #expect(TripScreenLogic.entryCamera(.driving) == .follow)
        #expect(TripScreenLogic.drivingEntryMode == .follow)
    }

    @Test func aSwitchFliesTheCameraButTheFirstFrameJustPlacesIt() {
        #expect(TripScreenLogic.animatesEntry(mapHasCamera: true))
        #expect(!TripScreenLogic.animatesEntry(mapHasCamera: false))
    }

    @MainActor @Test func theStageHasACameraOnceALayerPlacedOne() {
        let stage = TripScreenModel()
        #expect(stage.mode == .lobby)
        #expect(!stage.hasCamera)
        stage.camera = .region(MKCoordinateRegion(
            center: .init(latitude: 3.9, longitude: 101.3), span: .init(latitudeDelta: 1.5, longitudeDelta: 1)))
        #expect(stage.hasCamera)
        #expect(TripScreenModel(mode: .driving).mode == .driving)
    }

    // MARK: The one sheet

    @Test func theLobbysSheetIsMediumAndTallTheMapTouchableUpToMedium() {
        let sheet = TripScreenLogic.Sheet.lobby(compact: 470)
        #expect(sheet.mode == .lobby)
        #expect(sheet.detents == [.height(470), .large])
        #expect(sheet.touchableUpThrough == .height(470))
    }

    @Test func drivingsSheetIsTheConvoyPanelsThreeHeightsTheMapTouchableThroughout() {
        let heights = PanelSheet.Heights(short: 282, tall: 520, full: 760)
        let sheet = TripScreenLogic.Sheet.driving(heights)
        #expect(sheet.mode == .driving)
        #expect(sheet.detents == [.height(282), .height(520), .height(760)])
        // #402: the map, pill, banners and round buttons answer (undimmed) at every height, pulled up included.
        #expect(sheet.touchableUpThrough == .height(760))
    }

    // MARK: Home on the same map (D54)

    @Test func openingATripFromHomeIsTheLobbyOrDrivingWhenItHasStarted() {
        #expect(TripScreenLogic.mode(after: .open(started: false), from: .home) == .lobby)
        #expect(TripScreenLogic.mode(after: .open(started: true), from: .home) == .driving)
    }

    @Test func leaveEndAndBackReturnToHomesList() {
        #expect(TripScreenLogic.mode(after: .exit, from: .lobby) == .home)
        #expect(TripScreenLogic.mode(after: .exit, from: .driving) == .home)
        #expect(TripScreenLogic.mode(after: .exit, from: .home) == .home)
    }

    @Test func startAndShowMapDoNothingOnHome() {
        // No trip is open on Home: nothing to drive.
        #expect(TripScreenLogic.mode(after: .start, from: .home) == .home)
        #expect(TripScreenLogic.mode(after: .showMap, from: .home) == .home)
    }

    @Test func homeIsItsOwnLayerAndTheLobbyRestsThere() {
        #expect(TripScreenLogic.layer(in: .home) == .home)
        #expect(!TripScreenLogic.lobbyListens(onScreen: true, mode: .home, pulledUp: true))
    }

    @Test func homesCameraIsItsOwnListFit() {
        #expect(TripScreenLogic.entryCamera(.home) == .homeList)
    }

    @MainActor @Test func theStageOpensATripAndExitsToHomeKeepingTheOneCamera() {
        let stage = TripScreenModel(mode: .home)
        #expect(stage.mode == .home)
        #expect(stage.tripId == nil)
        stage.camera = .region(MKCoordinateRegion(
            center: .init(latitude: 3.1, longitude: 101.7), span: .init(latitudeDelta: 1, longitudeDelta: 1)))

        stage.open(tripId: "t1", started: false)
        #expect(stage.mode == .lobby)
        #expect(stage.tripId == "t1")
        // The camera is the same one: the lobby flies from where Home left it.
        #expect(stage.hasCamera)
        #expect(TripScreenLogic.animatesEntry(mapHasCamera: stage.hasCamera))

        stage.exit()
        #expect(stage.mode == .home)
        #expect(stage.tripId == nil)
        #expect(stage.hasCamera)

        stage.open(tripId: "t2", started: true)
        #expect(stage.mode == .driving)
        #expect(stage.tripId == "t2")
    }

    @Test func homesSheetHasTheListsOrTheCreateStepsHeights() {
        let list = TripScreenLogic.Sheet.home(.list, compact: 300)
        #expect(list.mode == .home)
        #expect(list.detents == [.height(300), .large])
        #expect(list.touchableUpThrough == .height(300))
        let newTrip = TripScreenLogic.Sheet.home(.newTrip, compact: 300)
        #expect(newTrip.detents == [.height(HomeSheet.newTripHeight), .large])
        #expect(newTrip.touchableUpThrough == .height(HomeSheet.newTripHeight))
    }

    @Test func homeAsksForPastRoutesAPickedTripOrTheNewTripsPins() {
        let line = [[3.1, 101.6], [4.6, 101.1]]
        let route = PastTripRoute(id: "p1", name: "Raya", destinationName: "Ipoh", destinationLatitude: 4.6,
                                  destinationLongitude: 101.1, points: line)
        #expect(TripMapInput.home(routes: [route], names: [:]).layers == [.user, .pastRoutes])
        #expect(TripMapInput.home(routes: [], names: [:]).layers == [.user])

        let dot = RecapTimelineItem(id: "s1", kind: .stop, time: Date(), title: "Tapah", detail: "", symbol: "fuelpump",
                                    latitude: 4.2, longitude: 101.2)
        let picked = TripMapInput.picked(route: route, dots: [dot], selectedId: nil)
        #expect(picked.layers == [.pickedRoute, .recapDots])
        // Past routes are not drawn under a picked trip.
        #expect(!picked.layers.contains(.pastRoutes))

        let place = DestinationResult(name: "Ipoh", subtitle: "Perak", coordinate: .init(latitude: 4.6, longitude: 101.1))
        let searching = TripMapInput.newTrip(places: [place], focusedId: place.id, route: [])
        #expect(searching.layers == [.user, .places])
        let ready = TripMapInput.newTrip(places: [place], focusedId: nil, route: route.coordinates)
        #expect(ready.layers == [.user, .places, .newTripRoute])
        // Home never asks for a trip's cars, hazards or stop pins.
        for input in [TripMapInput.home(routes: [route], names: [:]), picked, ready] {
            #expect(input.layers.isDisjoint(with: [.route, .cars, .hazards, .pins, .overlays, .ownRoute]))
        }
    }

    @Test func drivingIsNotAPushSoItNoLongerCoversTheLobbysSheet() {
        // The cover rule has nothing for the map any more: the sheet stays up and changes its content.
        #expect(!LobbySheet.isCovered(.init(), lobbyOnScreen: true))
        #expect(!PanelSheet.isCovered(ended: false, explainerWants: false, lobbyWants: false))
    }

    // MARK: Camera reading (D57)

    /// A move that ends where it began writes nothing, so nothing that reads the heading or the scale redraws.
    @MainActor @Test func theMapsReadingIsWrittenOnlyWhenItChanges() {
        let stage = TripScreenModel(mode: .home)
        let reading = TripCameraReading(distance: 2_500, pitch: 0, latitudeDelta: 0.02)
        stage.read(heading: 10, reading: reading)
        final class Flag: @unchecked Sendable { var on = false }
        let changed = Flag()
        withObservationTracking { _ = stage.heading; _ = stage.reading } onChange: { changed.on = true }
        stage.read(heading: 10, reading: reading)
        #expect(!changed.on)
        stage.read(heading: 12, reading: reading)
        #expect(changed.on)
        #expect(stage.heading == 12)
        let again = Flag()
        withObservationTracking { _ = stage.reading } onChange: { again.on = true }
        stage.read(heading: 12, reading: TripCameraReading(distance: 3_000, pitch: 0, latitudeDelta: 0.025))
        #expect(again.on)
        #expect(stage.reading?.distance == 3_000)
    }
}

/// The trip screen's one model owns the open trip's objects (D63 C2): made once in `open`, dropped in `exit`, and the
/// session (with the tracker) stopped there, so nothing keeps tracking after Back to trips, Leave or End.
@MainActor
struct TripScreenModelTests {
    /// A model whose trips use a fake tracker and car-route service, and save nothing.
    @MainActor private final class Rig {
        let tracker = FakeTrackingController()
        let carRoute = FakeCarRoute()
        private(set) var made: [String] = []
        let defaults = UserDefaults(suiteName: "TripScreenModelTests.\(UUID().uuidString)")!

        func model(mode: TripScreenMode = .home) -> TripScreenModel {
            TripScreenModel(mode: mode, defaults: defaults) { [self] tripId in
                made.append(tripId)
                let carRoute = carRoute
                let session = TripSession(tripId: tripId, userId: "u1", tracker: tracker,
                                          carRouteFactory: { _, _, _, _, _ in carRoute })
                return OpenTrip(id: tripId, session: session,
                                planner: StopPlanner(router: StraightRoads(), delay: .zero, origin: { nil }, save: { _ in }))
            }
        }
    }

    private static let trip = Trip(
        id: "t1", name: "T", code: "ABC123", organizerId: "u1", route: Fixtures.longRoute.polyline,
        destination: Destination(name: "KB", coordinate: GeoPoint(latitude: 6.1, longitude: 102.2)), status: .active)
    private static let member = Member(id: "u1", displayName: "A", carId: "c1", role: .organizer)
    private static let car = Car.fixture("c1", name: "Car", number: 1, lead: true, state: .joining, color: "#000000",
                                         tracker: "u1")

    @Test func openMakesTheTripsObjectsOnceAndOpeningItAgainKeepsThem() throws {
        let rig = Rig()
        let screen = rig.model()
        #expect(screen.trip == nil)

        screen.open(tripId: "t1", started: false)
        let first = try #require(screen.trip)
        #expect(first.id == "t1")
        #expect(first.lobby.tripId == "t1")
        #expect(first.map.mode == TripScreenLogic.drivingEntryMode)

        // The app opening into the trip it already has (a relaunch route, a Now row): the same objects.
        screen.open(tripId: "t1", started: true)
        let again = try #require(screen.trip)
        #expect(again.session === first.session)
        #expect(again.lobby === first.lobby)
        #expect(again.planner === first.planner)
        #expect(again.map === first.map)
        #expect(rig.made == ["t1"])
        #expect(screen.mode == .driving)
    }

    @Test func exitDropsEveryObjectSoNoSessionIsLeft() {
        let rig = Rig()
        let screen = rig.model()
        weak var session: TripSession?
        weak var lobby: LobbyModel?
        weak var planner: StopPlanner?
        weak var map: TripMapModel?
        screen.open(tripId: "t1", started: false)
        session = screen.trip?.session
        lobby = screen.trip?.lobby
        planner = screen.trip?.planner
        map = screen.trip?.map
        #expect(session != nil && lobby != nil && planner != nil && map != nil)

        screen.exit()
        #expect(screen.trip == nil)
        #expect(screen.tripId == nil)
        #expect(screen.mode == .home)
        #expect(session == nil)
        #expect(lobby == nil)
        #expect(planner == nil)
        #expect(map == nil)
    }

    @Test func backToTripsStopsTrackingThatWasRunning() async {
        let rig = Rig()
        let screen = rig.model()
        screen.open(tripId: "t1", started: true)
        screen.trip?.session.applyForTesting(trip: Self.trip, member: Self.member, car: Self.car)
        await waitUntil(.seconds(2)) { rig.tracker.isTracking }
        #expect(rig.tracker.isTracking)

        screen.exit()
        #expect(!rig.tracker.isTracking)
        #expect(rig.tracker.stopCount >= 1)
        // A fix after the exit reaches nobody: the session is gone.
        #expect(rig.tracker.onFix == nil)
    }

    @Test func reopeningAnotherTripGivesFreshObjects() throws {
        let rig = Rig()
        let screen = rig.model()
        screen.open(tripId: "t1", started: false)
        weak let oldSession = screen.trip?.session
        let oldPlanner = try #require(screen.trip?.planner)
        screen.exit()

        screen.open(tripId: "t2", started: false)
        let next = try #require(screen.trip)
        #expect(next.id == "t2")
        #expect(next.planner !== oldPlanner)
        #expect(oldSession == nil)
        #expect(rig.made == ["t1", "t2"])

        // And the same trip again after an exit: fresh too (its old objects went with the exit).
        screen.exit()
        screen.open(tripId: "t2", started: false)
        #expect(screen.trip?.session !== next.session)
        #expect(rig.made == ["t1", "t2", "t2"])
    }

    @Test func aRelaunchOpensDrivingForAStartedTripAndTheLobbyOtherwise() {
        let entry = PastTrips.Entry(id: "a", name: "Trip a", destination: "Ipoh", endedAt: nil,
                                    seenAt: Date(timeIntervalSince1970: 0))
        for (read, mode) in [(HomeNow.Read(line: "On the move", started: true), TripScreenMode.driving),
                             (HomeNow.Read(line: "Gathering"), .lobby)] {
            let rig = Rig()
            let screen = rig.model()
            let route = LaunchRoute.decide(signedIn: true, entries: [entry], read: ["a": read], pendingJoin: nil)
            guard case .trip(let id, let started) = route else { Issue.record("expected a trip, got \(route)"); continue }
            screen.open(tripId: id, started: started)
            #expect(screen.mode == mode)
            #expect(screen.trip?.id == "a")
        }
    }

    @Test func keepScreenOnIsOnUntilChosenAndRemembersTheChoice() {
        let rig = Rig()
        #expect(rig.model().keepScreenOn)
        let screen = rig.model()
        screen.keepScreenOn = false
        #expect(rig.defaults.bool(forKey: TripScreenModel.keepAwakeAnsweredKey))
        #expect(!rig.model().keepScreenOn)
        screen.keepScreenOn = true
        #expect(rig.model().keepScreenOn)
    }
}
