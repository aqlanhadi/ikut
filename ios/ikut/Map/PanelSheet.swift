import SwiftUI

/// The sizes, detents and cover rule of the driving screen's convoy sheet, pure so they can be tested.
/// The sheet is Apple's own (`.sheet`, always up, the map above it stays touchable): short shows today's
/// folded panel, tall the unfolded one, and an open stop card takes the sheet's place at its own height.
/// Heights are the panel's own measured height, so the text size is followed; until a layout has been
/// seen once, an estimate stands in. Neither ever passes the room under the pills and banners.
enum PanelSheet {
    /// What the sheet is showing now.
    enum Shown: Equatable { case folded, unfolded, card }

    /// The panel's content heights before they are measured (folded, then unfolded), without the bar.
    static let foldedEstimate: CGFloat = 220
    static let unfoldedEstimate: CGFloat = 450
    static let cardEstimate: CGFloat = 330
    /// The gap beside Report and Pit stop (to the sheet's side edges), and under them to the sheet's bottom edge.
    static let sideGap: CGFloat = Spacing.l
    /// How far the buttons hang down into the sheet's bottom safe area (the home indicator's) so the gap under them
    /// equals `sideGap`. Never negative, so a sheet without a safe area (an iPhone with a home button) keeps them
    /// where the layout puts them; never more than leaves the indicator's own strip (`indicatorClearance`) free.
    static func barLift(safeBottom: CGFloat) -> CGFloat {
        max(0, min(safeBottom - sideGap, safeBottom - indicatorClearance))
    }
    /// The strip at the very bottom the home indicator draws in; the buttons stay above it.
    static let indicatorClearance: CGFloat = 14
    /// The sheet never gets smaller than this, however little room the pills leave.
    static let minimumHeight: CGFloat = 150

    struct Heights: Equatable {
        var short: CGFloat
        var tall: CGFloat
        var card: CGFloat
    }

    /// The bar's height before it is measured (Report and Pit stop with the space above them).
    static let barEstimate: CGFloat = 62

    /// The detent heights: each panel content height (nil until seen) plus the pinned bar's (nil until seen), capped
    /// at `room`, the map's height under the pills and banners (nil before the map is measured). The card has no
    /// bar. No home-indicator strip is added: a presented sheet already keeps its content out of the bottom safe
    /// area, so adding it again (as Home's formula does for its own header) left about 34 pt of empty space.
    /// When the content is taller than the cap, the list scrolls under the bar and the bar stays in view.
    static func heights(folded: CGFloat?, unfolded: CGFloat?, card: CGFloat?, bar: CGFloat? = nil, room: CGFloat?) -> Heights {
        let cap = max(room ?? .greatestFiniteMagnitude, minimumHeight)
        let barHeight = bar ?? barEstimate
        func fit(_ content: CGFloat?, _ estimate: CGFloat, bar: CGFloat = 0) -> CGFloat {
            min((content ?? estimate) + bar, cap).rounded()
        }
        let short = fit(folded, foldedEstimate, bar: barHeight)
        return Heights(short: short, tall: max(short, fit(unfolded, unfoldedEstimate, bar: barHeight)), card: fit(card, cardEstimate))
    }

    /// What a detent the sheet reports means for the panel: tall (true) or short (false) when it is one of the
    /// two it has now, nothing for any other value. A measured height that changes under an open tall sheet
    /// reports its old detent for a moment; that is not the driver folding the list.
    static func choice(_ detent: PresentationDetent, in heights: Heights) -> Bool? {
        if detent == .height(heights.short) { return false }
        if detent == .height(heights.tall) { return true }
        return nil
    }

    /// How long after a stop card closes the sheet's own detent reports are ignored. Swapping the card's single
    /// detent for the panel's two makes the system pick one and report it, which is not the driver folding the list.
    static let cardSwapQuiet: TimeInterval = 0.8

    /// Whether a detent the sheet reports is the driver's drag: not on a card, and not the system re-picking
    /// after the card closed (`sinceCardClosed`, nil when no card has closed lately).
    static func acceptsDetentReport(shown: Shown, sinceCardClosed: TimeInterval?) -> Bool {
        shown != .card && (sinceCardClosed ?? .greatestFiniteMagnitude) >= cardSwapQuiet
    }

    /// Whether an action waits for the sheet to go (it is up, and its own dismissal runs the action) or runs
    /// at once (the sheet is already gone, so no dismissal will come).
    enum ExitTiming: Equatable { case afterDismissal, now }

    static func exit(sheetUp: Bool) -> ExitTiming { sheetUp ? .afterDismissal : .now }

    static func shown(expanded: Bool, cardOpen: Bool) -> Shown { cardOpen ? .card : (expanded ? .unfolded : .folded) }

    static func height(_ shown: Shown, in heights: Heights) -> CGFloat {
        switch shown {
        case .folded: heights.short
        case .unfolded: heights.tall
        case .card: heights.card
        }
    }

    /// A card has the one detent that fits it; the panel has its short and tall one. While a card opens or closes
    /// (`bridged`) the sheet has all three, so the swap is a move between two detents it already has, which the sheet
    /// animates; swapping the set itself in the same update made it jump to the new height in one frame.
    static func detents(_ shown: Shown, in heights: Heights, bridged: Bool = false) -> Set<PresentationDetent> {
        if bridged { return [.height(heights.short), .height(heights.tall), .height(heights.card)] }
        return shown == .card ? [.height(heights.card)] : [.height(heights.short), .height(heights.tall)]
    }

    /// How long a card swap waits after bridging the detent set before it moves, so the sheet has the set first.
    static let bridgeDelay: TimeInterval = 0.02

    static func detent(_ shown: Shown, in heights: Heights) -> PresentationDetent { .height(height(shown, in: heights)) }

    // MARK: One motion (D42: A1, A2, A3, A6)

    /// A measured height is taken at rest only when it differs from the one in use by more than this (a sub-point
    /// re-layout is not a resize).
    static let settleTolerance: CGFloat = 1
    /// After a fold or card motion has finished (its removed views gone), how long before the held heights are let go.
    static let settleAfterMotion: TimeInterval = 0.1
    /// The longest a motion holds the heights, should its completion never come.
    static let motionLongest: TimeInterval = 1.2

    /// The heights the sheet uses. While it moves (a fold, a drag let go, a card opening or closing) it holds the panel's
    /// short and tall heights, and the card's while the card is shown, so the detent it is moving to never changes under
    /// it (the fold used to hand the sheet a new detent set mid-motion, which it applied in one frame). At rest each
    /// measured height is taken when it differs by more than `settleTolerance`. `applied` nil (nothing used yet): the
    /// measured ones.
    static func settled(_ applied: Heights?, measured: Heights, moving: Bool, shown: Shown) -> Heights {
        guard let applied else { return measured }
        func take(_ old: CGFloat, _ new: CGFloat, hold: Bool) -> CGFloat {
            !hold && abs(new - old) > settleTolerance ? new : old
        }
        return Heights(
            short: take(applied.short, measured.short, hold: moving),
            tall: take(applied.tall, measured.tall, hold: moving),
            card: take(applied.card, measured.card, hold: moving && shown == .card))
    }

    /// What the sheet's body holds. A stop card is laid out unseen over the panel until its height is known
    /// (`cardMeasured`), then the panel goes and the card shows, in the transaction that moves the detent to the card's
    /// height: never both on screen, and never the card at the panel's height.
    struct Layers: Equatable {
        var panel: Bool
        var card: Bool
        var cardVisible: Bool
    }

    static func layers(cardRequested: Bool, cardMeasured: Bool) -> Layers {
        guard cardRequested else { return Layers(panel: true, card: false, cardVisible: false) }
        return cardMeasured
            ? Layers(panel: false, card: true, cardVisible: true)
            : Layers(panel: true, card: true, cardVisible: false)
    }

    /// How long a requested card waits for its height before it opens at what is known.
    static let cardMeasureWait: TimeInterval = 0.3

    /// The moments of a hazard approach that touch the convoy list.
    enum HazardMoment: Equatable { case approaching, passed, gaveUp }

    /// Whether the list is unfolded after `moment`, from `expanded` now. The approach folds it, so my car and the hazard
    /// have the room; passing the hazard (or giving up on it) leaves it as it is: the owner's choice (#344), since the
    /// unfolded list covers more than half the map while the car is moving.
    static func expanded(_ expanded: Bool, after moment: HazardMoment) -> Bool {
        moment == .approaching ? false : expanded
    }

    /// The sheet steps aside for everything that is pushed or presented from under it: the trip ending (the
    /// recap), leaving the screen, and the Always location sheet that the lobby presents.
    static func isCovered(ended: Bool, leaving: Bool, explainerWants: Bool) -> Bool {
        ended || leaving || explainerWants
    }

    /// The room for the sheet: the map's full height less what the pills and banners need above it.
    static func room(mapHeight: CGFloat, reserved: CGFloat) -> CGFloat? {
        mapHeight > 0 ? mapHeight - reserved : nil
    }
}

private struct InPanelSheetKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the convoy sheet: the stop cards drop their own glass, the sheet is the surface.
    var inPanelSheet: Bool {
        get { self[InPanelSheetKey.self] }
        set { self[InPanelSheetKey.self] = newValue }
    }
}
