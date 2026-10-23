import CoreLocation
import FirebaseFirestore

/// Turns raw fixes into `Position` documents. Pure: no CoreLocation manager, no Firestore I/O.
///
/// Offsets:
/// - `routeOffset` is the projection onto the car's own route (`carRoute`), or onto the main route
///   when the car has none.
/// - `convoyOffset` is nil while the car is still joining. The car counts as merged once its own
///   route offset reaches `RouteLine.mergeOffset(of:).otherOffset` (the point along its own route
///   where it joins the main route for good). From then on, sticky, it is the projection onto the
///   main route. If the car's route never joins the main route, `convoyOffset` stays nil.
/// - With no own route, the car is on the main route from the start, so both offsets are the main one.
///
/// Both projections use the previous segment as the hint, which keeps them cheap and stops a route
/// that doubles back from snapping to the wrong leg.
struct PositionBuilder {
    private let main: RouteLine
    private let own: RouteLine?
    /// Offset along `own` at which the car joins the main route; nil if it never does.
    private let ownMergeOffset: Double?
    private var ownHint: Int?
    private var mainHint: Int?
    private(set) var hasMerged: Bool
    private var lastValidHeading: Double = 0

    init(mainRoute: RouteLine, carRoute: RouteLine?) {
        main = mainRoute
        if let carRoute, !carRoute.isEmpty {
            own = carRoute
            // A route that ends at the main route's start is a car's way to the meeting point: it joins on arrival.
            ownMergeOffset = (mainRoute.meetingMerge(of: carRoute) ?? mainRoute.mergeOffset(of: carRoute))?.otherOffset
            hasMerged = false
        } else {
            own = nil
            ownMergeOffset = nil
            hasMerged = true
        }
    }

    mutating func build(from fix: LocationFix, battery: Double?) -> Position {
        let routeOffset: Double
        var convoyOffset: Double?

        if let own {
            let p = own.project(fix.coordinate, hint: ownHint)
            ownHint = p?.segmentIndex
            routeOffset = p?.offset ?? 0
            if !hasMerged, let ownMergeOffset, routeOffset >= ownMergeOffset { hasMerged = true }
            if hasMerged { convoyOffset = projectMain(fix.coordinate) }
        } else {
            let offset = projectMain(fix.coordinate)
            routeOffset = offset
            convoyOffset = offset
        }

        return Position(
            location: GeoPoint(latitude: fix.latitude, longitude: fix.longitude),
            speed: Self.speed(fix.speed),
            heading: heading(fix.course),
            routeOffset: max(0, routeOffset),
            convoyOffset: convoyOffset.map { max(0, $0) },
            battery: battery,
            updatedAt: nil)
    }

    private mutating func projectMain(_ c: CLLocationCoordinate2D) -> Double {
        let p = main.project(c, hint: mainHint)
        mainHint = p?.segmentIndex
        return p?.offset ?? 0
    }

    /// Negative (invalid) speed becomes 0; the rules require `speed >= 0`.
    static func speed(_ raw: Double) -> Double {
        raw.isFinite ? max(0, raw) : 0
    }

    /// A valid course (0..<360, 360 wraps to 0) is remembered; an invalid one reuses the last valid value.
    private mutating func heading(_ course: Double) -> Double {
        if course.isFinite, course >= 0 {
            lastValidHeading = course.truncatingRemainder(dividingBy: 360)
        }
        return lastValidHeading
    }

    /// `UIDevice.batteryLevel` is -1 when unknown.
    static func battery(_ level: Float) -> Double? {
        guard level >= 0, level.isFinite else { return nil }
        return Double(min(level, 1))
    }
}
