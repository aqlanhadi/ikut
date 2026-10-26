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
    static func motion(reduceMotion: Bool) -> Animation? { Motion.sheet(reduceMotion: reduceMotion) }

    /// The short detent's height, the same for the list and a picked trip (so a pick never resizes the sheet).
    /// `scaled` is `compactHeight` scaled with the text size; it is capped so the tall detent stays well above it.
    static func compact(scaled: CGFloat) -> CGFloat {
        min(max(scaled, compactHeight), compactHeight * 1.5)
    }

    static let detentExtra = BottomSheet.detentExtra
    /// From the screen's bottom edge to the top of the list's short sheet.
    static let defaultReach: CGFloat = legalInset(compact: compactHeight)

    /// The map's bottom safe area: from the screen's bottom edge up to the top of the short sheet, which is its height
    /// plus `detentExtra`. MapKit keeps its own 10 pt between the logo and Legal and the edge of that area, which is
    /// Apple's 10 pt above the sheet. Fixed from the first frame: the tall sheet covers them and the map doesn't move
    /// when the sheet is pulled up or down (owner 2026-10-25, #343).
    static func legalInset(compact: CGFloat) -> CGFloat { max(0, compact) + detentExtra }

    /// What Home's sheet shows: its list, or one of the two steps of making a trip over the same map (MapFirst B2, B3).
    enum Mode: Equatable { case list, whereTo, newTrip }

    /// Where to? with the keyboard up (B2), and New trip with the route drawn (B3).
    static let whereToHeight: CGFloat = 560
    static let newTripHeight: CGFloat = 420

    @MainActor static func mode(flow: NewTripFlow?) -> Mode {
        guard let flow else { return .list }
        return flow.ready == nil ? .whereTo : .newTrip
    }

    /// The short detent's height for `mode`.
    static func height(_ mode: Mode, compact: CGFloat) -> CGFloat {
        switch mode {
        case .list: compact
        case .whereTo: whereToHeight
        case .newTrip: newTripHeight
        }
    }

    static func detents(_ mode: Mode, compact: CGFloat) -> Set<PresentationDetent> {
        [short(height(mode, compact: compact)), tall]
    }

    static func detent(expanded: Bool, mode: Mode, compact: CGFloat) -> PresentationDetent {
        expanded ? tall : short(height(mode, compact: compact))
    }

    /// A sheet pulled up for one step does not stay tall for the next: New trip opens at its own height.
    static func expanded(_ was: Bool, from old: Mode, to new: Mode) -> Bool { old == new ? was : false }

    /// Past routes are drawn only with the list; making a trip shows its own pins and route.
    static func drawsPastRoutes(_ mode: Mode) -> Bool { mode == .list }

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
