import CoreLocation
import FirebaseFirestore
import Foundation
import Observation
import OSLog

/// Live state of the trip this user is in, plus the tracker duty that follows from it.
///
/// Every member listens to the trip, their own member doc and `positions`. Only the car's tracker
/// (while the trip is active) runs the `TrackingService`; it stops the moment that stops being true.
@Observable @MainActor
final class TripSession {
    let tripId: String
    let userId: String

    private(set) var trip: Trip?
    private(set) var member: Member?
    private(set) var car: Car?
    /// The planned stops, in driving order.
    private(set) var stops: [PlannedStop] = []
    /// True while this car's answer on the meeting point is "we'll meet you along the way" (D25 4d-2).
    private(set) var skipsMeetingPoint = false
    /// Latest position per car id.
    private(set) var positions: [String: Position] = [:]
    private(set) var errorMessage: String?
    /// True once the member doc snapshot says this user is not in the trip (any more).
    private(set) var membershipLost = false
    /// True while leaving or ending; tracking is not restarted meanwhile.
    private(set) var isClosing = false
    private(set) var isTracking = false {
        didSet { PlacesRefresher.tripRunning = isTracking }
    }
    /// Organizer only: rebuilds the main route mid-trip (a new destination, a stop skipped for everyone).
    let rebuilder: RouteRebuilder

    /// True while this car's sharing is paused: the tracker paused it here, or the car doc says so
    /// (e.g. after a relaunch) and the pause has not expired.
    var isPaused: Bool { TripSessionLogic.isPaused(pausedAt: pauseStart, now: clock()) }
    var isEnded: Bool { trip?.status == .ended }
    var isOrganizer: Bool { trip?.organizerId == userId && !userId.isEmpty }
    /// The trip is still running and this user is still in it: leaving, pausing and editing make sense (Lobby's canLeave, canEdit and canPause build on it).
    var isLiveMember: Bool { !isEnded && !membershipLost }

    @ObservationIgnored private let tracker: TrackingControlling
    @ObservationIgnored private let injectedDB: Firestore?
    @ObservationIgnored private lazy var db: Firestore = injectedDB ?? Firestore.firestore()
    @ObservationIgnored private let carRouteFactory: CarRouteFactory
    @ObservationIgnored private let ensureTimeout: Duration
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "TripSession")
    @ObservationIgnored private var tripListener: ListenerRegistration?
    @ObservationIgnored private var memberListener: ListenerRegistration?
    @ObservationIgnored private var carListener: ListenerRegistration?
    @ObservationIgnored private var positionsListener: ListenerRegistration?
    @ObservationIgnored private var stopsListener: ListenerRegistration?
    @ObservationIgnored private var answerListener: ListenerRegistration?
    /// The stop and car `answerListener` is on, so it moves only when either does.
    @ObservationIgnored private var listeningAnswer: [String]?
    /// The stop and car whose answer has had its first snapshot (or failed), so a session may be keyed on it.
    @ObservationIgnored private var answerReadFor: [String]?
    /// The last error on the answer listener; the same listener waits `answerRetryDelay` before attaching again.
    @ObservationIgnored private var answerFailure: TripSessionLogic.AnswerFailure?
    @ObservationIgnored private var listeningCarId: String?
    /// The tracking session in progress (same car and main route); nil when not the tracker.
    @ObservationIgnored private var sessionKey: SessionKey?
    /// Bumped whenever a session ends or begins; stale startup and fix tasks compare against it.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var carRoute: CarRouteControlling?
    /// Signature of the own route `TrackingService` was last started with.
    @ObservationIgnored private var trackedCarRoute: [Double]?
    @ObservationIgnored private var explainerShown = false
    /// True from the moment the Always-location sheet is wanted until it's dismissed; the map holds its asks
    /// for as long as it is.
    var alwaysExplainerShowing = false
    /// True while a map ask is on screen; the lobby holds the sheet until it's answered.
    var askShowing = false
    /// True while the driving screen's convoy sheet is up; the lobby's Always sheet waits for it to go (one sheet at a time).
    var mapSheetUp = false
    /// Set the instant this user pauses, before the write lands; cleared on resume or losing tracker duty.
    private var localPausedAt: Date?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let pauseWriter: PauseWriter?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var expiryFor: Date?

    private var pauseStart: Date? { localPausedAt ?? car?.pausedAt }

    private struct SessionKey: Equatable {
        var carId: String
        var tripRoute: String
        /// Latitude and longitude of the meeting point; nil without one.
        var meetingPoint: [Double]?
    }

    init(
        tripId: String, userId: String, tracker: TrackingControlling? = nil, db: Firestore? = nil,
        carRouteFactory: @escaping CarRouteFactory = {
            try TripSessionLogic.makeCarRouteService(tripId: $0, carId: $1, trip: $2, car: $3, meetingPoint: $4)
        },
        ensureTimeout: Duration = .seconds(8),
        clock: @escaping () -> Date = { Date() },
        pauseWriter: PauseWriter? = nil
    ) {
        self.clock = clock
        self.pauseWriter = pauseWriter
        self.tripId = tripId
        self.userId = userId
        self.tracker = tracker ?? TrackingService()
        self.injectedDB = db
        self.carRouteFactory = carRouteFactory
        self.ensureTimeout = ensureTimeout
        self.rebuilder = RouteRebuilder(tripId: tripId) { result, destination in
            try await TripService.rebuildRoute(tripId: tripId, result: result, destination: destination)
        }
        self.tracker.onFix = { [weak self] fix in self?.handle(fix: fix) }
        self.rebuilder.input = { [weak self] in try await self?.rebuildInput() }
    }

    isolated deinit {
        startupTask?.cancel()
        expiryTask?.cancel()
        rebuilder.cancel()
        tracker.onFix = nil
        tracker.stop()
        removeListeners()
        PlacesRefresher.tripRunning = false
    }

    /// Attaches the listeners; calling it again while running does nothing.
    func start() {
        guard tripListener == nil else { return }

        tripListener = db.document(FirestorePaths.trip(tripId)).addSnapshotListener { [weak self] snapshot, error in
            let trip = try? snapshot?.data(as: Trip.self)
            let message = error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                if let trip { self.trip = trip }
                if let message { self.errorMessage = message }
                self.reevaluate()
                if self.isOrganizer, trip?.startedAt != nil { self.rebuilder.resumeIfPending() }
            }
        }

        memberListener = db.document(FirestorePaths.member(tripId: tripId, userId: userId))
            .addSnapshotListener { [weak self] snapshot, error in
                let exists = snapshot?.exists
                let member = try? snapshot?.data(as: Member.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let message { self.errorMessage = message }
                    if let exists { self.applyMember(exists ? member : nil) }
                }
            }

        stopsListener = db.collection(FirestorePaths.stops(tripId: tripId))
            .addSnapshotListener { [weak self] snapshot, error in
                let stops = snapshot?.decoded(PlannedStop.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let stops {
                        self.stops = stops.sorted { $0.order < $1.order }
                        self.reevaluate()
                    }
                    if let message { self.errorMessage = message }
                }
            }

        positionsListener = db.collection(FirestorePaths.positions(tripId: tripId))
            .addSnapshotListener { [weak self] snapshot, error in
                let positions = snapshot?.decoded(Position.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self else { return }
                    if let positions {
                        self.positions = positions.keyedByID()
                    }
                    if let message { self.errorMessage = message }
                }
            }
    }

    /// Stops tracking and detaches every listener.
    func stop() {
        stopTrackingNow()
        rebuilder.cancel()
        removeListeners()
    }

    // MARK: - Leave and end

    /// Stops tracking right away (before any network call), releases tracker duty, then deletes the member doc.
    func leave() async throws {
        stopTrackingNow()
        isClosing = true
        // Offline, the writes stay queued and the phone leaves anyway (ServerWrite).
        do {
            if car?.trackerUserId == userId, let carId = member?.carId ?? car?.id {
                let carRef = db.document(FirestorePaths.car(tripId: tripId, carId: carId))
                try await ServerWrite.commit {
                    try await carRef.updateData(["trackerUserId": FieldValue.delete(), "pausedAt": FieldValue.delete()])
                }
            }
            let memberRef = db.document(FirestorePaths.member(tripId: tripId, userId: userId))
            try await ServerWrite.commit { try await memberRef.delete() }
        } catch {
            isClosing = false
            reevaluate()
            throw error
        }
        stop()
    }

    // MARK: - Pause

    /// Tracker only: stops tracking right away (before any network call), then writes `pausedAt` so the
    /// other members see "Paused" instead of a stale position. If the write fails the pause stays in
    /// effect locally (nothing is shared) and the error is thrown so the caller can offer a retry.
    func pauseSharing() async throws {
        guard !isClosing, !isPaused, let carId = car?.id, car?.trackerUserId == userId, trip?.status == .active else { return }
        let now = clock()
        localPausedAt = now
        stopTrackingNow()
        syncExpiryTimer()
        try await writePausedAt(now, carId: carId)
    }

    /// Clears `pausedAt`, then restarts tracking through the normal `reevaluate` path. If the write fails
    /// the pause stays and the error is thrown.
    func resumeSharing() async throws {
        guard !isClosing, isPaused, let carId = car?.id else { return }
        try await writePausedAt(nil, carId: carId)
        localPausedAt = nil
        car?.pausedAt = nil
        reevaluate()
    }

    private func writePausedAt(_ date: Date?, carId: String) async throws {
        if let pauseWriter {
            try await pauseWriter(carId, date)
            return
        }
        try await db.document(FirestorePaths.car(tripId: tripId, carId: carId))
            .updateData(["pausedAt": date.map { Timestamp(date: $0) } ?? FieldValue.delete()])
    }

    /// One timer for the pause in effect: when it expires tracking resumes by itself and the stale
    /// field is cleared best-effort.
    private func syncExpiryTimer() {
        let start = pauseStart
        guard start != expiryFor else { return }
        expiryTask?.cancel()
        expiryTask = nil
        expiryFor = start
        guard let start else { return }
        // An already-expired pause needs no timer (isPaused is false); scheduling one would re-enter
        // reevaluate() forever while a stale pausedAt stays on the car doc.
        let delay = start.addingTimeInterval(TripSessionLogic.pauseExpiry).timeIntervalSince(clock())
        guard delay > 0 else { return }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.expiryFor == start else { return }
            await self.pauseExpired()
        }
    }

    private func pauseExpired() async {
        let carId = car?.id
        let wasTracker = car?.trackerUserId == userId
        localPausedAt = nil
        expiryFor = nil
        reevaluate()
        if wasTracker, let carId, car?.pausedAt != nil { try? await writePausedAt(nil, carId: carId) }
    }

    /// Organizer only: stops tracking right away, then marks the trip ended.
    func endTrip() async throws {
        guard isOrganizer else { return }
        stopTrackingNow()
        isClosing = true
        do {
            let tripRef = db.document(FirestorePaths.trip(tripId))
            try await ServerWrite.commit {
                try await tripRef.updateData(["status": TripStatus.ended.rawValue, "endedAt": FieldValue.serverTimestamp()])
            }
        } catch {
            isClosing = false
            reevaluate()
            throw error
        }
    }

    /// True the first time it is asked with an action that wants the Always explainer.
    func consumeAlwaysExplainer(action: LocationAction) -> Bool {
        guard TripSessionLogic.shouldPresentAlwaysExplainer(action: action, alreadyShown: explainerShown) else {
            return false
        }
        explainerShown = true
        return true
    }

    /// Test seam: feeds the state the listeners would, without Firestore.
    func applyForTesting(
        trip: Trip?, member: Member?, car: Car?, stops: [PlannedStop] = [], skipsMeetingPoint: Bool = false
    ) {
        self.trip = trip
        self.skipsMeetingPoint = skipsMeetingPoint
        self.stops = stops
        self.member = member
        membershipLost = member == nil
        self.car = car
        reevaluate()
    }

    // MARK: - Private

    /// Stops tracking synchronously and ends the session: no later fix reaches the car-route service.
    private func stopTrackingNow() {
        tracker.stop()
        sessionGeneration += 1
        startupTask?.cancel()
        startupTask = nil
        carRoute = nil
        sessionKey = nil
        trackedCarRoute = nil
        isTracking = false
    }

    private func applyMember(_ member: Member?) {
        self.member = member
        membershipLost = member == nil
        guard let member else {
            carListener?.remove()
            carListener = nil
            listeningCarId = nil
            car = nil
            reevaluate()
            return
        }
        if listeningCarId != member.carId { listenToCar(member.carId) }
        reevaluate()
    }

    private func listenToCar(_ carId: String) {
        carListener?.remove()
        listeningCarId = carId
        car = nil
        carListener = db.document(FirestorePaths.car(tripId: tripId, carId: carId))
            .addSnapshotListener { [weak self] snapshot, error in
                let exists = snapshot?.exists
                let car = try? snapshot?.data(as: Car.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.listeningCarId == carId else { return }
                    if let message { self.errorMessage = message }
                    if let exists {
                        self.car = exists ? car : nil
                        self.reevaluate()
                    }
                }
            }
    }

    /// Starts, restarts (own route changed) or stops tracking to match the current state.
    ///
    /// A restart happens in exactly one place: here, when the car doc's `route` differs from the one
    /// tracking runs with. A reroute by the car-route service lands here through the snapshot of its own write.
    private func reevaluate() {
        guard !isClosing else { return }
        let duty = TripSessionLogic.shouldTrack(
            userId: userId, tripStatus: trip?.status, isMember: member != nil,
            trackerUserId: car?.trackerUserId)
        // Losing tracker duty while paused drops the local pause; the doc's pause is the next tracker's to resume.
        if !duty { localPausedAt = nil }
        syncExpiryTimer()
        listenToOwnAnswer()
        let wants = duty && !isPaused
        guard wants, let trip, let car, let carId = car.id else {
            if tracker.isTracking || sessionKey != nil { stopTrackingNow() }
            isTracking = tracker.isTracking
            return
        }
        let started = trip.startedAt != nil
        if tripListener != nil,
           TripSessionLogic.waitsForAnswer(
               stops: stops, carState: car.state, tripStarted: started, answerRead: answerReadFor == listeningAnswer
                   && listeningAnswer != nil) {
            isTracking = tracker.isTracking
            return
        }
        let running = sessionKey.flatMap { key -> TripSessionLogic.RunningSession? in
            guard key.carId == carId, key.tripRoute == trip.route else { return nil }
            return TripSessionLogic.RunningSession(
                meetingPoint: key.meetingPoint.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) })
        }
        let meetingPoint = TripSessionLogic.sessionMeetingPoint(
            in: stops, skippingAlong: skipsMeetingPoint, carState: car.state, tripStarted: started, running: running)
        let key = SessionKey(
            carId: carId, tripRoute: trip.route, meetingPoint: meetingPoint.map { [$0.latitude, $0.longitude] })
        if key != sessionKey {
            stopTrackingNow()
            beginSession(
                key, trip: trip,
                car: TripSessionLogic.carForNewSession(car, hasMeetingPoint: meetingPoint != nil, tripStarted: trip.startedAt != nil),
                meetingPoint: meetingPoint)
        } else if tracker.isTracking {
            let docRoute = TripSessionLogic.routeLine(from: car.route)
            if TripSessionLogic.signature(of: docRoute) != trackedCarRoute {
                startTracking(carId: carId, carRoute: docRoute)
            }
        }
        isTracking = tracker.isTracking
    }

    private func startTracking(carId: String, carRoute: RouteLine?) {
        trackedCarRoute = TripSessionLogic.signature(of: carRoute)
        tracker.start(
            tripId: tripId, carId: carId,
            mainRoute: TripSessionLogic.routeLine(from: trip?.route) ?? RouteLine([]),
            carRoute: carRoute)
    }

    /// Becoming the tracker: one fix, then `ensureRoute`, then tracking with the own route.
    /// Tracking never waits on the network for long: `ensureRoute` is abandoned after `ensureTimeout`.
    private func beginSession(_ key: SessionKey, trip: Trip, car: Car, meetingPoint: CLLocationCoordinate2D?) {
        sessionKey = key
        sessionGeneration += 1
        let generation = sessionGeneration
        let service: CarRouteControlling?
        do {
            service = try carRouteFactory(tripId, key.carId, trip, car, meetingPoint)
        } catch {
            log.error("car route service unavailable: \(error.localizedDescription, privacy: .public)")
            service = nil
        }
        carRoute = service
        let docRoute = TripSessionLogic.routeLine(from: car.route)
        startupTask = Task { [weak self] in
            await self?.runStartup(generation: generation, carId: key.carId, service: service, docRoute: docRoute)
        }
    }

    private func runStartup(generation: Int, carId: String, service: CarRouteControlling?, docRoute: RouteLine?) async {
        if let service, let fix = await tracker.firstFix() {
            guard generation == sessionGeneration else { return }
            _ = await ensureRoute(service, at: fix.coordinate)
        }
        guard generation == sessionGeneration else { return }
        // On failure the service still holds the route it resumed with (nil: main route only).
        startTracking(carId: carId, carRoute: service.map(\.routeLine) ?? docRoute)
        isTracking = tracker.isTracking
        // No reconcile with the car doc here: it may not yet show the route `ensureRoute` just wrote,
        // and the snapshot of that write restarts tracking if it differs.
    }

    /// True if `ensureRoute` succeeded in time. A late success still reaches us as a car snapshot.
    private func ensureRoute(_ service: CarRouteControlling, at location: CLLocationCoordinate2D) async -> Bool {
        let race = EnsureRace()
        let timeout = ensureTimeout
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let work = Task { @MainActor [log] in
                do {
                    _ = try await service.ensureRoute(at: location)
                    race.finish(true)
                } catch {
                    log.error("ensureRoute failed, tracking the main route: \(error.localizedDescription, privacy: .public)")
                    race.finish(false)
                }
            }
            let timer = Task { @MainActor [log] in
                try? await Task.sleep(for: timeout)
                if race.finish(false) { log.error("ensureRoute timed out, tracking the main route") }
            }
            race.cancelTimer = { timer.cancel() }
            _ = work
        }
    }

    /// Once-only result for `ensureRoute` versus its timeout.
    @MainActor
    private final class EnsureRace {
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelTimer: (() -> Void)?

        @discardableResult
        func finish(_ success: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            cancelTimer?()
            continuation.resume(returning: success)
            return true
        }
    }

    /// What the organizer's phone rebuilds the route from (D25 4d). Nil once there is nothing to rebuild here (not
    /// the organizer, not started, ended); throws while there is no location yet, so the rebuilder tries again.
    private func rebuildInput() async throws -> RouteRebuild.Input? {
        guard isOrganizer, isLiveMember, let trip, trip.startedAt != nil else { return nil }
        let own = member.flatMap { positions[$0.carId] }
        let organizer: CLLocationCoordinate2D
        if let here = try? await RouteBuilder.currentLocation() {
            organizer = here
        } else if let own {
            organizer = own.location.coordinate
        } else {
            throw RouteError.locationUnavailable
        }
        return RouteRebuild.Input(
            route: trip.route, routeSeconds: trip.routeSeconds, stops: stops,
            destination: CLLocationCoordinate2D(
                latitude: trip.destination.coordinate.latitude, longitude: trip.destination.coordinate.longitude),
            destinationName: trip.destination.name, organizer: organizer, organizerOffset: own?.convoyOffset)
    }

    /// Every published fix goes to the car-route service without blocking tracking. A reroute needs no
    /// action here: the write it made comes back as a car snapshot, which restarts tracking.
    private func handle(fix: LocationFix) {
        guard let service = carRoute, tracker.isTracking else { return }
        let generation = sessionGeneration
        Task { [weak self] in
            let event = await service.handle(fix: fix)
            guard let self, generation == self.sessionGeneration else { return }
            if case .failed(let message) = event { self.log.error("car route update failed: \(message, privacy: .public)") }
        }
    }

    /// Listens to this car's answer on the meeting point (the first stop, when it is a meeting point), so a
    /// "we'll meet you along the way" restarts the car's route towards the destination and "we'll stop after all"
    /// sends it back. Only once the listeners run (`start()`); a test feeds `skipsMeetingPoint` itself.
    private func listenToOwnAnswer() {
        guard tripListener != nil else { return }
        let meet = stops.min(by: { $0.order < $1.order }).flatMap { $0.kind == .meet ? $0 : nil }
        let carId = member?.carId ?? car?.id
        guard let stopId = meet?.id, let carId else {
            answerListener?.remove()
            answerListener = nil
            listeningAnswer = nil
            answerReadFor = nil
            skipsMeetingPoint = false
            return
        }
        let target = [stopId, carId]
        guard listeningAnswer != target,
              TripSessionLogic.mayAttachAnswer(target: target, lastFailure: answerFailure, now: clock())
        else { return }
        answerListener?.remove()
        listeningAnswer = target
        if answerReadFor != target { skipsMeetingPoint = false }
        answerListener = db.document(FirestorePaths.answer(tripId: tripId, stopId: stopId, carId: carId))
            .addSnapshotListener { [weak self] snapshot, error in
                guard let snapshot else {
                    // Firestore ends a listener that errors: log it, let the next reevaluate attach a new one, and
                    // don't hold the session back for an answer that can't be read.
                    let reason = error?.localizedDescription ?? "no snapshot"
                    Task { @MainActor in
                        guard let self, self.listeningAnswer == target else { return }
                        self.log.error("meeting point answer listener ended: \(reason, privacy: .public)")
                        self.answerListener = nil
                        self.listeningAnswer = nil
                        self.answerReadFor = target
                        self.answerFailure = TripSessionLogic.AnswerFailure(target: target, at: self.clock())
                        self.reevaluate()
                    }
                    return
                }
                let skipping = (try? snapshot.data(as: StopAnswer.self))?.answer == .skip
                Task { @MainActor in
                    guard let self, self.listeningAnswer == target else { return }
                    let first = self.answerReadFor != target
                    self.answerReadFor = target
                    if first || self.skipsMeetingPoint != skipping {
                        self.skipsMeetingPoint = skipping
                        self.reevaluate()
                    }
                }
            }
    }

    private func removeListeners() {
        tripListener?.remove()
        memberListener?.remove()
        carListener?.remove()
        positionsListener?.remove()
        stopsListener?.remove()
        answerListener?.remove()
        answerListener = nil
        listeningAnswer = nil
        tripListener = nil
        memberListener = nil
        carListener = nil
        positionsListener = nil
        stopsListener = nil
        listeningCarId = nil
    }
}
