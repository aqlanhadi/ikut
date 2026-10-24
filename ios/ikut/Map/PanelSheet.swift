import SwiftUI

/// The sizes, detents and cover rule of the driving screen's convoy sheet, pure so they can be tested.
/// The sheet is Apple's own (`.sheet`, always up, the map above it stays touchable): short shows today's
/// folded panel, tall the unfolded one, and an open stop card takes the sheet's place at its own height.
/// Heights are the panel's own measured height, so the text size is followed; until a layout has been
/// seen once, an estimate stands in. Neither ever passes the room under the pills and banners.
enum PanelSheet {
    /// What the sheet is showing now.
    enum Shown: Equatable { case folded, unfolded, card }

    /// The panel's content heights before they are measured (folded, then unfolded), without the home indicator.
    static let foldedEstimate: CGFloat = 290
    static let unfoldedEstimate: CGFloat = 520
    static let cardEstimate: CGFloat = 330
    /// The sheet never gets smaller than this, however little room the pills leave.
    static let minimumHeight: CGFloat = 150

    struct Heights: Equatable {
        var short: CGFloat
        var tall: CGFloat
        var card: CGFloat
    }

    /// The detent heights: each content height (nil until seen) plus the home indicator, capped at `room`,
    /// the map's height under the pills and banners (nil before the map is measured).
    static func heights(folded: CGFloat?, unfolded: CGFloat?, card: CGFloat?, bottomInset: CGFloat, room: CGFloat?) -> Heights {
        let cap = max(room ?? .greatestFiniteMagnitude, minimumHeight)
        func fit(_ content: CGFloat?, _ estimate: CGFloat) -> CGFloat { min((content ?? estimate) + bottomInset, cap).rounded() }
        let short = fit(folded, foldedEstimate)
        return Heights(short: short, tall: max(short, fit(unfolded, unfoldedEstimate)), card: fit(card, cardEstimate))
    }

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

    /// Whether a dragged sheet settled on the tall detent (a dragged sheet reports only its detent). When the
    /// two are the same height there is nothing to unfold, and the sheet counts as folded.
    static func isTall(_ detent: PresentationDetent, in heights: Heights) -> Bool {
        heights.tall > heights.short && BottomSheet.isTall(detent, tall: .height(heights.tall))
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
