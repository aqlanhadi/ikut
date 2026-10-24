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

    /// A card has the one detent that fits it; the panel has its short and tall one.
    static func detents(_ shown: Shown, in heights: Heights) -> Set<PresentationDetent> {
        shown == .card ? [.height(heights.card)] : [.height(heights.short), .height(heights.tall)]
    }

    static func detent(_ shown: Shown, in heights: Heights) -> PresentationDetent { .height(height(shown, in: heights)) }

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
