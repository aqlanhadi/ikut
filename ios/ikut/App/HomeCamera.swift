import CoreLocation
import MapKit
import SwiftUI

/// Home's camera plan (D57), pure so it can be tested. Home never hands its camera to MapKit's follow-the-user
/// (`.userLocation`), which moved it on every location fix (it was a suspect for the UI tests' never-idle stall, Q18;
/// not confirmed, now Q21). Home opens on a fixed region instead (the cached routes, the phone's last known spot, or
/// Kuala Lumpur); the first fix flies to a fixed region around you, and later fixes move it only once you have really
/// moved, and only while it is Home's view of where you are. Every animated move is paced by `CameraPace`.
enum HomeCamera {
    /// Where Home opens before it knows where you are, with no routes to show: Kuala Lumpur.
    static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))

    /// The view around you: about 2 km top to bottom.
    static let hereSpan = 0.02
    /// A fix this far from where the view around you was centred, as a share of its height (about 550 m), is a real
    /// move; anything less leaves the camera still.
    static let recentreShare = 0.25

    /// Where Home opens: every cached route, else the view around where the phone last knew you were, else the
    /// fallback. Always a fixed region.
    static func launch(cachedRoutes: MKCoordinateRegion?, here: CLLocationCoordinate2D? = nil,
                       bottomObscured: Double = 0, topObscured: Double = 0) -> MapCameraPosition {
        if let cachedRoutes { return .region(cachedRoutes) }
        if let here { return .region(around(here, bottomObscured: bottomObscured, topObscured: topObscured)) }
        return .region(fallback)
    }

    /// The view around `here`, centred in the part of the map the sheet and the status bar leave clear.
    static func around(_ here: CLLocationCoordinate2D, bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion {
        PickedTripLogic.focus(on: here, span: hereSpan, bottomObscured: bottomObscured, topObscured: topObscured)
    }

    /// Meters a fix has to move from the last view around you to move the camera again.
    static var recentreMeters: Double { hereSpan * 111_000 * recentreShare }

    /// Whether `fix` is a real move from `anchor` (where the view around you was last centred); the first fix always is.
    static func isRealMove(from anchor: CLLocationCoordinate2D?, to fix: CLLocationCoordinate2D) -> Bool {
        guard let anchor else { return true }
        let meters = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
            .distance(from: CLLocation(latitude: fix.latitude, longitude: fix.longitude))
        return meters > recentreMeters
    }

    /// Whether a location fix may move the camera: only when it shows where you are (the list with no routes drawn, or
    /// Where to? before a place is on the map), and never once the person has moved the map themselves.
    static func followsFixes(mode: HomeSheet.Mode, hasRoutes: Bool, hasPlace: Bool, positionedByUser: Bool) -> Bool {
        guard !positionedByUser, !hasRoutes else { return false }
        switch mode {
        case .list: return true
        case .whereTo: return !hasPlace
        case .newTrip, .leftTrip, .join: return false
        }
    }

    /// Where to?'s camera: the place (or the route) when there is one; with none yet, the view around you when the
    /// camera follows you, else nil: the camera stays on the fixed region it has.
    static func create(place: MKCoordinateRegion?, here: CLLocationCoordinate2D?, follows: Bool,
                       bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        if let place { return place }
        guard follows, let here else { return nil }
        return around(here, bottomObscured: bottomObscured, topObscured: topObscured)
    }

    /// Where Close (Where to?, joining) or Back to trips takes the camera.
    enum Back: Equatable {
        /// The view around you: the list has no routes and the camera showed you (a fix may have come in meanwhile,
        /// so the camera saved before can be the fallback).
        case here
        /// The camera saved before the flow or the pick.
        case saved
    }

    static func back(hasRoutes: Bool, hereKnown: Bool, positionedByUser: Bool) -> Back {
        !hasRoutes && hereKnown && !positionedByUser ? .here : .saved
    }

    /// What a position shows, for pacing: its region, or its camera; nil when it has neither (MapKit's own).
    static func view(of position: MapCameraPosition) -> CameraView? {
        if let region = position.region { return CameraView(region: region) }
        if let camera = position.camera { return CameraView(center: camera.centerCoordinate, distance: camera.distance) }
        return nil
    }

    /// How one move on Home runs.
    enum Step: Equatable {
        /// At once: the first frame, a refit for the measured height, or a position with no view to pace from.
        case place
        /// The shortest glide: too small a change to pace (`CameraPace.isSmallAdjustment`).
        case nudge
        /// Waits for the flight in the air to land, then glides: a small change of where it lands.
        case hold
        /// Paced by `CameraPace`: a near move glides, a far one pulls out, travels and settles.
        case fly
    }

    /// `flyingTo`: where a flight in the air lands (nil when none); `seen`: the camera as last drawn.
    static func step(animated: Bool, flyingTo: CameraView?, seen: CameraView?, to: CameraView?) -> Step {
        guard let to else { return .place }
        guard animated else {
            if let flyingTo, CameraPace.isSmallAdjustment(from: flyingTo, to: to) { return .hold }
            return .place
        }
        switch CameraPace.decide(flyingTo: flyingTo, seen: seen, to: to) {
        case .nudge: return .nudge
        case .hold: return .hold
        case .fly: return .fly
        }
    }
}
