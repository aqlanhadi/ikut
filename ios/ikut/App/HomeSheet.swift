import CoreLocation
import SwiftUI

/// The sizes and detents of Home's sheet, pure so they can be tested. The sheet is Apple's own
/// (`.sheet` with two detents, always up, the map behind it stays touchable at the short one); the
/// map's `expanded` state is what the detent selection reads and writes.
enum HomeSheet {
    /// Height of the sheet when short (at the default text size): the list shows its title row, the two pills and the first
    /// past trips; a picked trip its header (back, name, date, Share, stats line) and the top of its recap card.
    static let compactHeight: CGFloat = 300
    /// Room the drag indicator takes above the content.
    static let indicatorRoom = BottomSheet.indicatorRoom

    /// What every change of Home's content runs on, the camera's flight included, so they start and end together.
    static let motion = Animation.smooth(duration: 0.5)

    /// The short detent's height, the same for the list and a picked trip (so a pick never resizes the sheet).
    /// `scaled` is `compactHeight` scaled with the text size; it is capped so the tall detent stays well above it.
    static func compact(scaled: CGFloat) -> CGFloat {
        min(max(scaled, compactHeight), compactHeight * 1.5)
    }

    static let detentExtra = BottomSheet.detentExtra
    /// From the screen's bottom edge to the top of the list's short sheet.
    static let defaultReach: CGFloat = compactHeight + detentExtra

    /// The map's bottom safe area: from the screen's bottom edge up to the top of the sheet where it rests. MapKit
    /// keeps its own 10 pt between the logo and Legal and the edge of that area, which is Apple's 10 pt above
    /// the sheet (owner, 2026-10-25: on every map, at every height the sheet rests at, the tall one too).
    static func legalInset(reach: CGFloat) -> CGFloat { max(0, reach) }

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
