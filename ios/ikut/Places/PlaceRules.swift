import Foundation

/// Every number the side-of-road and Suggest stops logic uses, in one place. They come across unchanged from the
/// spike (`tools/osm/places.mjs`, the tested reference of this port); change one there and here together.
enum PlaceRules {
    // MARK: Which side of the road

    /// How far off the route line a place is still considered (an R&R's far edge is 150 to 400 m from the road).
    static let reach: Double = 600
    /// An outline with corners more than this many meters to each side of the route line spans the road.
    static let span: Double = 15
    /// Within this of the route, a junction is on the route's own road (a dual carriageway is 20 to 60 m across).
    static let onRoad: Double = 120
    /// Bearings this close are the same direction of travel...
    static let sameDirection: Double = 60
    /// ...and this far apart, the other carriageway.
    static let oppositeDirection: Double = 120
    /// The route's bearing at a point is taken over this far either side.
    static let bearingSpan: Double = 50
    /// An entry slip road counts as before the place when it leaves the route at most this far past it.
    static let entrySlack: Double = 200

    // MARK: Suggest stops

    /// A break about every 2 hours of driving.
    static let every: Double = 7_200
    /// A stop within this many seconds of the mark counts.
    static let window: Double = 1_800
    /// None in the last half hour of the trip (you are nearly there).
    static let minFromEnd: Double = 1_800
    /// A trip with no 2 h mark but at least this long gets one stop near halfway (1 h 30).
    static let halfwayFrom: Double = 5_400
    /// Two places within this many seconds of the mark tie, and the one with more for everyone wins.
    static let tie: Double = 300
}
