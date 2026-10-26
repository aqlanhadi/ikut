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

    @Test func backSwitchesDrivingToTheLobby() {
        #expect(TripScreenLogic.mode(after: .back, from: .driving) == .lobby)
    }

    @Test func aSwitchToTheModeAlreadyOnIsNoChange() {
        #expect(TripScreenLogic.mode(after: .showMap, from: .driving) == .driving)
        #expect(TripScreenLogic.mode(after: .back, from: .lobby) == .lobby)
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

    @Test func drivingsSheetIsTheConvoyPanelsShortAndTallTheMapTouchableThroughout() {
        let heights = PanelSheet.Heights(short: 282, tall: 520)
        let sheet = TripScreenLogic.Sheet.driving(heights)
        #expect(sheet.mode == .driving)
        #expect(sheet.detents == [.height(282), .height(520)])
        #expect(sheet.touchableUpThrough == .height(520))
    }

    @Test func drivingIsNotAPushSoItNoLongerCoversTheLobbysSheet() {
        // The cover rule has nothing for the map any more: the sheet stays up and changes its content.
        #expect(!LobbySheet.isCovered(.init(), lobbyOnScreen: true))
        #expect(!PanelSheet.isCovered(ended: false, leaving: false, explainerWants: false))
    }
}
