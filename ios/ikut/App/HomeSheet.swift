import CoreLocation
import SwiftUI

/// The sizes and detents of Home's sheet, pure so they can be tested. The sheet is Apple's own
/// (`.sheet` with two detents, always up, the map behind it stays touchable at the short one); the
/// one sheet's size (`TripSheet`, through `HomeModel.expanded`) is what the detent selection reads and writes.
enum HomeSheet {
    /// Height of the sheet when short (at the default text size): the list shows its title row, the two pills and the first
    /// past trips; a picked trip its header (back, name, date, Share, stats line) and the top of its recap card. It is the
    /// convoy's resting folded sheet (`PanelSheet`'s folded content plus its bar), one number from the same constants, so
    /// Home and the drive rest at the same height (D115; the owner liked the convoy's).
    static let compactHeight: CGFloat = PanelSheet.foldedEstimate + PanelSheet.barEstimate
    /// Room the drag indicator takes above the content.
    static let indicatorRoom = BottomSheet.indicatorRoom

    /// What every change of Home's content runs on. The camera keeps its own pace (`CameraPace`, D57): a far hop takes
    /// longer than the sheet's swap.
    static func motion(reduceMotion: Bool) -> Animation? { Motion.sheet(reduceMotion: reduceMotion) }

    /// The short detent's height, the same for the list and a picked trip (so a pick never resizes the sheet).
    /// `scaled` is `compactHeight` scaled with the text size; it is capped so the tall detent stays well above it.
    static func compact(scaled: CGFloat) -> CGFloat {
        min(max(scaled, compactHeight), compactHeight * 1.5)
    }

    static let detentExtra = BottomSheet.detentExtra
    /// From the screen's bottom edge to the top of the list's short sheet and the gap above it, at the default text size.
    static let defaultReach: CGFloat = reach(.list, compact: compactHeight)

    /// How far up from the screen's bottom edge the camera keeps the short sheet of `mode` and the gap above it
    /// clear: the list's, except a left trip's short sheet (#437). Where to?, New trip and joining keep the list's
    /// (`createInsets`). This used to be the map's bottom padding; the padding is now one constant for every screen
    /// (`LobbySheet.mapPadding`, D109) and the camera reads this relative to it (`obscured`, `createInsets`), so the
    /// tall sheet covers the map on purpose and moves nothing (#343).
    static func reach(_ mode: Mode, compact: CGFloat) -> CGFloat {
        max(0, mode == .leftTrip ? height(.leftTrip, compact: compact) : compact) + detentExtra
    }

    /// What Home's sheet shows: its list, or one of the two steps of making a trip over the same map (MapFirst B2, B3).
    enum Mode: Equatable { case list, whereTo, newTrip, leftTrip, join }

    /// A trip you left early picked on Home: its header and the two-line note, nothing below. Its short detent is this
    /// fraction of the list's (so it scales with the text size, as the list's does).
    static let leftTripFraction: CGFloat = 0.62

    /// Where to? with the keyboard up (B2), and New trip with the route drawn (B3).
    static let whereToHeight: CGFloat = 560
    static let newTripHeight: CGFloat = 420
    /// Joining (D58): one height for every step (code, car, and the name and location steps in front), with the keyboard
    /// up or down, so going on or back never resizes the sheet.
    static let joinHeight: CGFloat = 560

    @MainActor static func mode(flow: NewTripFlow?, leftTripPicked: Bool = false, joining: Bool = false, naming: Bool = false) -> Mode {
        // The name step before Where to? is the join steps' height, so it doesn't resize before Where to? takes over (D112).
        if joining || naming { return .join }
        guard let flow else { return leftTripPicked ? .leftTrip : .list }
        return flow.ready == nil ? .whereTo : .newTrip
    }

    /// What Home's sheet covers of the map for its camera (D63 C4): the short sheet of `mode`. The
    /// tall one covers the map on purpose and moves nothing (#343), so it is not a parameter.
    static func cover(_ mode: Mode, compact: CGFloat) -> MapCover { MapCover(top: 0, bottom: height(mode, compact: compact)) }

    /// The short detent's height for `mode`.
    static func height(_ mode: Mode, compact: CGFloat) -> CGFloat {
        switch mode {
        case .list: compact
        case .whereTo: whereToHeight
        case .newTrip: newTripHeight
        case .join: joinHeight
        case .leftTrip: compact * leftTripFraction
        }
    }

    static func detents(_ mode: Mode, compact: CGFloat) -> Set<PresentationDetent> {
        [short(height(mode, compact: compact)), tall]
    }

    static func detent(expanded: Bool, mode: Mode, compact: CGFloat) -> PresentationDetent {
        expanded ? tall : short(height(mode, compact: compact))
    }

    /// Room kept between the camera's content and the sheet's top edge when making a trip.
    static let createMargin: CGFloat = 24
    /// Status bar plus room for a pin drawn above its coordinate.
    static let createTopRoom: CGFloat = 110

    /// What the camera keeps clear for Where to? and New trip, as fractions of the part of the map the camera frames.
    /// MapKit frames the map above its bottom safe area (`padding`, the one constant `LobbySheet.mapPadding`), so the
    /// fractions are of that part, not of the whole screen. `sheet` is the cover's bottom; the bottom fraction is what it
    /// covers beyond the padding (the list's reach at least, as before), and negative when that is lower than the
    /// padding (the strip then reaches below the frame's edge).
    static func createInsets(mapHeight: CGFloat, sheet: CGFloat, compact: CGFloat, padding: CGFloat) -> (top: Double, bottom: Double) {
        let full = mapHeight > sheet + createTopRoom ? mapHeight : 874
        let area = max(1, full - padding)
        let cleared = max(reach(.list, compact: compact), sheet + createMargin)
        return (Double(createTopRoom / area), Double((cleared - padding) / area))
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
}
