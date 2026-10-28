import CoreLocation
import Foundation

/// Where the driving map draws a car, and the follow camera aims, on each new fix, and how long the glide there takes
/// (D70). My car moves on this phone's own fixes (about one a second), every other car on its written positions
/// (about every 5 s). The glide is linear and lasts most of the time between the last two fixes, so the map moves on
/// steadily instead of standing still and stepping; it ends a moment before the next fix is due (`share`), which
/// leaves the app a moment with nothing animating (XCTest waits for one) and is too short to see.
///
/// Never ahead of the car: the aim is the latest fix, carried on along its course only by how old the fix already is
/// (at most one interval, `maxLead`), and the glide reaches it after the car has gone further.
enum FollowGlide {
    struct Fix: Equatable, Sendable {
        var coordinate: MapCoordinate
        /// Degrees clockwise from north; negative when unknown.
        var course: Double = -1
        /// Meters per second; negative when unknown.
        var speed: Double = -1
        var at: Date
    }

    struct Aim: Equatable, Sendable {
        var coordinate: MapCoordinate
        /// Degrees clockwise from north; nil when unknown.
        var heading: Double?
        /// Seconds of linear glide to `coordinate`; 0 places it at once.
        var duration: TimeInterval
    }

    /// Assumed between two fixes with the same time.
    static let firstInterval: TimeInterval = 1
    static let shortest: TimeInterval = 0.25
    /// Past this since the last fix (a tunnel, the app back from the background) the car is placed, not glided.
    static let longest: TimeInterval = 6
    /// The share of the interval the glide takes.
    static let share = 0.9
    /// A step longer than this is a jump (a wrong fix, a car back after a gap); the camera paces it itself.
    static let jumpMeters: CLLocationDistance = 1_000
    /// Under this speed the car is standing: not carried on.
    static let movingSpeed = 1.0
    /// A step shorter than this says nothing about the way the car points.
    static let headingMeters: CLLocationDistance = 5

    /// The aim for `latest` read at `now`, after `previous`. `maxLead` caps how far the fix is carried on, in seconds
    /// (0 for another car's position, timed by the server's clock).
    static func aim(previous: Fix?, latest: Fix, now: Date, maxLead: TimeInterval = .infinity) -> Aim {
        let step = previous.map { RouteLine.haversine($0.coordinate.clCoordinate, latest.coordinate.clCoordinate) }
        let interval = previous.map { latest.at.timeIntervalSince($0.at) }.map { $0 > 0 ? $0 : firstInterval }
        var duration: TimeInterval = 0
        if let interval, let step, interval <= longest, step <= jumpMeters {
            duration = max(interval, shortest) * share
        }
        let moving = latest.speed >= movingSpeed && latest.course >= 0
        let lead = moving ? min(max(now.timeIntervalSince(latest.at), 0), interval ?? firstInterval, maxLead) : 0
        let coordinate = lead > 0 ? carried(latest.coordinate, meters: latest.speed * lead, course: latest.course)
            : latest.coordinate
        var heading: Double?
        if moving {
            heading = latest.course
        } else if let previous, let step, step >= headingMeters {
            heading = PlaceSide.bearing(previous.coordinate.clCoordinate, latest.coordinate.clCoordinate)
        }
        return Aim(coordinate: coordinate, heading: heading, duration: duration)
    }

    /// `coordinate` moved `meters` along `course` (short distances: flat earth).
    static func carried(_ coordinate: MapCoordinate, meters: Double, course: Double) -> MapCoordinate {
        let rad = course * .pi / 180
        let cosLat = max(cos(coordinate.latitude * .pi / 180), 0.01)
        return MapCoordinate(latitude: coordinate.latitude + meters * cos(rad) / 111_195,
                             longitude: coordinate.longitude + meters * sin(rad) / (111_195 * cosLat))
    }
}
