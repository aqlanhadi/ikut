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
        // Capped at 55% of the screen (D116): 874 pt gives 480.7, a small phone's 667 gives 366.85.
        #expect(LobbySheet.compact(scaled: 5000) == 874 * SheetStops.midShare)
        #expect(abs(LobbySheet.compact(scaled: 470, screenHeight: 667) - 667 * SheetStops.midShare) < 1e-9)
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

    @MainActor @Test func theSheetStaysForNothingPushedOrPresented() {
        #expect(TripSheet(size: .lobby(tall: false)).presented)
    }

    @MainActor @Test(arguments: [TripSheetCover.changeDestination, .alwaysExplainer])
    func eachPushedOrPresentedThingCoversTheSheet(cover: TripSheetCover) {
        let sheet = TripSheet(size: .lobby(tall: false))
        sheet.cover([cover], among: TripSheetCover.trip)
        #expect(!sheet.presented)
    }

    /// D110: Leave, End and Rename present from inside the lobby's sheet, as in driving: the sheet never leaves for them.
    @MainActor @Test(arguments: [TripSheetCover.renaming, .confirmLeave, .confirmEnd, .confirmNewCode])
    func theLobbysOwnAsksKeepTheSheetUp(cover: TripSheetCover) {
        let sheet = TripSheet(size: .lobby(tall: false))
        sheet.cover([cover], among: TripSheetCover.trip)
        #expect(sheet.presented)
        // With a real cover alongside, it still steps aside.
        sheet.cover([cover, .alwaysExplainer], among: TripSheetCover.trip)
        #expect(!sheet.presented)
    }

    // MARK: The exit row (D110)

    @Test func leaveAsksThenWorksThenExitsOnce() {
        var exit = ExitFlow()
        #expect(exit.phase == .idle && !exit.busy)
        exit.ask(.leave)
        #expect(exit.asking == .leave && !exit.busy)
        exit.confirm(.leave)
        #expect(exit.working == .leave && exit.busy && exit.asking == nil)
        let first = exit.land()
        let second = exit.land()
        #expect(first && !second)
    }

    @Test func cancellingAnAskReturnsToIdle() {
        for kind in [ExitFlow.Kind.leave, .end, .newCode] {
            var exit = ExitFlow()
            exit.ask(kind)
            exit.cancel(kind)
            #expect(exit.phase == .idle && exit.asking == nil && !exit.busy)
        }
    }

    @Test func aFailedWriteReturnsTheRowToNormalWithTheError() {
        var exit = ExitFlow()
        exit.ask(.end)
        exit.confirm(.end)
        exit.fail("Can’t reach the server.")
        #expect(exit.phase == .idle && !exit.busy)
        #expect(exit.error == "Can’t reach the server.")
        // A later try starts clean, and a write that lands after a failure doesn't exit.
        let late = exit.land()
        #expect(!late)
        exit.confirm(.end)
        #expect(exit.error == nil && exit.working == .end)
    }

    @Test func cancellingTheAskOrConfirmingTwiceChangesNothingElse() {
        var exit = ExitFlow()
        exit.ask(.leave)
        exit.cancel(.leave)
        #expect(exit.phase == .idle)
        exit.confirm(.leave)
        // The dialog closing after its button was tapped cancels nothing; a second confirm doesn't switch kind.
        exit.cancel(.leave)
        exit.confirm(.end)
        #expect(exit.working == .leave)
    }

    /// D104: New code goes through the same row as Leave and End: asked, working, then the row returns (the trip's own
    /// listener shows the new code), and a failure returns it with the words. Nothing exits.
    @Test func newCodeAsksWorksAndLandsBackOnIdleWithoutExiting() {
        var exit = ExitFlow()
        exit.ask(.newCode)
        #expect(exit.asking == .newCode && !exit.busy)
        exit.confirm(.newCode)
        #expect(exit.working == .newCode && exit.progress == .newCode && exit.busy && !exit.canGoBack)
        let exits = exit.land()
        #expect(!exits && exit.phase == .idle && !exit.busy && exit.error == nil)
    }

    @Test func aFailedNewCodeReturnsTheRowWithTheError() {
        var exit = ExitFlow()
        exit.ask(.newCode)
        exit.confirm(.newCode)
        exit.fail("Can’t reach the server. Check your signal and try again.")
        #expect(exit.phase == .idle && exit.error != nil)
        exit.ask(.newCode)
        exit.cancel(.newCode)
        #expect(exit.phase == .idle)
        // The other rows rest while it works, and no second ask starts over it.
        exit.confirm(.newCode)
        exit.ask(.leave)
        #expect(exit.working == .newCode)
    }

    @MainActor @Test func theRunnerLandsANewCodeWithoutExitingAndFailsWithTheMessage() async {
        let runner = ExitRunner()
        var exits = 0
        #expect(await runner.run(.newCode, write: {}, exit: { exits += 1 }) == nil)
        #expect(exits == 0 && runner.flow.phase == .idle)
        struct Down: LocalizedError { var errorDescription: String? { "Can’t reach the server. Check your signal and try again." } }
        let problem = await runner.run(.newCode, write: { throw Down() }, exit: { exits += 1 })
        #expect(problem == "Can’t reach the server. Check your signal and try again." && exits == 0 && runner.flow.phase == .idle)
    }

    @Test func endingHoldsItsProgressUntilTheRecapTakesTheScreen() {
        var exit = ExitFlow()
        exit.confirm(.end)
        let exits = exit.land()
        #expect(!exits && exit.progress == .end && exit.busy)
    }

    @Test func backIsOffWhileAWriteIsOutOrLanded() {
        var exit = ExitFlow()
        #expect(exit.canGoBack)
        exit.ask(.leave)
        #expect(exit.canGoBack)
        exit.confirm(.leave)
        #expect(!exit.canGoBack)
        exit.fail("x")
        #expect(exit.canGoBack)
    }

    @MainActor @Test func aLandedLeaveExitsOnce() async {
        let runner = ExitRunner()
        var exits = 0
        let problem = await runner.run(.leave, write: {}, exit: { exits += 1 })
        #expect(problem == nil && exits == 1)
        // A second try after it landed writes nothing and exits nothing.
        var writes = 0
        await runner.run(.leave, write: { writes += 1 }, exit: { exits += 1 })
        #expect(writes == 0 && exits == 1)
    }

    @MainActor @Test func aFailedLeaveNeverExitsAndReturnsToIdle() async {
        struct Down: LocalizedError { var errorDescription: String? { "Can’t reach the server." } }
        let runner = ExitRunner()
        var exits = 0
        let problem = await runner.run(.leave, write: { throw Down() }, exit: { exits += 1 })
        #expect(problem == "Can’t reach the server." && exits == 0)
        #expect(runner.flow.phase == .idle && runner.flow.error == "Can’t reach the server.")
    }

    @MainActor @Test func aWriteLandingAfterTheScreenWentExitsNothing() async {
        let runner = ExitRunner()
        var exits = 0
        await runner.run(.leave, write: { runner.live = false }, exit: { exits += 1 })
        #expect(exits == 0)
    }

    @MainActor @Test func aPoppedLobbyTakesItsSheetWithIt() {
        let sheet = TripSheet(size: .lobby(tall: false))
        sheet.cover([.tripOffScreen], among: [.tripOffScreen])
        #expect(!sheet.presented)
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
        // The map's bottom padding (Home's short sheet) is not part of what the region is fitted into.
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

    @Test func theFirstFitFliesWhenTheMapHasACameraAndIsPlacedWhenItHasNone() {
        #expect(LobbyMapLogic.fitAnimates(fitted: false, mapHasCamera: true))
        #expect(!LobbyMapLogic.fitAnimates(fitted: false, mapHasCamera: false))
    }

    @Test func laterRefitsStillFly() {
        #expect(LobbyMapLogic.fitAnimates(fitted: true, mapHasCamera: true))
        #expect(LobbyMapLogic.fitAnimates(fitted: true, mapHasCamera: false))
    }

    @Test func askingForTheSameTargetTwiceIsANewRequest() {
        let first = LobbyMapCommand().asking(.stop("a"))
        #expect(first.asking(.stop("a")) != first)
    }
}
