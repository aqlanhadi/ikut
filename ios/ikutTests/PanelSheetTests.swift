import SwiftUI
import Testing
@testable import ikut

struct PanelSheetTests {
    private func heights(folded: CGFloat? = 300, unfolded: CGFloat? = 480, card: CGFloat? = 340,
                         inset: CGFloat = 34, room: CGFloat? = 700) -> PanelSheet.Heights {
        PanelSheet.heights(folded: folded, unfolded: unfolded, card: card, bottomInset: inset, room: room)
    }

    @Test func shortAndTallFollowTheMeasuredPanelPlusTheHomeIndicator() {
        let h = heights()
        #expect(h.short == 334)
        #expect(h.tall == 514)
        #expect(h.card == 374)
    }

    @Test func aLayoutNotSeenYetUsesTheEstimate() {
        let h = heights(folded: nil, unfolded: nil, card: nil)
        #expect(h.short == PanelSheet.foldedEstimate + 34)
        #expect(h.tall == PanelSheet.unfoldedEstimate + 34)
        #expect(h.card == PanelSheet.cardEstimate + 34)
    }

    @Test func neitherHeightPassesTheRoomUnderThePills() {
        let h = heights(folded: 300, unfolded: 900, card: 900, room: 600)
        #expect(h.tall == 600)
        #expect(h.card == 600)
        #expect(h.short == 334)
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
        #expect(heights(folded: 300, unfolded: 900, room: nil).tall == 934)
        #expect(PanelSheet.room(mapHeight: 0, reserved: 74) == nil)
        #expect(PanelSheet.room(mapHeight: 874, reserved: 74) == 800)
    }

    @Test func detentsAreTheShortAndTallOneOrTheCardsOwn() {
        let h = heights()
        #expect(PanelSheet.detents(.folded, in: h) == [.height(334), .height(514)])
        #expect(PanelSheet.detents(.unfolded, in: h) == [.height(334), .height(514)])
        #expect(PanelSheet.detents(.card, in: h) == [.height(374)])
        #expect(PanelSheet.detent(.folded, in: h) == .height(334))
        #expect(PanelSheet.detent(.unfolded, in: h) == .height(514))
        #expect(PanelSheet.detent(.card, in: h) == .height(374))
    }

    @Test func aCardOpenWinsOverTheFoldedState() {
        #expect(PanelSheet.shown(expanded: false, cardOpen: false) == .folded)
        #expect(PanelSheet.shown(expanded: true, cardOpen: false) == .unfolded)
        #expect(PanelSheet.shown(expanded: true, cardOpen: true) == .card)
        #expect(PanelSheet.shown(expanded: false, cardOpen: true) == .card)
    }

    @Test func aDraggedSheetUnfoldsTheListOnlyAtTheTallDetent() {
        let h = heights()
        #expect(PanelSheet.isTall(.height(514), in: h))
        #expect(!PanelSheet.isTall(.height(334), in: h))
        // Nothing to unfold when the two are one height.
        let same = heights(folded: 300, unfolded: 300)
        #expect(!PanelSheet.isTall(.height(334), in: same))
    }

    @Test func theMapInsetFollowsTheDetentOnShow() {
        let h = heights()
        #expect(PanelSheet.height(.folded, in: h) == 334)
        #expect(PanelSheet.height(.unfolded, in: h) == 514)
        #expect(PanelSheet.height(.card, in: h) == 374)
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
