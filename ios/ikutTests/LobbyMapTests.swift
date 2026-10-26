import CoreLocation
import SwiftUI
import Testing
@testable import ikut

struct LobbyMapTests {
    private func stop(_ id: String, _ kind: PlannedStopKind, _ lat: Double, _ lng: Double = 101.3) -> StopDraft {
        StopDraft(id: id, name: id.uppercased(), coordinate: .init(latitude: lat, longitude: lng), kind: kind)
    }
    private let route: [CLLocationCoordinate2D] = [
        .init(latitude: 3.14, longitude: 101.69), .init(latitude: 4.0, longitude: 101.3), .init(latitude: 4.6, longitude: 101.09)]
    private let ipoh = CLLocationCoordinate2D(latitude: 4.6, longitude: 101.09)

    // MARK: Sheet

    @Test func mediumIsTheCanvasHeightAndGrowsWithTextButIsCapped() {
        #expect(LobbySheet.compact(scaled: 470) == 470)
        #expect(LobbySheet.compact(scaled: 300) == 470)
        #expect(LobbySheet.compact(scaled: 5000) == 470 * 1.4)
    }

    @Test func twoDetentsMediumAndTall() {
        let detents = LobbySheet.detents(compact: 470)
        #expect(detents == [.height(470), .large])
        #expect(LobbySheet.detent(expanded: false, compact: 470) == .height(470))
        #expect(LobbySheet.detent(expanded: true, compact: 470) == .large)
        #expect(LobbySheet.isExpanded(.large))
        #expect(!LobbySheet.isExpanded(.height(470)))
    }

    @Test func legalKeepsClearOfTheMediumSheet() {
        #expect(LobbySheet.legalInset(compact: 470) == 470 + BottomSheet.detentExtra)
    }

    // MARK: Cover rule

    @Test func theSheetStaysForNothingPushedOrPresented() {
        #expect(!LobbySheet.isCovered(.init(), lobbyOnScreen: true))
    }

    @Test(arguments: [
        LobbySheet.Cover(tripMap: true), .init(changeDestination: true), .init(suggestStops: true),
        .init(renaming: true), .init(alwaysExplainer: true), .init(confirmLeave: true), .init(confirmEnd: true),
    ])
    func eachPushedOrPresentedThingCoversTheSheet(cover: LobbySheet.Cover) {
        #expect(LobbySheet.isCovered(cover, lobbyOnScreen: true))
    }

    @Test func aPoppedLobbyTakesItsSheetWithIt() {
        #expect(LobbySheet.isCovered(.init(), lobbyOnScreen: false))
    }

    // MARK: Pins

    @Test func stopsAreNumberedInListOrderAndTheMeetingPointIsItsOwnPin() {
        let stops = [stop("meet", .meet, 3.2), stop("a", .fuel, 3.5), stop("b", .food, 4.0)]
        let pins = LobbyMapLogic.pins(stops: stops, destinationName: "Ipoh", destination: ipoh, isOrganizer: true, ownJoin: nil)
        #expect(pins.map(\.kind) == [.meeting, .stop(number: 1), .stop(number: 2), .destination])
        #expect(pins.last?.name == "Ipoh")
    }

    @Test func theOrganiserHasNoJoinPin() {
        let pins = LobbyMapLogic.pins(stops: [], destinationName: "Ipoh", destination: ipoh, isOrganizer: true, ownJoin: route[1])
        #expect(pins.map(\.kind) == [.destination])
    }

    @Test func aParticipantSeesOnlyTheirOwnJoinPoint() {
        let pins = LobbyMapLogic.pins(stops: [stop("a", .fuel, 3.5)], destinationName: "Ipoh", destination: ipoh,
                                      isOrganizer: false, ownJoin: route[1])
        #expect(pins.filter { $0.kind == .join }.count == 1)
        #expect(pins.map(\.kind) == [.stop(number: 1), .destination, .join])
        #expect(LobbyMapLogic.pins(stops: [], destinationName: nil, destination: nil, isOrganizer: false, ownJoin: nil).isEmpty)
    }

    // MARK: Camera

    private func pins() -> [LobbyPin] {
        LobbyMapLogic.pins(stops: [stop("a", .fuel, 3.5, 101.5)], destinationName: "Ipoh", destination: ipoh,
                           isOrganizer: true, ownJoin: nil)
    }

    @Test func aTappedStopGetsACloseViewCentredOnIt() throws {
        let region = try #require(LobbyMapLogic.region(for: .stop("a"), route: route, pins: pins(), bottomObscured: 0, topObscured: 0))
        #expect(abs(region.center.latitude - 3.5) < 1e-9)
        #expect(abs(region.center.longitude - 101.5) < 1e-9)
        #expect(region.span.latitudeDelta == LobbyMapLogic.stopSpan)
    }

    @Test func aStopThatIsGoneHasNoTarget() {
        #expect(LobbyMapLogic.region(for: .stop("zzz"), route: route, pins: pins(), bottomObscured: 0, topObscured: 0) == nil)
    }

    @Test func theWholeTripFitsTheRouteAndPins() throws {
        let region = try #require(LobbyMapLogic.region(for: .wholeTrip, route: route, pins: pins(), bottomObscured: 0, topObscured: 0))
        for c in route + [ipoh] {
            #expect(abs(c.latitude - region.center.latitude) <= region.span.latitudeDelta / 2)
            #expect(abs(c.longitude - region.center.longitude) <= region.span.longitudeDelta / 2)
        }
        #expect(LobbyMapLogic.region(for: .wholeTrip, route: [], pins: [], bottomObscured: 0, topObscured: 0) == nil)
    }

    @Test func theSheetAndTheBarPushTheTripOutOfTheirWay() throws {
        let plain = try #require(LobbyMapLogic.region(for: .wholeTrip, route: route, pins: pins(), bottomObscured: 0, topObscured: 0))
        let clear = try #require(LobbyMapLogic.region(for: .wholeTrip, route: route, pins: pins(), bottomObscured: 0.1, topObscured: 0.2))
        #expect(clear.span.latitudeDelta > plain.span.latitudeDelta)
    }

    @Test func theTopFractionFollowsTheMeasuredBarAndFallsBackBeforeThat() {
        let band = LobbyMapLogic.buttonBand
        #expect(LobbyMapLogic.topFraction(mapHeight: 0, safeTop: 0)
            == Double(LobbyMapLogic.typicalBar + band + LobbyMapLogic.flagRoom) / 874)
        #expect(LobbyMapLogic.topFraction(mapHeight: 1000, safeTop: 62)
            == Double(62 + band + LobbyMapLogic.flagRoom) / 1000)
        // The map's bottom padding (the medium sheet) is not part of what the region is fitted into.
        #expect(LobbyMapLogic.topFraction(mapHeight: 874, safeTop: 62, bottomPadding: 500)
            == Double(62 + band + LobbyMapLogic.flagRoom) / 374)
    }

    @Test(arguments: [(CGFloat(62), CGFloat(874)), (50, 667), (68, 956)])
    func aDestinationAtTheNorthEdgeLandsBelowTheStatusBarAndTheMapButton(bar: CGFloat, height: CGFloat) throws {
        // The destination is the northernmost point, with the route running south from it.
        let north = [CLLocationCoordinate2D(latitude: 5.0, longitude: 101.0), .init(latitude: 3.0, longitude: 101.6)]
        let pins = LobbyMapLogic.pins(stops: [], destinationName: "North", destination: north[0], isOrganizer: true, ownJoin: nil)
        let top = LobbyMapLogic.topFraction(mapHeight: height, safeTop: bar)
        let region = try #require(LobbyMapLogic.region(for: .wholeTrip, route: north, pins: pins, bottomObscured: 0, topObscured: top))
        let fromTop = (region.center.latitude + region.span.latitudeDelta / 2 - 5.0) / region.span.latitudeDelta * height
        // The coordinate is below the status bar and the round button, with the flag's room above it.
        #expect(fromTop >= bar + LobbyMapLogic.buttonBand + LobbyMapLogic.flagRoom - 1)
    }

    @Test func aMovedCameraOrAStopViewIsNotRefitted() {
        #expect(LobbyMapLogic.shouldRefit(positionedByUser: false, onStop: false))
        #expect(!LobbyMapLogic.shouldRefit(positionedByUser: true, onStop: false))
        #expect(!LobbyMapLogic.shouldRefit(positionedByUser: false, onStop: true))
    }

    @Test func askingForTheSameTargetTwiceIsANewRequest() {
        let first = LobbyMapCommand().asking(.stop("a"))
        #expect(first.asking(.stop("a")) != first)
    }
}
