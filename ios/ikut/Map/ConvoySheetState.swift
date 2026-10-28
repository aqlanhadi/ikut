import SwiftUI

/// What the card sheet over the convoy sheet shows.
enum MapCard: Equatable, Identifiable {
    case report, stopRequest, arrival(String)
    /// One identity for all: a card changing into another swaps in the sheet that is up, never dismisses and re-presents.
    var id: String { "card" }
}

/// The motion and hand-over state of the driving screen's convoy sheet (D63 B3): the panel's measured heights and the ones it holds while it moves, and the card sheet over it (which card is wanted, which is
/// up, which is on its way out, what the keyboard covers). A value type with no view in it, so every transition is a
/// plain mutation that a test can run; `TripMapView` keeps it in one `@State`, wraps a change in `withAnimation`
/// (`Motion.sheet`) and runs the timers (the held heights' release, the dismissal fallback), which are the only parts
/// that need a clock. The sizes and rules themselves stay in `PanelSheet`; which size the sheet shows, and whether it is
/// up, are the one sheet's (`TripSheet`, D63 C3).
struct ConvoySheetState: Equatable {
    /// The panel's measured heights (nil until each layout is seen): folded list, unfolded list, the card, the
    /// pinned bar, and the banner on top of the panel (0 without one).
    var foldedContent: CGFloat?
    var unfoldedContent: CGFloat?
    var cardContent: CGFloat?
    var barContent: CGFloat?
    var topContent: CGFloat = 0
    /// One sheet motion at a time (D42): while a fold or a drag's release runs, the heights hold (`PanelSheet.settled`).
    private(set) var moving = false
    private(set) var motion = 0
    /// The heights the sheet uses; nil until the first measurement.
    private(set) var appliedHeights: PanelSheet.Heights?
    /// The card sheet on screen, and the one it last showed, so its content stays while it slides down.
    /// `cardDismissing`: a card is on its way out, so the next waits for its dismissal.
    private(set) var presentedCard: MapCard?
    private(set) var lastCard: MapCard?
    private(set) var cardDismissing = false
    /// What is asked for over the sheet: Report, the Pit stop request (opened only by a tap on the button) and the
    /// planned stop whose "who is here" card is open (the Next stop cell).
    var reportOpen = false
    var stopCardOpen = false
    var arrivalStopId: String?
    /// The sheet's and the card sheet's bottom safe areas (the home indicator's), and what the keyboard covers of the
    /// screen's bottom while a card's field is typed in (`PanelSheet.keyboardCover`).
    var sheetSafeBottom: CGFloat = 34
    private(set) var cardSafeBottom: CGFloat = 34
    private(set) var cardKeyboard: CGFloat = 0

    // MARK: Heights

    /// What the layouts measure now. `room`: the map's height under the pills and banners (nil before the map is
    /// measured); `hasTopBanner`: the banner on top of the panel is there.
    func measuredHeights(room: CGFloat?, hasTopBanner: Bool) -> PanelSheet.Heights {
        PanelSheet.heights(folded: foldedContent, unfolded: unfoldedContent, bar: barContent,
                           top: hasTopBanner ? topContent : 0, room: room)
    }

    /// What the sheet uses: the measured heights, held while it moves (`PanelSheet.settled`).
    func heights(room: CGFloat?, hasTopBanner: Bool) -> PanelSheet.Heights {
        appliedHeights ?? measuredHeights(room: room, hasTopBanner: hasTopBanner)
    }

    /// The text size changed: every layout is measured again.
    mutating func forgetMeasuredHeights() {
        foldedContent = nil
        unfoldedContent = nil
        cardContent = nil
    }

    /// The measured heights the sheet may take now, or nil when they are the ones in use already.
    func heightsToTake(room: CGFloat?, hasTopBanner: Bool) -> PanelSheet.Heights? {
        let next = PanelSheet.settled(appliedHeights, measured: measuredHeights(room: room, hasTopBanner: hasTopBanner),
                                      moving: moving)
        return next == appliedHeights ? nil : next
    }

    /// Takes the heights from `heightsToTake`. The first ones come without a motion, a change at rest with the usual one.
    @discardableResult
    mutating func take(_ heights: PanelSheet.Heights) -> Bool {
        let first = appliedHeights == nil
        appliedHeights = heights
        return first
    }

    /// The height of the map the sheets cover at `shown`, for the camera; 0 while the sheet is not `up`.
    func covered(_ shown: PanelSheet.Shown, up: Bool, room: CGFloat?, hasTopBanner: Bool) -> CGFloat {
        guard up else { return 0 }
        return PanelSheet.covered(
            shown: shown, in: heights(room: room, hasTopBanner: hasTopBanner),
            card: presentedCard == nil ? nil : cardHeight(room: room))
    }

    // MARK: One motion

    /// A fold, unfold or pull-up starts: the heights hold until it is over. Returns the motion's number, which
    /// `endMotion` needs.
    mutating func beginMotion() -> Int {
        motion &+= 1
        moving = true
        return motion
    }

    /// A motion's completion (or its longest-wait fallback) arrived. True when that ended the motion and the heights
    /// may be taken now; false when it was an older motion's or the motion is over already.
    mutating func endMotion(_ number: Int) -> Bool {
        guard number == motion, moving else { return false }
        moving = false
        return true
    }

    // MARK: The card

    /// The card wanted over the convoy sheet: Report, the Pit stop request or the who-is-here card. Each needs what it
    /// shows: `reportReady` its context, `stopReady` the stop's, `arrivalLive` its stop still on.
    func wantedCard(reportReady: Bool, stopReady: Bool, arrivalLive: Bool) -> MapCard? {
        if reportOpen, reportReady { return .report }
        if stopCardOpen, stopReady { return .stopRequest }
        if arrivalLive, let id = arrivalStopId { return .arrival(id) }
        return nil
    }

    /// The card sheet's detent: its content's height, up to the room under the pills.
    func cardHeight(room: CGFloat?) -> CGFloat { PanelSheet.cardHeight(content: cardContent, room: room) }

    /// `cardHeight`, taller by the keyboard while one is up, so the card stays above it (Q16).
    func cardDetent(room: CGFloat?) -> CGFloat {
        PanelSheet.cardHeight(content: cardContent, room: room, keyboard: cardKeyboard)
    }

    /// The card sheet's state follows what is wanted. One card at a time: a new one waits for the one on its way out to
    /// be gone (`cardDismissed`), and a card changing into another swaps in the sheet that is up. True when a
    /// dismissal started, so the caller arms `PanelSheet.cardDismissFallback`.
    @discardableResult
    mutating func syncCard(wanted: MapCard?) -> Bool {
        if let wanted { lastCard = wanted }
        return applyCard(PanelSheet.cardSync(cardSheet, wanted: wanted != nil), wanting: wanted)
    }

    /// The sheet reported its dismissal (or the fallback ran): a card still wanted opens now.
    @discardableResult
    mutating func cardDismissed(wanted: MapCard?) -> Bool {
        applyCard(PanelSheet.cardDismissed(cardSheet, wanted: wanted != nil), wanting: wanted)
    }

    private var cardSheet: PanelSheet.CardSheet {
        PanelSheet.CardSheet(presented: presentedCard != nil, dismissing: cardDismissing)
    }

    private mutating func applyCard(_ next: PanelSheet.CardSheet, wanting want: MapCard?) -> Bool {
        let startedDismissing = next.dismissing && !cardDismissing
        presentedCard = next.presented ? (presentedCard ?? want) : nil
        cardDismissing = next.dismissing
        return startedDismissing
    }

    /// The convoy sheet went (the trip ended, the Always explainer): the card went with it, and nothing is on its
    /// way out. It comes back with the convoy sheet if it is still wanted.
    mutating func convoySheetWent() {
        presentedCard = nil
        cardDismissing = PanelSheet.cardsGone.dismissing
    }

    /// A swipe down on a card (Report allows one) closes what it showed; the sheet going away because we cleared
    /// `presentedCard` ourselves has nothing left to clear. False when there was nothing to do.
    @discardableResult
    mutating func cardClosedBySystem() -> Bool {
        guard presentedCard != nil else { return false }
        presentedCard = nil
        cardDismissing = true
        reportOpen = false
        stopCardOpen = false
        arrivalStopId = nil
        return true
    }

    /// The stop requests ran out while the Pit stop card was open: it closes by itself. True when it did.
    @discardableResult
    mutating func stopRequestsChanged(hadRequests: Bool, hasRequests: Bool) -> Bool {
        guard stopCardOpen, hadRequests, !hasRequests else { return false }
        stopCardOpen = false
        return true
    }

    // MARK: The keyboard

    /// The keyboard's end frame changed.
    mutating func keyboardFrame(_ frame: CGRect, screenHeight: CGFloat) {
        cardKeyboard = PanelSheet.keyboardCover(frame: frame, screenHeight: screenHeight)
    }

    mutating func keyboardGone() { cardKeyboard = 0 }

    /// The card's bottom safe area was read; one taken with the keyboard up is the keyboard's and is ignored.
    mutating func readCardSafeBottom(_ reading: CGFloat) {
        cardSafeBottom = PanelSheet.cardSafeBottom(reading: reading, keyboard: cardKeyboard, last: cardSafeBottom)
    }
}
