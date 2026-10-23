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
    /// Hazard markers: events not expired and not yet passed by every car.
    let hazards: HazardModel

    /// Free once the user pans; the map view sets it from the mode control and from gestures.
    var mode: MapMode = .follow

    private(set) var cars: [Car] = []
    private(set) var tripName = ""
    /// When the trip started, for "Left 12:11": the trip's `createdAt`. A trip goes live (and its
    /// cars start sharing) the moment it is created, so this is the convoy's departure time.
    private(set) var departedAt: Date?
    /// "K7M 2QX".
    private(set) var tripCode = ""
    private(set) var mainRoute: RouteLine?
    private(set) var myCarId: String?
    private(set) var myCar: Car?
    /// I am the tracker of my car, so my phone is what reports its position.
    private(set) var isTracker = false
    /// The phone's own fix, while it is being streamed (not the tracker).
    var device: DeviceFix?  // set by the location stream; tests set it directly
    private(set) var isEnded = false
    /// The trip has started (`startedAt`): stops can then be left, and the lead car marks when it arrived.
    var tripStarted = false
    /// The trip's organizer (user id), for naming who can skip a stop for everyone.
    private(set) var organizerId: String?

    @ObservationIgnored private let session: TripSession?
    @ObservationIgnored private let db: Firestore?
    @ObservationIgnored private var listener: ListenerRegistration?
    @ObservationIgnored private var positions: [String: Position] = [:]
    @ObservationIgnored private var mainRouteString: String?
    @ObservationIgnored private var allOverlays: [RouteOverlay] = []
    @ObservationIgnored private var overlayKey: [OverlayKey] = []
    @ObservationIgnored private var fallbackPoints: [MapCoordinate] = []
    @ObservationIgnored private var ownRoutes: [String: RouteLine] = [:]

    // Hazards
    @ObservationIgnored private let eventSource: @Sendable (String) -> AsyncStream<[TripEvent]>
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var events: [TripEvent] = []
    @ObservationIgnored private var alertAnnouncer: (any AlertAnnouncing)?
    @ObservationIgnored private var alertUserId: String?
    @ObservationIgnored private var alertTripId: String?
    @ObservationIgnored private var catchUpWatch = CatchUpHeadsUp()
    @ObservationIgnored private var catchUpAt: Date?
    /// "Aisha’s car is 3.3 km behind you" while its pill is up (D26).
    private(set) var catchUp: TripAlert?
    /// The trip's planned stops, in route order (by `routeOffset`), from the session. Observable, for the
    /// approach pill and the panel's Next stop.
    private(set) var stops: [PlannedStop] = [] { didSet { convoy.setStops(stops) } }
    @ObservationIgnored private var stopWatch = StopApproach()
    @ObservationIgnored private var stopApproachAt: Date?
    /// "R&R Tapah in 2 km" while its pill is up (D25 piece 3a).
    private(set) var stopApproach: TripAlert?
    @ObservationIgnored private var approach: ApproachMonitor?
    @ObservationIgnored private var approachCarId: String?
    /// My joining route (nil once merged), decoded once per change.
    @ObservationIgnored private var myOwnRouteKey: String?
    @ObservationIgnored private var myOwnRoute: RouteLine?
    /// Builds the region monitor when this phone is the tracker; nil (demo, tests) means none.
    @ObservationIgnored var regionMonitorFactory: (@MainActor () -> HazardRegionMonitor)?
    @ObservationIgnored private var regions: HazardRegionMonitor?
    @ObservationIgnored private var hazardsRunning = false

    private struct OverlayKey: Equatable {
        var id: String?
        var route: String?
        var state: CarState
        var main: String?
    }

    /// `session` nil makes a model that is only fed through `apply` (previews, tests).
    init(
        session: TripSession?, db: Firestore? = nil, convoy: ConvoyModel = ConvoyModel(),
        hazards: HazardModel = HazardModel(),
        eventSource: @escaping @Sendable (String) -> AsyncStream<[TripEvent]> = { EventService.listen(tripId: $0) }
    ) {
        self.session = session
        self.db = db
        self.convoy = convoy
        self.hazards = hazards
        self.eventSource = eventSource
    }

    isolated deinit {
        listener?.remove()
        eventsTask?.cancel()
    }

    // MARK: Lifecycle

    /// Listens to every car in the trip and pulls the session's current state.
    func start() {
        sync()
        guard listener == nil, let session else { return }
        listenToEvents(tripId: session.tripId)
        let db = db ?? Firestore.firestore()
        listener = db.collection(FirestorePaths.cars(tripId: session.tripId))
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let cars = snapshot?.decoded(Car.self) else { return }
                Task { @MainActor in self?.setCars(cars) }
            }
    }

    func stop() {
        listener?.remove()
        listener = nil
        stopHazards()
    }

    /// Reads trip, my car and positions from the session. Call when any of them changes.
    func sync() {
        guard let session else { return }
        setStops(session.stops)
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
        convoy.myCarId = myCarId
        self.isTracker = isTracker
        self.isEnded = isEnded
        self.positions = positions
        var routeChanged = false
        if let trip {
            tripStarted = trip.startedAt != nil
            organizerId = trip.organizerId
            tripName = trip.name
            departedAt = trip.startedAt ?? trip.createdAt
            tripCode = Self.formatCode(trip.code)
            convoy.destinationName = trip.destination.name
            if trip.route != mainRouteString {
                mainRouteString = trip.route
                mainRoute = TripSessionLogic.routeLine(from: trip.route)
                fallbackPoints = [mainRoute?.coordinates.first, mainRoute?.coordinates.last]
                    .compactMap { $0.map(MapCoordinate.init) }
                convoy.setMainRoute(mainRoute)
                hazards.setMainRoute(mainRoute)
                routeChanged = true
                recomputeOverlays()
            }
        }
        convoy.update(cars: cars, positions: positions)
        hazards.setPositions(positions)
        feedHazardServices(routeChanged: routeChanged)
        checkCatchUp()
        checkStopApproach()
        checkLeadArrival()
    }

    /// Sets the planned stops without checking (tests, the demo); the next `apply` or `setCars` does.
    func setStops(_ stops: [PlannedStop]) { self.stops = stops.sorted { $0.routeOffset < $1.routeOffset } }

    /// New car list from the listener. Overlays are rebuilt only when a route or state changed.
    func setCars(_ cars: [Car]) {
        self.cars = cars
        recomputeOverlays()
        convoy.update(cars: cars, positions: positions)
        hazards.setCars(cars)
        checkCatchUp()
        checkStopApproach()
        checkLeadArrival()
    }

    // MARK: The lead car at a stop (D25 4a)

    /// Writes a stop's `arrivedAt`; set by the live map. Nil in tests and demos.
    @ObservationIgnored var arrivalWriter: (@Sendable (_ tripId: String, _ stopId: String) async throws -> Void)?
    @ObservationIgnored private var arrivalMarked: Set<String> = []

    /// The lead car's tracker phone writes `arrivedAt` the first time it counts its car at a stop with a planned
    /// length: one server time for every phone to count "Leaving at" from. Once per stop per run; the rules refuse
    /// a second write, so a second phone or a retry is harmless.
    private func checkLeadArrival() {
        guard !isEnded, isTracker, myCar?.isLead == true, let write = arrivalWriter,
              let tripId = alertTripId ?? session?.tripId, let myCarId else { return }
        let offset = convoy.convoy.first { $0.id == myCarId }?.convoyOffset
        guard let stop = StopLeave.stopToMarkArrived(
                  stops: stops, isLeadTracker: true, tripStarted: tripStarted, position: positions[myCarId],
                  offset: offset, now: Date()),
              let stopId = stop.id, arrivalMarked.insert(stopId).inserted else { return }
        Task { try? await write(tripId, stopId) }
    }

    // MARK: A planned stop ahead (D25)

    /// After every convoy update: tells this phone once, about 2 km before a planned stop ahead, and keeps
    /// the pill up until the car is nearly there, the stop is skipped or passed, or 5 minutes go by.
    private func checkStopApproach() {
        if let alert = stopApproach, !stopApproachShowing(alert) { stopApproach = nil }
        // A fix that is not fresh says nothing about where I am now: no pill and no speech from it.
        guard !isEnded, let announcer = alertAnnouncer, let tripId = alertTripId, let myCarId,
              let mine = positions[myCarId], HazardLogic.isFresh(mine, now: Date(), config: .default),
              let due = stopWatch.check(stops: stops, myOffset: myOffsetNow()).first else { return }
        let alert = AlertWording.stopApproach(tripId: tripId, due: due)
        stopApproach = alert
        stopApproachAt = Date()
        announcer.announce(alert: alert)
    }

    private func stopApproachShowing(_ alert: TripAlert) -> Bool {
        guard let at = stopApproachAt, Date().timeIntervalSince(at) < 5 * 60 else { return false }
        return StopApproach.isShowing(stops.first { $0.id == alert.eventId }, distance: stopDistance(alert.eventId))
    }

    /// Meters from my car to a planned stop along the main route, counting down between fixes; negative
    /// once passed, nil while my car is off the convoy.
    func stopDistance(_ stopId: String, now: Date = Date()) -> Double? {
        guard let stop = stops.first(where: { $0.id == stopId }), let mine = myOffsetNow(now: now) else { return nil }
        return stop.routeOffset - mine
    }

    /// Seconds per meter along the main route for my car (`NextStop.pace`): my ETA over what is left of the route,
    /// else my speed; nil while I'm not in the convoy or with neither.
    func stopPace() -> Double? {
        guard let length = mainRoute?.length, length > 0, let mine = convoy.convoy.first(where: { $0.id == myCarId })
        else { return nil }
        return NextStop.pace(
            travelTimeToGo: convoy.driveArrival(forCar: mine.id)?.timeIntervalSinceNow,
            remaining: max(0, length - mine.convoyOffset), speed: mine.speed)
    }

    // MARK: A car parked ahead (D26)

    /// After every convoy update: when my car is parked ahead on the route, tells its phone once,
    /// about 2 minutes before the nearest car behind reaches it, and keeps the pill up until it has.
    private func checkCatchUp() {
        if let alert = catchUp, !catchUpShowing(alert) { catchUp = nil }
        guard !isEnded, let announcer = alertAnnouncer, let tripId = alertTripId, let myCarId,
              let due = catchUpWatch.check(convoy.snapshot, tripId: tripId, myCarId: myCarId)
        else { return }
        let alert = AlertWording.catchUp(tripId: tripId, myCarId: myCarId, due: due)
        catchUp = alert
        catchUpAt = Date()
        announcer.announce(alert: alert)
    }

    /// The pill stays until the car behind is within 150 m of mine or past it, for at most 5 minutes.
    private func catchUpShowing(_ alert: TripAlert) -> Bool {
        guard let at = catchUpAt, Date().timeIntervalSince(at) < 5 * 60,
              let gap = catchUpDistance(alert) else { return false }
        return gap > 150
    }

    /// Meters from the car coming up behind (`alert.eventId`) to mine, carried forward at its speed
    /// between fixes; nil once either car is off the route.
    func catchUpDistance(_ alert: TripAlert, now: Date = Date()) -> Double? {
        guard let ahead = convoy.distance(fromMyCarTo: alert.eventId) else { return nil }
        var gap = -ahead
        if let them = convoy.convoy.first(where: { $0.id == alert.eventId }), let at = them.position.updatedAt,
           !them.isPaused {
            gap -= them.movingSpeed * min(max(now.timeIntervalSince(at), 0), 30)
        }
        return gap
    }

    /// Seconds until the car coming up behind reaches mine at its speed; nil while it is barely moving.
    func catchUpSeconds(_ alert: TripAlert, distance: Double) -> Double? {
        guard let them = convoy.convoy.first(where: { $0.id == alert.eventId }), them.movingSpeed > 1 else { return nil }
        return distance / them.movingSpeed
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
        // Fit keeps the hazards in view too: the one ahead of the convoy is what the driver wants to see.
        let hazardPoints = hazards.markers.map { MapCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
        var focus: MapCoordinate?
        if case .hazard(let id) = mode, let hazard = hazards.markers.first(where: { $0.id == id }) {
            focus = MapCoordinate(latitude: hazard.latitude, longitude: hazard.longitude)
        }
        return MapCameraLogic.target(
            mode: mode, me: myCoordinate,
            fresh: markers.filter { !$0.isStale }.map(\.coordinate) + hazardPoints,
            all: markers.map(\.coordinate) + hazardPoints, fallback: fallbackPoints, focus: focus)
    }

    /// The latest position written for a car, if any.
    func carPosition(_ carId: String) -> Position? { positions[carId] }

    var separationWarning: String? { SeparationWarning.text(convoy.snapshot.driftedGaps) }

    // MARK: Hazards

    /// Starts approach alerts (announced through `announcer`) and, for the tracker, region monitoring.
    /// Call when the map appears; `stop()` ends them.
    /// The same announcer tells a car parked ahead that the convoy is coming (`tripId` defaults to the session's).
    func startHazardAlerts(announcer: any AlertAnnouncing, userId: String, tripId: String? = nil) {
        alertAnnouncer = announcer
        alertUserId = userId
        alertTripId = tripId ?? session?.tripId
        hazardsRunning = true
        feedHazardServices(routeChanged: true)
    }

    /// New events from the listener (or the demo).
    func setEvents(_ events: [TripEvent]) {
        self.events = events
        hazards.setEvents(events)
        approach?.setEvents(events)
        feedHazardServices(routeChanged: false)
    }

    private func listenToEvents(tripId: String) {
        guard eventsTask == nil else { return }
        let stream = eventSource(tripId)
        eventsTask = Task { [weak self] in
            for await events in stream {
                guard !Task.isCancelled, let self else { return }
                self.setEvents(events)
            }
        }
    }

    private func stopHazards() {
        eventsTask?.cancel()
        eventsTask = nil
        hazardsRunning = false
        approach = nil
        approachCarId = nil
        alertAnnouncer = nil
        stopRegions()
    }

    private func stopRegions() {
        guard let regions else { return }
        self.regions = nil
        Task { await regions.stop() }
    }

    /// Pushes my latest fix to the approach monitor and the region monitor. My car is measured on my
    /// own route while joining (no `convoyOffset` yet), else on the main one.
    private func feedHazardServices(routeChanged: Bool, now: Date = Date()) {
        guard hazardsRunning, let carId = myCarId else { return }
        let ownEncoded = myCar?.state == .joining ? myCar?.route : nil
        let ownChanged = ownEncoded != myOwnRouteKey
        if ownChanged {
            myOwnRouteKey = ownEncoded
            myOwnRoute = TripSessionLogic.routeLine(from: ownEncoded)
        }
        if let announcer = alertAnnouncer, approach == nil || approachCarId != carId {
            let monitor = ApproachMonitor(announcer: announcer, myCarId: carId, myUserId: alertUserId)
            monitor.setEvents(events)
            monitor.setMainRoute(mainRoute)
            monitor.setOwnRoute(myOwnRoute)
            approach = monitor
            approachCarId = carId
        } else {
            if routeChanged { approach?.setMainRoute(mainRoute) }
            if ownChanged { approach?.setOwnRoute(myOwnRoute) }
        }
        let wantsRegions = isTracker && !isEnded
        if wantsRegions, regions == nil, let factory = regionMonitorFactory {
            let monitor = factory()
            monitor.start()
            regions = monitor
        } else if !wantsRegions {
            stopRegions()
        }
        // A fix that is not fresh (the tracker paused or lost signal) says nothing about where I am now.
        guard let position = positions[carId], HazardLogic.isFresh(position, now: now, config: .default) else { return }
        approach?.update(position: position, now: now)
        updateRegions(position: position, carId: carId, now: now)
    }

    private func updateRegions(position: Position, carId: String, now: Date) {
        guard let regions else { return }
        let route = position.convoyOffset != nil ? mainRoute : myOwnRoute
        let offset = position.convoyOffset ?? position.routeOffset
        // Hazards already hidden (passed by everyone) don't need a wake-up.
        let shown = Set(hazards.markers.map(\.id))
        let events = events
        let hidden = Set(events.map(HazardGeometry.key(for:))).subtracting(shown)
        let userId = alertUserId
        Task {
            await regions.update(
                events: events, route: route, myOffset: offset, myCarId: carId, myUserId: userId,
                exclude: hidden, now: now)
        }
    }

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
                device = DeviceFix(
                    coordinate: MapCoordinate(location.coordinate), course: location.course, speed: location.speed,
                    at: location.timestamp)
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
