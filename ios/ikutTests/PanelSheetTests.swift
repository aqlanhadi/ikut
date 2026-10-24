import SwiftUI
import Testing
@testable import ikut

struct PanelSheetTests {
    private func heights(folded: CGFloat? = 300, unfolded: CGFloat? = 480, card: CGFloat? = 340, bar: CGFloat? = 0,
                         room: CGFloat? = 700) -> PanelSheet.Heights {
        PanelSheet.heights(folded: folded, unfolded: unfolded, card: card, bar: bar, room: room)
    }

    @Test func shortAndTallAreTheMeasuredPanelPlusTheMeasuredBar() {
        let h = heights(bar: 62)
        #expect(h.short == 362)
        #expect(h.tall == 542)
        // The stop card has no bar.
        #expect(h.card == 340)
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
        let h = heights(folded: nil, unfolded: nil, card: nil, bar: nil)
        #expect(h.short == PanelSheet.foldedEstimate + PanelSheet.barEstimate)
        #expect(h.tall == PanelSheet.unfoldedEstimate + PanelSheet.barEstimate)
        #expect(h.card == PanelSheet.cardEstimate)
    }

    @Test func neitherHeightPassesTheRoomUnderThePills() {
        let h = heights(folded: 300, unfolded: 900, card: 900, room: 600)
        #expect(h.tall == 600)
        #expect(h.card == 600)
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

    @Test func detentsAreTheShortAndTallOneOrTheCardsOwn() {
        let h = heights()
        #expect(PanelSheet.detents(.folded, in: h) == [.height(300), .height(480)])
        #expect(PanelSheet.detents(.unfolded, in: h) == [.height(300), .height(480)])
        #expect(PanelSheet.detents(.card, in: h) == [.height(340)])
        #expect(PanelSheet.detent(.folded, in: h) == .height(300))
        #expect(PanelSheet.detent(.unfolded, in: h) == .height(480))
        #expect(PanelSheet.detent(.card, in: h) == .height(340))
    }

    @Test func aCardOpenWinsOverTheFoldedState() {
        #expect(PanelSheet.shown(expanded: false, cardOpen: false) == .folded)
        #expect(PanelSheet.shown(expanded: true, cardOpen: false) == .unfolded)
        #expect(PanelSheet.shown(expanded: true, cardOpen: true) == .card)
        #expect(PanelSheet.shown(expanded: false, cardOpen: true) == .card)
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
        let h = PanelSheet.heights(folded: 400, unfolded: 480, card: 300, bar: 60, room: nil)
        #expect(h.short == 460)
        #expect(h.tall == 540)
        #expect(h.card == 300)
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
        #expect(PanelSheet.height(.card, in: h) == 340)
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
}
