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

    @Test func theSystemsDetentPickAfterACardClosesIsNotAFold() {
        #expect(!PanelSheet.acceptsDetentReport(shown: .card, sinceCardClosed: nil))
        #expect(!PanelSheet.acceptsDetentReport(shown: .unfolded, sinceCardClosed: 0.1))
        #expect(PanelSheet.acceptsDetentReport(shown: .unfolded, sinceCardClosed: PanelSheet.cardSwapQuiet))
        #expect(PanelSheet.acceptsDetentReport(shown: .folded, sinceCardClosed: nil))
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

    // MARK: One motion (D42)

    @Test func whileTheSheetMovesThePanelHeightsHold() {
        // A1/A2: the fold's outgoing rows made the panel measure taller mid-motion, which changed the detent under the sheet.
        let applied = PanelSheet.Heights(short: 282, tall: 512, card: 330)
        let measured = PanelSheet.Heights(short: 600, tall: 700, card: 330)
        #expect(PanelSheet.settled(applied, measured: measured, moving: true, shown: .folded) == applied)
        #expect(PanelSheet.settled(applied, measured: measured, moving: true, shown: .unfolded) == applied)
    }

    @Test func atRestANewHeightIsTakenOnlyPastOnePoint() {
        let applied = PanelSheet.Heights(short: 282, tall: 512, card: 330)
        let nudged = PanelSheet.Heights(short: 282.6, tall: 511.2, card: 330.9)
        #expect(PanelSheet.settled(applied, measured: nudged, moving: false, shown: .folded) == applied)
        let grown = PanelSheet.Heights(short: 300, tall: 560, card: 410)
        #expect(PanelSheet.settled(applied, measured: grown, moving: false, shown: .folded) == grown)
        // Nothing in use yet: the measured heights.
        #expect(PanelSheet.settled(nil, measured: grown, moving: true, shown: .folded) == grown)
    }

    @Test func aCardsHeightHoldsOnlyWhileTheCardIsShownAndMoving() {
        let applied = PanelSheet.Heights(short: 282, tall: 512, card: 330)
        let measured = PanelSheet.Heights(short: 282, tall: 512, card: 420)
        // A6: a card measured while the list folds still opens at its own height.
        #expect(PanelSheet.settled(applied, measured: measured, moving: true, shown: .folded).card == 420)
        #expect(PanelSheet.settled(applied, measured: measured, moving: true, shown: .card).card == 330)
        #expect(PanelSheet.settled(applied, measured: measured, moving: false, shown: .card).card == 420)
    }

    @Test func aCardIsLaidOutUnseenUntilItsHeightIsKnownThenReplacesThePanel() {
        // A6: never the panel and the card on screen together, never the card at the panel's height.
        #expect(PanelSheet.layers(cardRequested: false, cardMeasured: false) == .init(panel: true, card: false, cardVisible: false))
        #expect(PanelSheet.layers(cardRequested: true, cardMeasured: false) == .init(panel: true, card: true, cardVisible: false))
        #expect(PanelSheet.layers(cardRequested: true, cardMeasured: true) == .init(panel: false, card: true, cardVisible: true))
        // A card closed while its measured flag is still set shows the panel at once.
        #expect(PanelSheet.layers(cardRequested: false, cardMeasured: true) == .init(panel: true, card: false, cardVisible: false))
        for requested in [false, true] {
            for measured in [false, true] {
                let l = PanelSheet.layers(cardRequested: requested, cardMeasured: measured)
                #expect(!(l.panel && l.cardVisible))
            }
        }
    }

    @Test func aCardSwapMovesBetweenDetentsTheSheetAlreadyHas() {
        // A6: swapping the detent set in the same update as the selection made the sheet jump to the card's height.
        let h = heights()
        for shown in [PanelSheet.Shown.folded, .unfolded, .card] {
            let bridged = PanelSheet.detents(shown, in: h, bridged: true)
            #expect(bridged == [.height(h.short), .height(h.tall), .height(h.card)])
            for target in [PanelSheet.Shown.folded, .unfolded, .card] {
                #expect(bridged.contains(PanelSheet.detent(target, in: h)))
            }
        }
        // At rest the card has only its own detent, so it can't be dragged to the panel's.
        #expect(PanelSheet.detents(.card, in: h) == [.height(h.card)])
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
