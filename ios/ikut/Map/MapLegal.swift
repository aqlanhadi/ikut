import CoreLocation
import SwiftUI

/// Where Apple's logo and Legal link go on the maps (owner 2026-10-25, #343): just above whatever covers the map's
/// bottom at its short or folded height, 10 pt above its top edge. Home and the driving map follow only the short or
/// folded sheet, so a sheet pulled up covers them (as in Apple Maps) and the map never moves with it. The map's bottom
/// safe area reaches up to that top; MapKit keeps its own 10 pt between the logo and the edge of that area. The recap
/// map's step card is measured, and its safe area follows the card once it has stopped moving, not while it is moving.
enum MapLegal {
    /// The reach of a cover whose top was measured: from the screen's bottom edge up to it. The current one for a
    /// reading within a point of it (so a settled cover doesn't touch the map's safe area again), and before the map
    /// or the cover has been measured.
    static func reach(sheetTop: CGFloat, screenHeight: CGFloat, current: CGFloat) -> CGFloat {
        guard screenHeight > 0, sheetTop > 0 else { return current }
        let reach = screenHeight - sheetTop
        return abs(reach - current) > 1 ? reach : current
    }
}
