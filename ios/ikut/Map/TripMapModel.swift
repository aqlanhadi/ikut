import CoreLocation
import FirebaseFirestore
import Foundation
import Observation

/// Everything the live map shows, derived from the trip session plus a listener on all the trip's
/// cars (the session only tracks my own).
///
/// Feeds `ConvoyModel` (`setMainRoute`, then `update(cars:positions:)`), decodes routes once per
/// change, and exposes marker view-models, route overlays and the camera target. The inputs go in
/// through `apply(...)` and `setCars(_:)`, so previews and tests can drive it without Firestore.
///
/// Lifecycle: call `start()` when the map appears and `stop()` when it goes away; run
/// `convoy.run()` and `runDeviceLocation()` from `.task`.
@Observable @MainActor
final class TripMapModel {
    let convoy: ConvoyModel

    /// Free once the user pans; the map view sets it from the mode control and from gestures.
    var mode: MapMode = .follow

    private(set) var cars: [Car] = []
    private(set) var tripName = ""
    /// "K7M 2QX".
    private(set) var tripCode = ""
    private(set) var mainRoute: RouteLine?
    private(set) var myCarId: String?
    private(set) var myCar: Car?
    /// I am the tracker of my car, so my phone is what reports its position.
    private(set) var isTracker = false
    /// The phone's own fix, while it is being streamed (not the tracker).
    private(set) var device: DeviceFix?
    private(set) var isEnded = false

    @ObservationIgnored private let session: TripSession?
    @ObservationIgnored private let db: Firestore?
    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var positions: [String: Position] = [:]
    @ObservationIgnored private var mainRouteString: String?
    @ObservationIgnored private var allOverlays: [RouteOverlay] = []
    @ObservationIgnored private var overlayKey: [OverlayKey] = []
    @ObservationIgnored private var fallbackPoints: [MapCoordinate] = []
    @ObservationIgnored private var ownRoutes: [String: RouteLine] = [:]

    private struct OverlayKey: Equatable {
        var id: String?
        var route: String?
        var state: CarState
        var main: String?
    }

    /// `session` nil makes a model that is only fed through `apply` (previews, tests).
    init(session: TripSession?, db: Firestore? = nil, convoy: ConvoyModel = ConvoyModel()) {
        self.session = session
        self.db = db
        self.convoy = convoy
    }

    isolated deinit {
        listener?.remove()
    }

    // MARK: Lifecycle

    /// Listens to every car in the trip and pulls the session's current state.
    func start() {
        sync()
        guard listener == nil, let session else { return }
        let db = db ?? Firestore.firestore()
        listener = db.collection(FirestorePaths.cars(tripId: session.tripId))
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let cars = snapshot?.documents.compactMap({ try? $0.data(as: Car.self) }) else { return }
                Task { @MainActor in self?.setCars(cars) }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    /// Reads trip, my car and positions from the session. Call when any of them changes.
    func sync() {
        guard let session else { return }
        apply(
            trip: session.trip, myCar: session.car, myCarId: session.member?.carId ?? session.car?.id,
            positions: session.positions, isTracker: session.isTracking, isEnded: session.isEnded)
    }

    // MARK: Inputs

    func apply(
        trip: Trip?, myCar: Car?, myCarId: String?, positions: [String: Position],
        isTracker: Bool, isEnded: Bool = false
    ) {
        self.myCar = myCar
        self.myCarId = myCarId
        self.isTracker = isTracker
        self.isEnded = isEnded
        self.positions = positions
        if let trip {
            tripName = trip.name
            tripCode = Self.formatCode(trip.code)
            convoy.destinationName = trip.destination.name
            if trip.route != mainRouteString {
                mainRouteString = trip.route
                mainRoute = TripSessionLogic.routeLine(from: trip.route)
                fallbackPoints = [mainRoute?.coordinates.first, mainRoute?.coordinates.last]
                    .compactMap { $0.map(MapCoordinate.init) }
                convoy.setMainRoute(mainRoute)
                recomputeOverlays()
            }
        }
        convoy.update(cars: cars, positions: positions)
    }

    /// New car list from the listener. Overlays are rebuilt only when a route or state changed.
    func setCars(_ cars: [Car]) {
        self.cars = cars
        recomputeOverlays()
        convoy.update(cars: cars, positions: positions)
    }

    private func recomputeOverlays() {
        let key = cars.map { OverlayKey(id: $0.id, route: $0.route, state: $0.state, main: mainRouteString) }
        guard key != overlayKey else { return }
        overlayKey = key
        allOverlays = RouteOverlays.overlays(cars: cars, mainRoute: mainRoute)
        ownRoutes = Dictionary(
            cars.compactMap { car in
                guard let id = car.id, let route = TripSessionLogic.routeLine(from: car.route) else { return nil }
                return (id, route)
            }, uniquingKeysWith: { _, new in new })
    }

    // MARK: Outputs

    var markers: [MapMarker] {
        MapMarkerBuilder.markers(from: convoy.snapshot, myCarId: myCarId)
    }

    var overlays: [RouteOverlay] {
        RouteOverlays.visible(allOverlays, convoyIds: Set(convoy.convoy.map(\.id)))
    }

    var mainRouteCoordinates: [CLLocationCoordinate2D] { mainRoute?.coordinates ?? [] }

    var myCoordinate: MapCoordinate? {
        let carPosition = myCarId.flatMap { positions[$0] }.map {
            MapCoordinate(latitude: $0.location.latitude, longitude: $0.location.longitude)
        }
        return MapCameraLogic.myCoordinate(isTracker: isTracker, carPosition: carPosition, device: device?.coordinate)
    }

    /// What the camera should show right now; nil in free mode.
    var cameraTarget: CameraTarget? {
        let markers = self.markers
        return MapCameraLogic.target(
            mode: mode, me: myCoordinate,
            fresh: markers.filter { !$0.isStale }.map(\.coordinate),
            all: markers.map(\.coordinate), fallback: fallbackPoints)
    }

    var separationWarning: String? { SeparationWarning.text(convoy.snapshot.separatedGaps) }

    // MARK: Report

    /// Nil until the trip knows which car is mine.
    func reportContext(authorId: String) -> ReportContext? {
        guard let tripId = session?.tripId, let carId = myCarId else { return nil }
        return ReportContext(tripId: tripId, carId: carId, authorId: authorId) { [weak self] in
            self?.reportSnapshot()
        }
    }

    func reportSnapshot(now: Date = Date()) -> ReportSnapshot? {
        MapReportSnapshot.make(
            isTracker: isTracker, carPosition: myCarId.flatMap { positions[$0] }, device: device,
            carState: myCar?.state, mainRoute: mainRoute, ownRoute: myCarId.flatMap { ownRoutes[$0] }, now: now)
    }

    // MARK: Device location

    /// Streams the phone's location while the map is visible and I am not the tracker (the tracker
    /// already knows where it is). Does nothing without When In Use or Always permission; the
    /// permission flow elsewhere asks for it. Ends when its task is cancelled.
    func runDeviceLocation() async {
        device = nil
        guard !isTracker else { return }
        switch CLLocationManager().authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return
        }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if Task.isCancelled { break }
                guard let location = update.location, location.horizontalAccuracy >= 0 else { continue }
                device = DeviceFix(coordinate: MapCoordinate(location.coordinate), course: location.course)
            }
        } catch {
            // The stream ended; the map keeps the last fix.
        }
    }

    // MARK: Helpers

    /// "K7M2QX" -> "K7M 2QX".
    static func formatCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
