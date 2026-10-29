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

    @Test func aCardsButtonsHangUntilTheGapUnderThemIsTheCardsPadding() {
        // 34 pt safe area, 20 pt card padding: lifted 14, so 20 pt is left under the buttons.
        #expect(PanelSheet.barLift(safeBottom: 34, gap: Spacing.block) == 10)
        #expect(PanelSheet.barLift(safeBottom: 0, gap: Spacing.block) == 0)
    }

    @Test func theQuestionBannersCornerIsConcentricWithTheOKCapsule() {
        #expect(StopPillView.questionRadius == 44)
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

    @Test func detentsAreTheShortTallAndPulledUpOne() {
        let h = heights()
        #expect(PanelSheet.detents(in: h) == [.height(300), .height(480), .height(700)])
        #expect(PanelSheet.detent(.pulledUp, in: h) == .height(700))
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

    @Test func theListIsUnfoldedAtTallAndPulledUp() {
        #expect(!PanelSheet.Shown.folded.listUnfolded)
        #expect(PanelSheet.Shown.unfolded.listUnfolded)
        #expect(PanelSheet.Shown.pulledUp.listUnfolded)
    }

    // MARK: Pulled up (D53, canvas row L)

    @Test func pulledUpIsTheTallestTheRoomAllows() {
        let h = heights(bar: 62, room: 700)
        #expect(h.tall == 542)
        #expect(h.full == 700)
        #expect(PanelSheet.height(.pulledUp, in: h) == 700)
        // No room measured yet: tall plus an estimate of what continues below it.
        let open = heights(bar: 62, room: nil)
        #expect(open.full == open.tall + PanelSheet.continuationEstimate)
    }

    @Test func pullingUpOnlyAddsBelowSoTheConvoyKeepsItsPlace() {
        // The same panel, unfolded, is on top at tall and at pulled up; the rest follows it.
        let h = heights()
        #expect(PanelSheet.showsContinuation(.pulledUp, in: h))
        #expect(!PanelSheet.showsContinuation(.unfolded, in: h))
        #expect(!PanelSheet.showsContinuation(.folded, in: h))
    }

    @Test func aConvoyAlreadyAsTallAsTheRoomContinuesAtTall() {
        // Tall is capped at the room: there is no taller detent, so the continuation scrolls on below the list.
        let h = heights(folded: 300, unfolded: 900, bar: 62, room: 600)
        #expect(h.tall == 600)
        #expect(h.full == 600)
        #expect(PanelSheet.detents(in: h) == [.height(362), .height(600)])
        #expect(PanelSheet.showsContinuation(.unfolded, in: h))
        #expect(PanelSheet.choice(.height(600), in: h) == .pulledUp)
    }

    @Test func aCardSheetIsAsTallAsItsContentUpToTheRoom() {
        #expect(PanelSheet.cardHeight(content: 340.4, room: 700) == 340)
        #expect(PanelSheet.cardHeight(content: 900, room: 600) == 600)
        #expect(PanelSheet.cardHeight(content: nil, room: 700) == PanelSheet.cardEstimate)
        #expect(PanelSheet.cardHeight(content: nil, room: nil) == PanelSheet.cardEstimate)
        #expect(PanelSheet.cardHeight(content: 900, room: 40) == PanelSheet.minimumHeight)
    }

    // Q16: a passenger typing a stop message on a phone with the software keyboard lost the field under it.
    @Test func withTheKeyboardUpTheCardSheetGrowsByItSoTheFieldStaysAboveIt() {
        // The message screen (about 300 pt) over a 336 pt keyboard: the sheet is 636 tall, the card in its top 300.
        #expect(PanelSheet.cardHeight(content: 300, room: 716, keyboard: 336) == 636)
        // Still never past the room under the pills: the card's body scrolls there.
        #expect(PanelSheet.cardHeight(content: 420, room: 716, keyboard: 336) == 716)
        #expect(PanelSheet.cardHeight(content: 300, room: 716, keyboard: 0) == 300)
    }

    @Test func theKeyboardCoverIsWhatItsEndFrameHidesOfTheScreen() {
        #expect(PanelSheet.keyboardCover(frame: CGRect(x: 0, y: 538, width: 402, height: 336), screenHeight: 874) == 336)
        // Going away: the end frame is below the screen.
        #expect(PanelSheet.keyboardCover(frame: CGRect(x: 0, y: 874, width: 402, height: 336), screenHeight: 874) == 0)
        // A hardware keyboard leaves only the shortcut bar.
        #expect(PanelSheet.keyboardCover(frame: CGRect(x: 0, y: 819, width: 402, height: 55), screenHeight: 874) == 55)
        #expect(PanelSheet.keyboardCover(frame: .zero, screenHeight: 874) == 0)
    }

    @Test func aSafeAreaReadWithTheKeyboardUpDoesNotLiftTheCardButtons() {
        // The keyboard's 316 pt would hang the buttons 296 pt down, under the keyboard: the home indicator's 34 stays.
        #expect(PanelSheet.cardSafeBottom(reading: 316, keyboard: 336, last: 34) == 34)
        #expect(PanelSheet.cardSafeBottom(reading: 34, keyboard: 0, last: 316) == 34)
        #expect(PanelSheet.barLift(safeBottom: PanelSheet.cardSafeBottom(reading: 316, keyboard: 336, last: 34)) == 18)
    }

    @Test func theMapIsCoveredByWhicheverSheetIsTaller() {
        let h = heights()
        #expect(PanelSheet.covered(shown: .folded, in: h, card: nil) == 300)
        #expect(PanelSheet.covered(shown: .folded, in: h, card: 340) == 340)
        #expect(PanelSheet.covered(shown: .unfolded, in: h, card: 340) == 480)
        // Pulled up, the camera keeps the room it had at tall: the map under the lobby doesn't move.
        #expect(PanelSheet.covered(shown: .pulledUp, in: h, card: nil) == 480)
    }

    @Test func aDraggedSheetUnfoldsTheListOnlyAtTheTallDetent() {
        let h = heights()
        #expect(PanelSheet.choice(.height(480), in: h) == .unfolded)
        #expect(PanelSheet.choice(.height(300), in: h) == .folded)
        #expect(PanelSheet.choice(.height(700), in: h) == .pulledUp)
        // Nothing to unfold when the two are one height: that height is the folded one.
        let same = heights(folded: 300, unfolded: 300)
        #expect(PanelSheet.choice(.height(300), in: same) == .folded)
    }

    @Test func aHeightThatChangesWhileTallIsNotTheDriverFoldingTheList() {
        // Tall was 480; the measured height settles at 446 and the sheet reports its old detent once more.
        let now = heights(unfolded: 446)
        #expect(now.tall == 446)
        #expect(PanelSheet.choice(.height(480), in: now) == nil)
        #expect(PanelSheet.choice(.height(446), in: now) == .unfolded)
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

    @Test func theMapInsetFollowsTheDetentOnShow() {
        let h = heights()
        #expect(PanelSheet.height(.folded, in: h) == 300)
        #expect(PanelSheet.height(.unfolded, in: h) == 480)
    }

    @MainActor @Test func theSheetStepsAsideForEachThingThatTakesTheScreen() {
        func presented(_ covers: Set<TripSheetCover>) -> Bool {
            let sheet = TripSheet(size: .driving(.folded))
            sheet.cover(covers, among: TripSheetCover.trip)
            return sheet.presented
        }
        #expect(presented([]))
        #expect(!presented([.tripEnded]))
        #expect(!presented([.alwaysExplainer]))
        // What the pulled-up lobby puts over the whole screen (Change destination, Suggest stops) takes it too.
        #expect(!presented([.changeDestination]))
        #expect(!presented([.suggestStops]))
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
        // A3 and #344: the approach folds, pulled up too; passing the hazard (or giving up on it) never unfolds it.
        #expect(PanelSheet.shown(after: .approaching, from: .unfolded) == .folded)
        #expect(PanelSheet.shown(after: .approaching, from: .pulledUp) == .folded)
        #expect(PanelSheet.shown(after: .approaching, from: .folded) == .folded)
        #expect(PanelSheet.shown(after: .passed, from: .folded) == .folded)
        #expect(PanelSheet.shown(after: .gaveUp, from: .folded) == .folded)
        // Unfolded or pulled up by the driver during the approach: stays as the driver left it.
        #expect(PanelSheet.shown(after: .passed, from: .unfolded) == .unfolded)
        #expect(PanelSheet.shown(after: .passed, from: .pulledUp) == .pulledUp)
    }

    @Test func aStopAskingBringsAPulledUpSheetBackToTallAndLeavesTheOthers() {
        // #402: the pill and the card must not be behind the lobby; folded or tall the sheet stays as it is.
        #expect(PanelSheet.shown(after: .stopAsks, from: .pulledUp) == .unfolded)
        #expect(PanelSheet.shown(after: .stopAsks, from: .unfolded) == .unfolded)
        #expect(PanelSheet.shown(after: .stopAsks, from: .folded) == .folded)
    }

    @Test func aBannerOnTopOfThePanelAddsToEveryHeightUpToTheRoom() {
        // "You're no longer in this trip" sits above the panel at every height.
        let h = PanelSheet.heights(folded: 300, unfolded: 480, bar: 62, top: 120, room: 700)
        #expect(h.short == 482)
        #expect(h.tall == 662)
        #expect(h.full == 700)
        #expect(PanelSheet.heights(folded: 300, unfolded: 480, bar: 62, top: 120, room: 600).tall == 600)
    }
}
