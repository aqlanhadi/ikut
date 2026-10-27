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
        let stage = TripMapStage()
        #expect(stage.mode == .lobby)
        #expect(!stage.hasCamera)
        stage.camera = .region(MKCoordinateRegion(
            center: .init(latitude: 3.9, longitude: 101.3), span: .init(latitudeDelta: 1.5, longitudeDelta: 1)))
        #expect(stage.hasCamera)
        #expect(TripMapStage(mode: .driving).mode == .driving)
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
        let stage = TripMapStage(mode: .home)
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
}
