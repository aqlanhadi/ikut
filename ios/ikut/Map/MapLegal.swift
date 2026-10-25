import CoreLocation
import SwiftUI

/// Where Apple's logo and Legal link go on every map (owner, 2026-10-25): just above whatever covers the map's bottom
/// (a sheet or a card), 10 pt above its top edge, at each height it rests at. The map's bottom safe area reaches up to
/// that top; MapKit keeps its own 10 pt between the logo and the edge of that area. The map draws edge to edge under
/// the cover, and the safe area follows the cover's top once it has stopped moving, not while it is moving.
enum MapLegal {
    /// The reach of a cover whose top was measured: from the screen's bottom edge up to it. The current one for a
    /// reading within a point of it (so a settled cover doesn't touch the map's safe area again), and before the map
    /// or the cover has been measured.
    static func reach(sheetTop: CGFloat, screenHeight: CGFloat, current: CGFloat) -> CGFloat {
        guard screenHeight > 0, sheetTop > 0 else { return current }
        let reach = screenHeight - sheetTop
        return abs(reach - current) > 1 ? reach : current
    }

    /// Where the camera's centre goes when the map's bottom safe area changes from `oldReach` to `newReach`, so
    /// the picture stays where it is: MapKit puts the camera's centre in the middle of the safe area, so the
    /// middle moves by half the change, and the centre coordinate moves with it (south when the area grows).
    /// `degreesPerPoint` is the map's latitude span over its height. Only for a north-up camera.
    static func recentred(_ center: CLLocationCoordinate2D, degreesPerPoint: Double,
                          oldReach: CGFloat, newReach: CGFloat) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: center.latitude - Double(oldReach - newReach) / 2 * degreesPerPoint,
                               longitude: center.longitude)
    }
}
