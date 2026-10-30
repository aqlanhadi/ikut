import SwiftUI

/// The app's one set of sheet stops (D116), in points at the default text size on an 874 pt screen. Every sheet that
/// rests at a short or medium height reads it, so the heights agree from screen to screen:
/// - collapsed (239): Home's list and a picked trip or a trip you left, and the driving folded sheet at rest;
/// - mid (470): the lobby's medium sheet, Home's New trip, and the driving unfolded sheet (never taller);
/// - tall: iOS's own full height (`.large`).
/// Outside the stops on purpose: the keyboard steps (Where to?, joining, the name step), the stop card (its content's
/// height) and the sheets iOS presents itself (report, the always-location explainer, Suggest stops).
enum SheetStops {
    /// The convoy's resting folded sheet: its folded content plus its bar.
    static let collapsedBase: CGFloat = PanelSheet.foldedEstimate + PanelSheet.barEstimate
    static let midBase: CGFloat = 470
    /// The screen the bases are drawn for (an iPhone 17 Pro).
    static let referenceScreen: CGFloat = 874
    /// What one stop may take of the screen's height, so a small phone keeps its map (an SE's 667 pt gives 280 and 367).
    static let collapsedShare: CGFloat = 0.42
    static let midShare: CGFloat = 0.55
    /// A larger text size grows collapsed by at most this much (it was Home's cap), so the tall detent stays well above.
    static let collapsedGrowth: CGFloat = 1.5

    /// `scale`: the text-size scale (1 at the default size, never below it).
    static func collapsed(scale: CGFloat, screenHeight: CGFloat = referenceScreen) -> CGFloat {
        min(collapsedBase * min(max(scale, 1), collapsedGrowth), collapsedShare * screenHeight)
    }

    static func mid(scale: CGFloat, screenHeight: CGFloat = referenceScreen) -> CGFloat {
        min(midBase * max(scale, 1), midShare * screenHeight)
    }

    /// The tall stop is the system's full sheet.
    static let tall = PresentationDetent.large

    /// The scale a `@ScaledMetric` value stands for.
    static func scale(of scaled: CGFloat, base: CGFloat) -> CGFloat { max(scaled, 0) / base }

    /// The screen's height, for the caps. One reading for every layer, so they agree.
    @MainActor static var screenHeight: CGFloat { UIScreen.main.bounds.height }
}
