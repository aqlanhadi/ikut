import Foundation
import SwiftUI
import Testing
@testable import ikut

/// The app's one set of sheet stops (D116) and that every layer reads it.
@MainActor struct SheetStopsTests {
    nonisolated static let sizes: [CGFloat] = [470, 560, 658, 900]

    @Test func theStopsAtTheDefaultTextSizeOnTheReferenceScreen() {
        #expect(SheetStops.collapsed(scale: 1, screenHeight: 874) == 282)
        #expect(SheetStops.mid(scale: 1, screenHeight: 874) == 470)
        #expect(SheetStops.tall == .large)
    }

    @Test(arguments: sizes, [CGFloat(874), 667])
    func collapsedIsBelowMidWhichIsBelowTheScreenAndMidKeepsTheMap(scaledMedium: CGFloat, screen: CGFloat) {
        let scale = SheetStops.scale(of: scaledMedium, base: SheetStops.midBase)
        let collapsed = SheetStops.collapsed(scale: scale, screenHeight: screen)
        let mid = SheetStops.mid(scale: scale, screenHeight: screen)
        #expect(collapsed <= mid)
        #expect(mid <= screen)
        #expect(mid <= screen * SheetStops.midShare)
        #expect(collapsed <= screen * SheetStops.collapsedShare)
    }

    @Test func aSmallPhoneKeepsItsMap() {
        #expect(abs(SheetStops.mid(scale: 1, screenHeight: 667) - 366.85) < 0.01)
        #expect(abs(SheetStops.collapsed(scale: 1, screenHeight: 667) - 280.14) < 0.01)
    }

    @Test func theStopsGrowWithTheTextSizeAndNeverShrinkBelowTheDefault() {
        #expect(SheetStops.collapsed(scale: 0.5) == 282)
        #expect(SheetStops.mid(scale: 0.5) == 470)
        #expect(SheetStops.collapsed(scale: 1.2) > 282)
        // Mid is already at its 55% cap on 874 pt, so it only grows on a taller screen.
        #expect(SheetStops.mid(scale: 1.9, screenHeight: 1200) > 470)
    }

    // MARK: every layer reads them

    @Test func homesListAndAPickedTripAreTheCollapsedStopAndTheDrivingFoldedSheetRestsThere() {
        let collapsed = SheetStops.collapsed(scale: 1)
        #expect(HomeSheet.height(.list, compact: HomeSheet.compact(scaled: HomeSheet.compactHeight)) == collapsed)
        #expect(HomeSheet.height(.leftTrip, compact: HomeSheet.compact(scaled: HomeSheet.compactHeight)) == collapsed)
        #expect(PanelSheet.heights(folded: nil, unfolded: nil, room: nil).short == collapsed)
    }

    @Test func theLobbyAndNewTripAreTheMidStopAndTheDrivingUnfoldedSheetNeverPassesIt() {
        let mid = SheetStops.mid(scale: 1)
        #expect(LobbySheet.compact(scaled: LobbySheet.compactHeight) == mid)
        #expect(HomeSheet.height(.newTrip, compact: 282) == mid)
        #expect(HomeSheet.height(.newTrip, compact: 282, medium: 400) == 400)
        #expect(PanelSheet.heights(folded: nil, unfolded: nil, room: nil, mid: mid).tall == mid)
    }

    @Test(arguments: sizes, [CGFloat(874), 667])
    func everyLayersShortAndMediumDetentsComeFromTheOneSource(scaledMedium: CGFloat, screen: CGFloat) {
        let scale = SheetStops.scale(of: scaledMedium, base: SheetStops.midBase)
        let collapsed = SheetStops.collapsed(scale: scale, screenHeight: screen)
        let mid = SheetStops.mid(scale: scale, screenHeight: screen)
        let compact = HomeSheet.compact(scaled: HomeSheet.compactHeight * scale, screenHeight: screen)
        let medium = LobbySheet.compact(scaled: scaledMedium, screenHeight: screen)
        #expect(abs(compact - collapsed) < 1e-9)
        #expect(abs(medium - mid) < 1e-9)
        #expect(HomeSheet.height(.list, compact: compact, medium: medium) == compact)
        #expect(HomeSheet.height(.leftTrip, compact: compact, medium: medium) == compact)
        #expect(HomeSheet.height(.newTrip, compact: compact, medium: medium) == medium)
        #expect(LobbySheet.medium(medium) == .height(medium))
        // The padding is the collapsed stop's reach, whatever the mode.
        #expect(abs(LobbySheet.mapPadding(scaledMedium: scaledMedium, screenHeight: screen) - (collapsed + BottomSheet.detentExtra)) < 1e-9)
    }

    // MARK: the driving sheet

    @Test func unfoldedIsTheSmallerOfItsMeasuredHeightAndMid() {
        // A big convoy (content 700) is capped at mid and scrolls; a small one (content 300) stays as measured.
        let big = PanelSheet.heights(folded: 220, unfolded: 700, bar: 62, room: 2000, mid: 470)
        #expect(big.short == 282 && big.tall == 470)
        let small = PanelSheet.heights(folded: 220, unfolded: 300, bar: 62, room: 2000, mid: 470)
        #expect(small.tall == 362)
        // Never under the folded sheet, even when mid is lower than it (a small phone at a large text size).
        let low = PanelSheet.heights(folded: 400, unfolded: 700, bar: 62, room: 2000, mid: 367)
        #expect(low.tall == low.short)
    }

    @Test func theDetentChoiceStillMapsWhenUnfoldedEqualsMidOrFolded() {
        let capped = PanelSheet.heights(folded: 220, unfolded: 700, bar: 62, room: 2000, mid: 470)
        #expect(PanelSheet.choice(.height(capped.short), in: capped) == .folded)
        #expect(PanelSheet.choice(.height(capped.tall), in: capped) == .unfolded)
        #expect(PanelSheet.choice(.height(capped.full), in: capped) == .pulledUp)
        // Unfolded equal to folded: the one detent reads as folded, and the pulled-up one is still distinct.
        let same = PanelSheet.heights(folded: 400, unfolded: 700, bar: 62, room: 2000, mid: 367)
        #expect(PanelSheet.choice(.height(same.short), in: same) == .folded)
        #expect(PanelSheet.choice(.height(same.full), in: same) == .pulledUp)
        // Mid equal to the room: the one top detent is pulled up.
        let tight = PanelSheet.heights(folded: 220, unfolded: 700, bar: 62, room: 470, mid: 470)
        #expect(PanelSheet.choice(.height(tight.tall), in: tight) == .pulledUp)
    }
}
