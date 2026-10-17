import CoreLocation
import FirebaseFirestore
import Foundation
import MapKit

// MARK: Seams

/// Computes a driving route between two points. Behind a protocol so tests use synthetic routes.
protocol CarRouteDirections: Sendable {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D]
}

/// Writes the three car fields the rules let the tracker change. Resolves when the server acknowledges.
protocol CarRouteWriting: Sendable {
    func write(_ plan: CarRoutePlan, tripId: String, carId: String) async throws
}

/// MKDirections from an explicit coordinate (`RouteBuilder.buildRoute` only starts at the current location).
struct MapKitCarRouteDirections: CarRouteDirections {
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response: MKDirections.Response
        do {
            response = try await MKDirections(request: request).calculate()
        } catch let error as MKError where error.code == .directionsNotFound {
            throw RouteError.noRoute
        } catch {
            throw RouteError.failed(error.localizedDescription)
        }
        guard let route = response.routes.first else { throw RouteError.noRoute }
        let polyline = route.polyline
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }
}

/// Writes with `updateData`, which has a real async overload that waits for the server.
/// A nil `route` or `mergeOffset` deletes the field.
struct FirestoreCarRouteWriter: CarRouteWriting {
    func write(_ plan: CarRoutePlan, tripId: String, carId: String) async throws {
        let ref = Firestore.firestore().document(FirestorePaths.car(tripId: tripId, carId: carId))
        let fields: [String: Any] = [
            "route": plan.route ?? FieldValue.delete(),
            "mergeOffset": plan.mergeOffset ?? FieldValue.delete(),
            "state": plan.state.rawValue,
        ]
        try await ref.updateData(fields)
    }
}

enum CarRouteError: Error, Equatable {
    /// The trip's main route is empty or undecodable.
    case invalidMainRoute
    /// The computed route had fewer than two points or the main route is empty.
    case unusableRoute
}

/// What `handle(fix:)` did.
enum CarRouteEvent: Sendable, Equatable {
    case none
    /// The car reached its merge point and was marked `.convoy`. The own route is unchanged.
    case merged
    /// A new plan was written. The session must rebuild its `PositionBuilder` from `service.routeLine`.
    case rerouted(CarRoutePlan)
    /// A recompute or write failed; retried after the throttle interval.
    case failed(String)
}

// MARK: Service

/// Owns one car's own route for the tracker's device. No UI.
///
/// Integration (TripSession), only on the device that tracks this car:
/// 1. On becoming tracker, build with the trip's main route, the destination and the car's current
///    doc (`route`, `state`) so a reconnecting tracker resumes, then `try await ensureRoute(at:)` with
///    the first fix. Start `TrackingService` with `mainRoute` and `RouteLine(Polyline.decode(route))`
///    from `routeLine` (nil when none).
/// 2. On every fix call `handle(fix:)`, in a Task so tracking is never blocked on a write or on
///    MKDirections. On `.rerouted`, restart tracking with the new `routeLine`.
/// 3. `handle` is safe to call concurrently; calls during a recompute return `.none`.
@MainActor
final class CarRouteService {
    private let tripId: String
    private let carId: String
    private let main: RouteLine
    private let destination: CLLocationCoordinate2D
    private let directions: CarRouteDirections
    private let writer: CarRouteWriting

    private var detector: OffRouteDetector
    private var busy = false
    private var ownHint: Int?
    private var mainHint: Int?

    /// The car's own route; nil when it is on the main route.
    private(set) var routeLine: RouteLine?
    private(set) var state: CarState
    /// Offset along `routeLine` at which it joins the main route; nil if none or it never does.
    private(set) var ownMergeOffset: Double?
    /// The `mergeOffset` currently stored on the car doc.
    private(set) var mergeOffsetOnMain: Double?

    init(
        tripId: String, carId: String, mainRoute: String, destination: CLLocationCoordinate2D,
        route: String? = nil, state: CarState = .joining,
        directions: CarRouteDirections = MapKitCarRouteDirections(),
        writer: CarRouteWriting = FirestoreCarRouteWriter(),
        detector: OffRouteDetector = OffRouteDetector()
    ) throws {
        let main = RouteLine(Polyline.decode(mainRoute))
        guard !main.isEmpty else { throw CarRouteError.invalidMainRoute }
        self.tripId = tripId
        self.carId = carId
        self.main = main
        self.destination = destination
        self.directions = directions
        self.writer = writer
        self.detector = detector
        self.state = state
        if let route, case let own = RouteLine(Polyline.decode(route)), !own.isEmpty {
            routeLine = own
            ownMergeOffset = main.mergeOffset(of: own, tolerance: CarRouteLogic.mergeTolerance)?.otherOffset
        }
    }

    /// Decides whether the car needs its own route, computes it if so, and writes the result.
    /// Throws on a failed directions request or write; state is unchanged then.
    @discardableResult
    func ensureRoute(at location: CLLocationCoordinate2D) async throws -> CarRoutePlan {
        let plan: CarRoutePlan
        if let onMain = CarRouteLogic.planIfOnMain(location: location, main: main) {
            plan = onMain
        } else {
            let computed = try await directions.route(from: location, to: destination)
            guard let own = CarRouteLogic.makePlan(computed: computed, main: main) else {
                throw CarRouteError.unusableRoute
            }
            plan = own
        }
        try await writer.write(plan, tripId: tripId, carId: carId)
        adopt(plan)
        return plan
    }

    /// Processes one fix: marks the merge, or recomputes when the car has left its route.
    func handle(fix: LocationFix) async -> CarRouteEvent {
        guard !busy else { return .none }
        busy = true
        defer { busy = false }

        // While joining, the car should be on its own route; otherwise on the main route.
        let followingOwn = state == .joining && routeLine != nil
        let distance: CLLocationDistance
        if followingOwn, let own = routeLine {
            let p = own.project(fix.coordinate, hint: ownHint)
            ownHint = p?.segmentIndex
            distance = p?.distance ?? 0
            if let p, let merge = ownMergeOffset, CarRouteLogic.hasMerged(ownOffset: p.offset, ownMergeOffset: merge) {
                return await markMerged()
            }
        } else {
            distance = projectMainDistance(fix.coordinate)
        }
        // Joining with no merge point (the own route never meets the main one): merged once on the main route.
        if state == .joining, ownMergeOffset == nil,
           !CarRouteLogic.needsOwnRoute(distanceFromMain: followingOwn ? projectMainDistance(fix.coordinate) : distance) {
            return await markMerged()
        }

        guard detector.observe(distanceFromRoute: distance, at: fix.timestamp) else { return .none }
        detector.markRecomputed(at: fix.timestamp)
        do {
            return .rerouted(try await ensureRoute(at: fix.coordinate))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: Private

    private func projectMainDistance(_ c: CLLocationCoordinate2D) -> CLLocationDistance {
        let p = main.project(c, hint: mainHint)
        mainHint = p?.segmentIndex
        return p?.distance ?? 0
    }

    private func markMerged() async -> CarRouteEvent {
        let plan = CarRoutePlan(
            route: routeLine.map { Polyline.encode($0.coordinates) }, mergeOffset: mergeOffsetOnMain,
            state: .convoy, kind: .merges)
        do {
            try await writer.write(plan, tripId: tripId, carId: carId)
        } catch {
            return .failed(error.localizedDescription)
        }
        state = .convoy
        detector.resetRun()
        return .merged
    }

    private func adopt(_ plan: CarRoutePlan) {
        state = plan.state
        mergeOffsetOnMain = plan.mergeOffset
        ownHint = nil
        mainHint = nil
        if let route = plan.route {
            let own = RouteLine(Polyline.decode(route))
            routeLine = own
            ownMergeOffset = main.mergeOffset(of: own, tolerance: CarRouteLogic.mergeTolerance)?.otherOffset
        } else {
            routeLine = nil
            ownMergeOffset = nil
        }
        detector.resetRun()
    }
}
