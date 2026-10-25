import SwiftUI
import Testing
@testable import ikut

struct PanelSheetTests {
    private func heights(folded: CGFloat? = 300, unfolded: CGFloat? = 480, bar: CGFloat? = 0,
                         room: CGFloat? = 700) -> PanelSheet.Heights {
        PanelSheet.heights(folded: folded, unfolded: unfolded, bar: bar, room: room)
    }

    @Test func shortAndTallAreTheMeasuredPanelPlusTheMeasuredBar() {
        let h = heights(bar: 62)
        #expect(h.short == 362)
        #expect(h.tall == 542)
    }

    @Test func theBarIsKeptWhenTheContentIsCapped() {
        // The panel is taller than the room: the sheet stops at the room, and the list scrolls under the bar.
        let h = heights(folded: 300, unfolded: 900, bar: 62, room: 600)
        #expect(h.tall == 600)
        #expect(h.short == 362)
        // Content that fits only without the bar is capped too, never past the room.
        #expect(heights(folded: 580, unfolded: 580, bar: 62, room: 600).short == 600)
    }

    @Test func aBarNotMeasuredYetUsesItsEstimate() {
        let h = heights(bar: nil)
        #expect(h.short == 300 + PanelSheet.barEstimate)
        #expect(h.tall == 480 + PanelSheet.barEstimate)
    }

    @Test func theBarHangsIntoTheSafeAreaSoTheGapUnderItEqualsTheSideGap() {
        // iPhone with a home indicator (34 pt): lifted 34 - 16 = 18, so 16 pt is left under the buttons.
        #expect(PanelSheet.barLift(safeBottom: 34) == 18)
        // No safe area (home button): nothing to hang into.
        #expect(PanelSheet.barLift(safeBottom: 0) == 0)
        #expect(PanelSheet.barLift(safeBottom: 10) == 0)
        // Never into the indicator's own strip.
        #expect(PanelSheet.barLift(safeBottom: 20) <= 20 - PanelSheet.indicatorClearance)
    }

    @Test func aLayoutNotSeenYetUsesTheEstimate() {
        let h = heights(folded: nil, unfolded: nil, bar: nil)
        #expect(h.short == PanelSheet.foldedEstimate + PanelSheet.barEstimate)
        #expect(h.tall == PanelSheet.unfoldedEstimate + PanelSheet.barEstimate)
    }

    @Test func neitherHeightPassesTheRoomUnderThePills() {
        let h = heights(folded: 300, unfolded: 900, room: 600)
        #expect(h.tall == 600)
        #expect(h.short == 300)
        // A big text size makes even the folded panel too tall: it gives way to the pills.
        #expect(heights(folded: 800, unfolded: 900, room: 600).short == 600)
    }

    @Test func theSheetNeverShrinksBelowItsMinimum() {
        let h = heights(room: 40)
        #expect(h.short == PanelSheet.minimumHeight)
        #expect(h.tall == PanelSheet.minimumHeight)
    }

    @Test func tallIsNeverBelowShort() {
        let h = heights(folded: 400, unfolded: 300)
        #expect(h.tall == h.short)
    }

    @Test func noRoomMeasuredYetCapsNothing() {
        #expect(heights(folded: 300, unfolded: 900, room: nil).tall == 900)
        #expect(PanelSheet.room(mapHeight: 0, reserved: 74) == nil)
        #expect(PanelSheet.room(mapHeight: 874, reserved: 74) == 800)
    }

    @Test func detentsAreTheShortAndTallOne() {
        let h = heights()
        #expect(PanelSheet.detents(in: h) == [.height(300), .height(480)])
        #expect(PanelSheet.detent(.folded, in: h) == .height(300))
        #expect(PanelSheet.detent(.unfolded, in: h) == .height(480))
    }

    @Test func aCardWantedWithNothingUpOpens() {
        #expect(PanelSheet.cardSync(.init(), wanted: true) == .init(presented: true, dismissing: false))
    }

    @Test func aCardWantedWhileAnotherIsUpSwapsInPlace() {
        let up = PanelSheet.CardSheet(presented: true, dismissing: false)
        #expect(PanelSheet.cardSync(up, wanted: true) == up)
    }

    @Test func aCardWantedWhileOneSlidesDownWaitsThenOpens() {
        let closing = PanelSheet.CardSheet(presented: false, dismissing: true)
        #expect(PanelSheet.cardSync(closing, wanted: true) == closing)
        #expect(PanelSheet.cardDismissed(closing, wanted: true) == .init(presented: true, dismissing: false))
        #expect(PanelSheet.cardDismissed(closing, wanted: false) == .init())
    }

    @Test func noCardWantedDismissesTheOneThatIsUp() {
        let up = PanelSheet.CardSheet(presented: true, dismissing: false)
        #expect(PanelSheet.cardSync(up, wanted: false) == .init(presented: false, dismissing: true))
        #expect(PanelSheet.cardSync(.init(), wanted: false) == .init())
    }

    @Test func aDismissalThatNeverComesDoesNotHoldTheNextCardBack() {
        // The fallback runs the same step as the sheet's own report; and the convoy sheet going away clears it.
        let stuck = PanelSheet.CardSheet(presented: false, dismissing: true)
        #expect(PanelSheet.cardDismissed(stuck, wanted: true).presented)
        #expect(PanelSheet.cardsGone == .init(presented: false, dismissing: false))
        #expect(PanelSheet.cardSync(PanelSheet.cardsGone, wanted: true).presented)
        #expect(PanelSheet.cardDismissFallback > 0)
    }

    @Test func theShownStateFollowsTheFold() {
        #expect(PanelSheet.shown(expanded: false) == .folded)
        #expect(PanelSheet.shown(expanded: true) == .unfolded)
    }

    @Test func aCardSheetIsAsTallAsItsContentUpToTheRoom() {
        #expect(PanelSheet.cardHeight(content: 340.4, room: 700) == 340)
        #expect(PanelSheet.cardHeight(content: 900, room: 600) == 600)
        #expect(PanelSheet.cardHeight(content: nil, room: 700) == PanelSheet.cardEstimate)
        #expect(PanelSheet.cardHeight(content: nil, room: nil) == PanelSheet.cardEstimate)
        #expect(PanelSheet.cardHeight(content: 900, room: 40) == PanelSheet.minimumHeight)
    }

    @Test func theMapIsCoveredByWhicheverSheetIsTaller() {
        let h = heights()
        #expect(PanelSheet.covered(shown: .folded, in: h, card: nil) == 300)
        #expect(PanelSheet.covered(shown: .folded, in: h, card: 340) == 340)
        #expect(PanelSheet.covered(shown: .unfolded, in: h, card: 340) == 480)
    }

    @Test func aDraggedSheetUnfoldsTheListOnlyAtTheTallDetent() {
        let h = heights()
        #expect(PanelSheet.choice(.height(480), in: h) == true)
        #expect(PanelSheet.choice(.height(300), in: h) == false)
        // Nothing to unfold when the two are one height: that height is the folded one.
        let same = heights(folded: 300, unfolded: 300)
        #expect(PanelSheet.choice(.height(300), in: same) == false)
    }

    @Test func aHeightThatChangesWhileTallIsNotTheDriverFoldingTheList() {
        // Tall was 480; the measured height settles at 446 and the sheet reports its old detent once more.
        let now = heights(unfolded: 446)
        #expect(now.tall == 446)
        #expect(PanelSheet.choice(.height(480), in: now) == nil)
        #expect(PanelSheet.choice(.height(446), in: now) == true)
        // Likewise a short that moved under a folded sheet.
        #expect(PanelSheet.choice(.height(300), in: heights(folded: 280)) == nil)
    }

    @Test func theSheetAddsNothingButTheBarToTheContent() {
        // The home indicator's strip is the sheet's own (adding it again left 34 pt of empty space under the buttons).
        let h = PanelSheet.heights(folded: 400, unfolded: 480, bar: 60, room: nil)
        #expect(h.short == 460)
        #expect(h.tall == 540)
        #expect(PanelSheet.sideGap == Spacing.l)
    }

    @Test func anExitWaitsForTheSheetOnlyWhileItIsUp() {
        #expect(PanelSheet.exit(sheetUp: true) == .afterDismissal)
        #expect(PanelSheet.exit(sheetUp: false) == .now)
    }

    @Test func theMapInsetFollowsTheDetentOnShow() {
        let h = heights()
        #expect(PanelSheet.height(.folded, in: h) == 300)
        #expect(PanelSheet.height(.unfolded, in: h) == 480)
    }

    @Test func theSheetStepsAsideForEachThingThatTakesTheScreen() {
        #expect(!PanelSheet.isCovered(ended: false, leaving: false, explainerWants: false))
        #expect(PanelSheet.isCovered(ended: true, leaving: false, explainerWants: false))
        #expect(PanelSheet.isCovered(ended: false, leaving: true, explainerWants: false))
        #expect(PanelSheet.isCovered(ended: false, leaving: false, explainerWants: true))
    }

    @Test func theLobbysAlwaysSheetWaitsForTheConvoySheetToGo() {
        #expect(!TripSessionLogic.explainerVisible(wanted: true, askShowing: false, mapSheetUp: true))
        #expect(TripSessionLogic.explainerVisible(wanted: true, askShowing: false, mapSheetUp: false))
        // An ask on screen keeps both the explainer and the cover away: the ask is answered first.
        #expect(!TripSessionLogic.explainerWants(wanted: true, askShowing: true))
        #expect(TripSessionLogic.explainerWants(wanted: true, askShowing: false))
        #expect(!TripSessionLogic.explainerWants(wanted: false, askShowing: false))
    }

    // MARK: One motion (D42)

    @Test func whileTheSheetMovesThePanelHeightsHold() {
        // A1/A2: the fold's outgoing rows made the panel measure taller mid-motion, which changed the detent under the sheet.
        let applied = PanelSheet.Heights(short: 282, tall: 512)
        let measured = PanelSheet.Heights(short: 600, tall: 700)
        #expect(PanelSheet.settled(applied, measured: measured, moving: true) == applied)
    }

    @Test func atRestANewHeightIsTakenOnlyPastOnePoint() {
        let applied = PanelSheet.Heights(short: 282, tall: 512)
        let nudged = PanelSheet.Heights(short: 282.6, tall: 511.2)
        #expect(PanelSheet.settled(applied, measured: nudged, moving: false) == applied)
        let grown = PanelSheet.Heights(short: 300, tall: 560)
        #expect(PanelSheet.settled(applied, measured: grown, moving: false) == grown)
        // Nothing in use yet: the measured heights.
        #expect(PanelSheet.settled(nil, measured: grown, moving: true) == grown)
    }

    @Test func aHazardApproachFoldsTheListAndPassingItLeavesItFolded() {
        // A3 and #344: the approach folds; passing the hazard (or giving up on it) never unfolds it.
        #expect(PanelSheet.expanded(true, after: .approaching) == false)
        #expect(PanelSheet.expanded(false, after: .approaching) == false)
        #expect(PanelSheet.expanded(false, after: .passed) == false)
        #expect(PanelSheet.expanded(false, after: .gaveUp) == false)
        // Unfolded by the driver during the approach: stays as the driver left it.
        #expect(PanelSheet.expanded(true, after: .passed) == true)
    }
}
