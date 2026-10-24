import CoreLocation
import Foundation
@testable import ikut

// Shared by the route, convoy and stop suites. The planar maths is fine at the scales the tests use.

/// Where the straight-road tests start: Cyberjaya.
let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)

/// Moves `north`/`east` meters from `c`.
func move(_ c: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
    let r = RouteLine.earthRadius
    return CLLocationCoordinate2D(
        latitude: c.latitude + north / r * 180 / .pi,
        longitude: c.longitude + east / (r * cos(c.latitude * .pi / 180)) * 180 / .pi)
}

/// Points about every `step` meters from `a` to `b`, both included.
func line(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, step: Double = 500) -> [CLLocationCoordinate2D] {
    let count = max(1, Int((RouteLine.haversine(a, b) / step).rounded(.up)))
    return (0...count).map { i in
        let t = Double(i) / Double(count)
        return CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }
}

/// `a` and `b` are within `tol` of each other.
func close(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
