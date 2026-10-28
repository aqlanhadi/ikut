import SwiftUI
import Testing
@testable import ikut

/// The convoy sheet's motion and card hand-over (`ConvoySheetState`), run without a view.
struct ConvoySheetStateTests {
    private let room: CGFloat? = 700

    private func measured() -> ConvoySheetState {
        var s = ConvoySheetState()
        s.foldedContent = 200
        s.unfoldedContent = 400
        s.barContent = 60
        s.panelUp = true
        return s
    }

    /// Takes the heights the way `TripMapView.resettle` does.
    private func settle(_ s: inout ConvoySheetState, room: CGFloat? = 700) {
        if let next = s.heightsToTake(room: room, hasTopBanner: false) { s.take(next) }
    }

    // MARK: Fold, unfold, pull up

    @Test func startsFoldedWithNoCard() {
        let s = ConvoySheetState()
        #expect(s.shown == .folded)
        #expect(!s.listUnfolded)
        #expect(s.presentedCard == nil)
        #expect(!s.cardDismissing)
    }

    @Test func foldAndUnfoldFollowTheHeader() {
        var s = ConvoySheetState()
        #expect(s.shown(expanding: false) == nil)
        #expect(s.shown(expanding: true) == .unfolded)
        s.shown = .unfolded
        #expect(s.listUnfolded)
        #expect(s.shown(expanding: true) == nil)
        #expect(s.shown(expanding: false) == .folded)
    }

    @Test func unfoldingAPulledUpSheetLeavesItPulledUp() {
        var s = ConvoySheetState()
        s.shown = .pulledUp
        #expect(s.listUnfolded)
        #expect(s.shown(expanding: true) == nil)
        // Folding it from there goes all the way down.
        #expect(s.shown(expanding: false) == .folded)
    }

    @Test func pullUpAndBackAreOnlyAMotionWhenTheSizeChanges() {
        var s = ConvoySheetState()
        s.shown = .unfolded
        #expect(s.needsMotion(to: .pulledUp))
        s.shown = .pulledUp
        #expect(!s.needsMotion(to: .pulledUp))
        #expect(s.needsMotion(to: .unfolded))
    }

    @Test func theHazardApproachFoldsAndPassingLeavesTheSizeAlone() {
        var s = ConvoySheetState()
        s.shown = .pulledUp
        #expect(s.shown(after: .approaching) == .folded)
        #expect(s.shown(after: .passed) == .pulledUp)
        s.shown = .unfolded
        #expect(s.shown(after: .gaveUp) == .unfolded)
    }

    @Test func aStopAskingBringsAPulledUpSheetBackToTall() {
        var s = ConvoySheetState()
        s.shown = .pulledUp
        #expect(s.shown(after: .stopAsks) == .unfolded)
        s.shown = .folded
        #expect(s.shown(after: .stopAsks) == .folded)
    }

    // MARK: Held heights

    @Test func theFirstMeasuredHeightsAreTakenWithoutAMotion() {
        var s = measured()
        let first = s.heightsToTake(room: room, hasTopBanner: false)
        #expect(first != nil)
        let r1 = s.take(first!)
        #expect(r1)
        #expect(s.appliedHeights == first)
        // Taken: nothing more to take until a layout changes.
        #expect(s.heightsToTake(room: room, hasTopBanner: false) == nil)
    }

    @Test func aHeightChangeAtRestIsTakenWithAMotion() {
        var s = measured()
        settle(&s)
        s.unfoldedContent = 500
        let next = s.heightsToTake(room: room, hasTopBanner: false)
        #expect(next?.tall == 560)
        let r2 = s.take(next!)
        #expect(r2 == false)
    }

    @Test func theHeightsAreHeldWhileTheSheetMoves() {
        var s = measured()
        settle(&s)
        let held = s.appliedHeights
        _ = s.beginMotion()
        #expect(s.moving)
        s.foldedContent = 260
        s.unfoldedContent = 520
        #expect(s.heightsToTake(room: room, hasTopBanner: false) == nil)
        #expect(s.heights(room: room, hasTopBanner: false) == held)
    }

    @Test func theHeightsAreLetGoWhenTheMotionEnds() {
        var s = measured()
        settle(&s)
        let number = s.beginMotion()
        s.unfoldedContent = 520
        let r3 = s.endMotion(number)
        #expect(r3)
        #expect(!s.moving)
        #expect(s.heightsToTake(room: room, hasTopBanner: false)?.tall == 580)
    }

    @Test func anOlderMotionsEndDoesNotReleaseANewerOne() {
        var s = measured()
        let first = s.beginMotion()
        let second = s.beginMotion()
        #expect(first != second)
        let r4 = s.endMotion(first)
        #expect(!r4)
        #expect(s.moving)
        let r5 = s.endMotion(second)
        #expect(r5)
        // Its fallback arriving after the completion has nothing left to do.
        let r6 = s.endMotion(second)
        #expect(!r6)
    }

    @Test func theTopBannerAddsToEveryHeightOnlyWhileItIsThere() {
        var s = measured()
        s.topContent = 50
        let with = s.measuredHeights(room: room, hasTopBanner: true)
        let without = s.measuredHeights(room: room, hasTopBanner: false)
        #expect(with.short == without.short + 50)
        #expect(with.tall == without.tall + 50)
    }

    @Test func aNewTextSizeMeasuresEveryLayoutAgain() {
        var s = measured()
        s.cardContent = 300
        s.forgetMeasuredHeights()
        #expect(s.foldedContent == nil && s.unfoldedContent == nil && s.cardContent == nil)
        // The bar's own height and the banner's stay.
        #expect(s.barContent == 60)
    }

    // MARK: What the sheets cover

    @Test func coversNothingWhileTheSheetIsNotUp() {
        var s = measured()
        settle(&s)
        s.panelUp = false
        #expect(s.covered(room: room, hasTopBanner: false) == 0)
    }

    @Test func coversTheSheetsHeightAndPulledUpCountsAsTall() {
        var s = measured()
        settle(&s)
        let h = s.appliedHeights!
        #expect(s.covered(room: room, hasTopBanner: false) == h.short)
        s.shown = .unfolded
        #expect(s.covered(room: room, hasTopBanner: false) == h.tall)
        s.shown = .pulledUp
        #expect(s.covered(room: room, hasTopBanner: false) == h.tall)
    }

    // MARK: A card opening and closing

    @Test(arguments: [PanelSheet.Shown.folded, .unfolded, .pulledUp])
    func aCardOpensOverEachSizeAndTheSizeIsTheSameWhenItCloses(size: PanelSheet.Shown) {
        var s = measured()
        s.shown = size
        s.stopCardOpen = true
        let want = s.wantedCard(reportReady: false, stopReady: true, arrivalLive: false)
        #expect(want == .stopRequest)
        let r7 = s.syncCard(wanted: want)
        #expect(!r7)
        #expect(s.presentedCard == .stopRequest)
        #expect(s.shown == size)
        s.stopCardOpen = false
        // Wanting none starts its dismissal, and the sheet reports it gone.
        let r8 = s.syncCard(wanted: nil)
        #expect(r8)
        #expect(s.presentedCard == nil)
        #expect(s.cardDismissing)
        let r9 = s.cardDismissed(wanted: nil)
        #expect(!r9)
        #expect(!s.cardDismissing)
        #expect(s.shown == size)
    }

    @Test func theCardKeepsShowingWhatItLastShowedWhileItSlidesDown() {
        var s = measured()
        s.reportOpen = true
        s.syncCard(wanted: .report)
        s.reportOpen = false
        s.syncCard(wanted: nil)
        #expect(s.lastCard == .report)
        #expect(s.presentedCard == nil)
    }

    @Test func oneCardIsAskedForAtATimeInThisOrder() {
        var s = ConvoySheetState()
        s.reportOpen = true
        s.stopCardOpen = true
        s.arrivalStopId = "stop1"
        #expect(s.wantedCard(reportReady: true, stopReady: true, arrivalLive: true) == .report)
        // Report has no context yet: the stop card is next.
        #expect(s.wantedCard(reportReady: false, stopReady: true, arrivalLive: true) == .stopRequest)
        #expect(s.wantedCard(reportReady: false, stopReady: false, arrivalLive: true) == .arrival("stop1"))
        // The arrival card's stop is gone.
        #expect(s.wantedCard(reportReady: false, stopReady: false, arrivalLive: false) == nil)
    }

    @Test func aCardChangingIntoAnotherSwapsInTheSheetThatIsUp() {
        var s = ConvoySheetState()
        s.syncCard(wanted: .stopRequest)
        #expect(s.presentedCard == .stopRequest)
        // The stop closes and its arrival card follows: nothing dismisses.
        let r10 = s.syncCard(wanted: .arrival("s"))
        #expect(!r10)
        #expect(s.presentedCard == .stopRequest)
        #expect(!s.cardDismissing)
    }

    @Test func aCardAskedForWhileAnotherSlidesDownWaitsForItsDismissal() {
        var s = ConvoySheetState()
        s.syncCard(wanted: .report)
        s.syncCard(wanted: nil)
        #expect(s.cardDismissing)
        let r11 = s.syncCard(wanted: .stopRequest)
        #expect(!r11)
        #expect(s.presentedCard == nil)
        // The dismissal (or its fallback) arrives: the waiting card opens.
        let r12 = s.cardDismissed(wanted: .stopRequest)
        #expect(!r12)
        #expect(s.presentedCard == .stopRequest)
        #expect(!s.cardDismissing)
    }

    @Test func aDismissalNeverReportedIsEndedByTheFallbackAndOnlyOnce() {
        var s = ConvoySheetState()
        s.syncCard(wanted: .stopRequest)
        s.syncCard(wanted: nil)
        #expect(s.cardDismissing)
        // The fallback's own call: no longer dismissing, and nothing opens when nothing is wanted.
        s.cardDismissed(wanted: nil)
        #expect(!s.cardDismissing)
        #expect(s.presentedCard == nil)
    }

    @Test func theCardGoesWithTheConvoySheetAndComesBackWithIt() {
        var s = measured()
        s.stopCardOpen = true
        s.syncCard(wanted: .stopRequest)
        s.convoySheetWent()
        #expect(!s.panelUp)
        #expect(s.presentedCard == nil)
        #expect(!s.cardDismissing)
        // Still wanted when the sheet is back up: it opens again.
        s.panelUp = true
        let r13 = s.syncCard(wanted: s.wantedCard(reportReady: false, stopReady: true, arrivalLive: false))
        #expect(!r13)
        #expect(s.presentedCard == .stopRequest)
    }

    @Test func aSwipeDownOnTheCardClearsEverythingItShowedAndWaitsForTheDismissal() {
        var s = ConvoySheetState()
        s.reportOpen = true
        s.stopCardOpen = true
        s.arrivalStopId = "s"
        s.syncCard(wanted: .report)
        let r14 = s.cardClosedBySystem()
        #expect(r14)
        #expect(s.presentedCard == nil)
        #expect(s.cardDismissing)
        #expect(!s.reportOpen && !s.stopCardOpen && s.arrivalStopId == nil)
        // The sheet going away by our own doing has nothing to clear.
        let r15 = s.cardClosedBySystem()
        #expect(!r15)
    }

    @Test func theStopCardClosesByItselfWhenItsStopCloses() {
        var s = ConvoySheetState()
        s.stopCardOpen = true
        // Requests still there, or none before: stays.
        let r16 = s.stopRequestsChanged(hadRequests: true, hasRequests: true)
        #expect(!r16)
        let r17 = s.stopRequestsChanged(hadRequests: false, hasRequests: false)
        #expect(!r17)
        #expect(s.stopCardOpen)
        let r18 = s.stopRequestsChanged(hadRequests: true, hasRequests: false)
        #expect(r18)
        #expect(!s.stopCardOpen)
    }

    @Test func aClosingStopLeavesTheReportAndArrivalCardsAlone() {
        var s = ConvoySheetState()
        s.reportOpen = true
        s.arrivalStopId = "s"
        let r19 = s.stopRequestsChanged(hadRequests: true, hasRequests: false)
        #expect(!r19)
        #expect(s.reportOpen)
        #expect(s.arrivalStopId == "s")
    }

    // MARK: The keyboard (Q16)

    @Test func theCardSheetGrowsByTheKeyboard() {
        var s = ConvoySheetState()
        s.cardContent = 300
        #expect(s.cardDetent(room: room) == 300)
        s.keyboardFrame(CGRect(x: 0, y: 500, width: 400, height: 300), screenHeight: 800)
        #expect(s.cardKeyboard == 300)
        #expect(s.cardDetent(room: room) == 600)
        // The sheet's height for the camera stays the card's own.
        #expect(s.cardHeight(room: room) == 300)
        s.keyboardGone()
        #expect(s.cardDetent(room: room) == 300)
    }

    @Test func theCardSheetWithTheKeyboardNeverPassesTheRoom() {
        var s = ConvoySheetState()
        s.cardContent = 400
        s.keyboardFrame(CGRect(x: 0, y: 450, width: 400, height: 350), screenHeight: 800)
        #expect(s.cardDetent(room: 600) == 600)
    }

    @Test func aKeyboardFrameOffScreenCoversNothing() {
        var s = ConvoySheetState()
        s.keyboardFrame(CGRect(x: 0, y: 800, width: 400, height: 300), screenHeight: 800)
        #expect(s.cardKeyboard == 0)
        s.keyboardFrame(.null, screenHeight: 800)
        #expect(s.cardKeyboard == 0)
    }

    @Test func theCardsSafeAreaReadWithTheKeyboardUpIsIgnored() {
        var s = ConvoySheetState()
        s.readCardSafeBottom(34)
        #expect(s.cardSafeBottom == 34)
        s.keyboardFrame(CGRect(x: 0, y: 500, width: 400, height: 300), screenHeight: 800)
        s.readCardSafeBottom(300)
        #expect(s.cardSafeBottom == 34)
        s.keyboardGone()
        s.readCardSafeBottom(0)
        #expect(s.cardSafeBottom == 0)
    }
}
