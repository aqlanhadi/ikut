import SwiftUI

/// The sizes and detents of Home's sheet, pure so they can be tested. The sheet is Apple's own
/// (`.sheet` with two detents, always up, the map behind it stays touchable at the short one); the
/// map's `expanded` state is what the detent selection reads and writes.
enum HomeSheet {
    /// Height of the sheet when short: title row, the two pills and the top of past trips.
    static let compactHeight: CGFloat = 300
    /// The short sheet of a picked trip (design/project/HomePicked.dc.html): back, name, date, stats line.
    static let pickedCompactMinimum: CGFloat = 172
    /// Room the drag indicator takes above the content.
    static let indicatorRoom = BottomSheet.indicatorRoom

    /// The short detent's height. A picked trip's follows its header (the text size can wrap it), and
    /// never goes below the design's height.
    static func compact(picked: Bool, pinnedHeight: CGFloat, bottomInset: CGFloat, margin: CGFloat) -> CGFloat {
        guard picked else { return compactHeight }
        return max(pickedCompactMinimum, pinnedHeight + indicatorRoom + bottomInset + margin)
    }

    /// The Apple logo and Legal sit this far above the short sheet, as on the driving map.
    static let legalMargin: CGFloat = 10

    /// The map's bottom safe-area padding: from the screen's bottom edge to just above the short sheet.
    /// MapKit fits regions inside it, so the camera keeps no bottom room of its own (`TripsHomeView.obscured`).
    static func legalInset(compact: CGFloat) -> CGFloat { compact + legalMargin }

    static func short(_ compact: CGFloat) -> PresentationDetent { .height(compact) }
    static let tall = PresentationDetent.large

    static func detents(compact: CGFloat) -> Set<PresentationDetent> { [short(compact), tall] }

    static func detent(expanded: Bool, compact: CGFloat) -> PresentationDetent {
        expanded ? tall : short(compact)
    }

    /// Whatever detent the sheet settles on, tall or not (a dragged sheet reports only its detent).
    static func isExpanded(_ detent: PresentationDetent) -> Bool { BottomSheet.isTall(detent, tall: tall) }

    /// Home's sheet steps aside while anything else is pushed or presented from the root: a pushed screen,
    /// the name or location-denied sheet (wanted, or waiting for the name), or a route being opened.
    static func isCovered(pathCount: Int, showName: Bool, showDenied: Bool, afterName: Bool, opening: Bool) -> Bool {
        pathCount > 0 || showName || showDenied || afterName || opening
    }
}
