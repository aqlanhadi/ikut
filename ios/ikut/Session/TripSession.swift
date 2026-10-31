import CoreLocation
import FirebaseFirestore
import Foundation
import Observation
import OSLog

/// Live state of the trip this user is in, plus the tracker duty that follows from it.
///
/// The one reader of the trip's data: the lobby and the convoy both read the trip, stops, cars and members from here,
/// so they can't disagree. Every member listens to the trip, their own member doc, the stops and `positions`; the
/// cars and the members only while a screen reads them (`read(_:by:)`, rule #396). Only the car's tracker
/// (while the trip is active) runs the `TrackingService`; it stops the moment that stops being true.
/// The session decides whether this phone has the duty (listeners, pause, leave, end, the meeting-point answer);
/// `TrackingDuty` does the tracking itself (session key, startup, the car's route, the fixes).
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
    /// Every car in the trip, while the lobby or the convoy reads them; the last read stays while nobody does.
    private(set) var cars: [Car] = []
    /// Everyone in the trip, while the lobby reads them (rule #396); the last read stays while it rests.
    private(set) var members: [Member] = []
    private(set) var errorMessage: String?
    /// True once the member doc snapshot says this user is not in the trip (any more).
    private(set) var membershipLost = false
    /// True while leaving or ending; tracking is not restarted meanwhile.
    private(set) var isClosing = false
    /// `stop()` ran (Back to trips, the screen's model closing the trip): tracking stays off until `start()`.
    @ObservationIgnored private var stopped = false
    var isTracking: Bool { duty.isTracking }
    /// Organizer only: rebuilds the main route mid-trip (a new destination, a stop skipped for everyone).
    let rebuilder: RouteRebuilder

    /// True while this car's sharing is paused: the tracker paused it here, or the car doc says so
    /// (e.g. after a relaunch) and the pause has not expired.
    var isPaused: Bool { TripSessionLogic.isPaused(pausedAt: pauseStart, now: clock()) }
    var isEnded: Bool { trip?.status == .ended }
    /// Started (`startedAt`) and not ended: the one answer the lobby and the convoy both read.
    var isStarted: Bool { TripSessionLogic.isStarted(trip) }
    var isOrganizer: Bool { trip?.organizerId == userId && !userId.isEmpty }
    /// The trip is still running and this user is still in it: leaving, pausing and editing make sense (Lobby's canLeave, canEdit and canPause build on it).
    var isLiveMember: Bool { !isEnded && !membershipLost }
    /// The convoy's stopped phase in effect (D122), nil while it is moving: from the trip, over after `ConvoyStop.cap`.
    private(set) var convoyStop: ConvoyStop?
    /// The convoy has stopped (We’ve stopped) and nobody has tapped Continue yet: the one value the tracking layer
    /// reads to save battery while stopped (D124).
    var convoyStopped: Bool { convoyStop != nil }
    /// This phone's own tracker is at rest in a stopped phase and in low power (D124): the one value the screen reads to
    /// let the phone sleep. False for a phone with no tracker, or a car still driving in.
    var trackerAtRest: Bool { duty.isLowPower }
    /// This phone tracks the lead car.
    var isLeadTracker: Bool { !userId.isEmpty && car?.isLead == true && car?.trackerUserId == userId }
    /// May tap Continue (and starts the phase with We’ve stopped): the lead car's tracker or the organizer.
    var mayEndConvoyStop: Bool {
        #if DEBUG
        if let demoLeadsStop { return demoLeadsStop }
        #endif
        return ConvoyStop.mayStartOrEnd(isLeadTracker: isLeadTracker, isOrganizer: isOrganizer)
    }

    @ObservationIgnored private let duty: TrackingDuty
    @ObservationIgnored private let injectedDB: Firestore?
    @ObservationIgnored private lazy var db: Firestore = injectedDB ?? Firestore.firestore()
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "TripSession")
    @ObservationIgnored private var tripListener: ListenerRegistration?
    @ObservationIgnored private var memberListener: ListenerRegistration?
    @ObservationIgnored private var carListener: ListenerRegistration?
    @ObservationIgnored private var positionsListener: ListenerRegistration?
    @ObservationIgnored private var stopsListener: ListenerRegistration?
    @ObservationIgnored private var answerListener: ListenerRegistration?
    @ObservationIgnored private var carsListener: ListenerRegistration?
    @ObservationIgnored private var membersListener: ListenerRegistration?
    /// What each screen reads from the session beyond the trip; the cars and members listeners run for their union.
    @ObservationIgnored private var readers: [TripReader: Set<TripRead>] = [:]
    @ObservationIgnored private var restTask: Task<Void, Never>?
    /// How long a listener nobody reads waits before it rests (a test makes it short).
    @ObservationIgnored private let restDelay: Duration
    /// How many times each shared listener was attached (the hand-over test: one cars listener throughout).
    @ObservationIgnored private(set) var attachCount: [TripRead: Int] = [:]
    /// The stop and car `answerListener` is on, so it moves only when either does.
    @ObservationIgnored private var listeningAnswer: [String]?
    /// The stop and car whose answer has had its first snapshot (or failed), so a session may be keyed on it.
    @ObservationIgnored private var answerReadFor: [String]?
    /// The last error on the answer listener; the same listener waits `answerRetryDelay` before attaching again.
    @ObservationIgnored private var answerFailure: TripSessionLogic.AnswerFailure?
    @ObservationIgnored private var listeningCarId: String?
    @ObservationIgnored private var explainerShown = false
    /// True from the moment the Always-location sheet is wanted until it's dismissed; the map holds its asks
    /// for as long as it is.
    var alwaysExplainerShowing = false
    /// True while a map ask is on screen; the lobby holds the sheet until it's answered.
    var askShowing = false
    /// Set the instant this user pauses, before the write lands; cleared on resume or losing tracker duty.
    private var localPausedAt: Date?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let stopResumer: @MainActor (String) async throws -> Void
    @ObservationIgnored private let pauseWriter: PauseWriter?
    @ObservationIgnored private let leaveWriter: LeaveWriter?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var expiryFor: Date?

    private var pauseStart: Date? { localPausedAt ?? car?.pausedAt }
    /// Ends `convoyStop` when it reaches the cap, so the phase goes without a write.
    @ObservationIgnored private var stopCapTask: Task<Void, Never>?
    /// Where the lead car stood when this phone first saw the phase (in memory only).
    @ObservationIgnored private var moveOff = ConvoyStop.MoveOff()

    #if DEBUG
    /// The paused banner's demo state: sharing paused just now, with nothing behind it.
    func pauseForDemo() { localPausedAt = clock() }
    @ObservationIgnored private var demoLeadsStop: Bool?
    /// The stopped banner's demo state: stopped 12 minutes ago, seen from the lead car (with Continue) or a passenger.
    func stopConvoyForDemo(lead: Bool) {
        demoLeadsStop = lead
        convoyStop = ConvoyStop(since: clock().addingTimeInterval(-12 * 60), by: "u-c1", eventId: "demo-stop")
    }
    #endif

    init(
        tripId: String, userId: String, tracker: TrackingControlling? = nil, db: Firestore? = nil,
        carRouteFactory: @escaping CarRouteFactory = {
            try TripSessionLogic.makeCarRouteService(tripId: $0, carId: $1, trip: $2, car: $3, meetingPoint: $4)
        },
        ensureTimeout: Duration = .seconds(8),
        clock: @escaping () -> Date = { Date() },
        pauseWriter: PauseWriter? = nil,
        leaveWriter: LeaveWriter? = nil,
        restDelay: Duration = .seconds(1),
        stopResumer: @escaping @MainActor (String) async throws -> Void = { _ = try await ConvoyStopService.resume(tripId: $0) }
    ) {
        self.stopResumer = stopResumer
        self.restDelay = restDelay
        self.leaveWriter = leaveWriter
        self.clock = clock
        self.pauseWriter = pauseWriter
        self.tripId = tripId
        self.userId = userId
        self.duty = TrackingDuty(
            tripId: tripId, tracker: tracker ?? TrackingService(), carRouteFactory: carRouteFactory,
            ensureTimeout: ensureTimeout)
        self.injectedDB = db
        self.rebuilder = RouteRebuilder(tripId: tripId) { result, destination in
            try await TripService.rebuildRoute(tripId: tripId, result: result, destination: destination)
        }
        self.duty.mainRoute = { [weak self] in self?.trip?.route }
        self.rebuilder.input = { [weak self] in try await self?.rebuildInput() }
    }

    isolated deinit {
        expiryTask?.cancel()
        stopCapTask?.cancel()
        restTask?.cancel()
        rebuilder.cancel()
        duty.shutDown()
        removeListeners()
        PlacesRefresher.tripRunning = false
    }

    /// Attaches the listeners; calling it again while running does nothing.
    func start() {
        guard tripListener == nil else { return }
        stopped = false
        // No signed-in user: `members/` with an empty id is not a document path, and Firestore traps on it.
        guard !userId.isEmpty else {
            errorMessage = "Add your name to open this trip."
            return
        }

        tripListener = db.document(FirestorePaths.trip(tripId)).addSnapshotListener { [weak self] snapshot, error in
            let trip = try? snapshot?.data(as: Trip.self)
            let message = error?.localizedDescription
            Task { @MainActor in
                // Queued before stop(): a session that has stopped takes nothing more in (no tracking restarts).
                guard let self, self.tripListener != nil else { return }
                if let trip { self.trip = trip }
                if let message { self.errorMessage = message }
                self.reevaluate()
                if self.isOrganizer, TripSessionLogic.isStarted(trip) { self.rebuilder.resumeIfPending() }
            }
        }

        memberListener = db.document(FirestorePaths.member(tripId: tripId, userId: userId))
            .addSnapshotListener { [weak self] snapshot, error in
                let exists = snapshot?.exists
                let member = try? snapshot?.data(as: Member.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.memberListener != nil else { return }
                    if let message { self.errorMessage = message }
                    if let exists { self.applyMember(exists ? member : nil) }
                }
            }

        stopsListener = db.collection(FirestorePaths.stops(tripId: tripId))
            .addSnapshotListener { [weak self] snapshot, error in
                let stops = snapshot?.decoded(PlannedStop.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.stopsListener != nil else { return }
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
                    guard let self, self.positionsListener != nil else { return }
                    if let positions {
                        self.positions = positions.keyedByID()
                        self.syncConvoyStop()
                    }
                    if let message { self.errorMessage = message }
                }
            }
        attachReads()
    }

    // MARK: - Who reads the cars and members

    /// What `reader` reads now. A listener someone starts reading attaches at once; one nobody reads any more rests a
    /// moment later (`restUnread()`), so a hand-over between the lobby and the convoy in one update keeps it running.
    func read(_ wanted: Set<TripRead>, by reader: TripReader) {
        guard readers[reader, default: []] != wanted else { return }
        readers[reader] = wanted
        attachReads()
        restTask?.cancel()
        restTask = Task { [weak self] in
            guard let delay = self?.restDelay else { return }
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.restUnread()
        }
    }

    /// Removes the cars or members listener when no screen reads it; what it last read stays.
    func restUnread() {
        let wanted = TripSessionLogic.reads(readers)
        if !wanted.contains(.cars) {
            carsListener?.remove()
            carsListener = nil
        }
        if !wanted.contains(.members) {
            membersListener?.remove()
            membersListener = nil
        }
    }

    /// The listeners running now, by name (the listener-count test).
    var runningListeners: [String] {
        let all: [(String, ListenerRegistration?)] = [
            ("trip", tripListener), ("member", memberListener), ("car", carListener), ("positions", positionsListener),
            ("stops", stopsListener), ("answer", answerListener), ("cars", carsListener), ("members", membersListener),
        ]
        return all.compactMap { $0.1 == nil ? nil : $0.0 }
    }

    /// Attaches the cars and members listeners someone reads, once the session runs (`start()`).
    private func attachReads() {
        guard tripListener != nil else { return }
        let wanted = TripSessionLogic.reads(readers)
        if wanted.contains(.cars), carsListener == nil {
            attachCount[.cars, default: 0] += 1
            carsListener = db.collection(FirestorePaths.cars(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let cars = snapshot?.decoded(Car.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.carsListener != nil else { return }
                    if let cars { self.cars = cars }
                    if let message { self.errorMessage = message }
                }
            }
        }
        if wanted.contains(.members), membersListener == nil {
            attachCount[.members, default: 0] += 1
            membersListener = db.collection(FirestorePaths.members(tripId: tripId)).addSnapshotListener { [weak self] snapshot, error in
                let members = snapshot?.decoded(Member.self)
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.membersListener != nil else { return }
                    if let members { self.members = members }
                    if let message { self.errorMessage = message }
                }
            }
        }
    }

    /// Stops tracking and detaches every listener. Until `start()` again, nothing that arrives late (a snapshot queued
    /// just before) can start tracking (`reevaluate`).
    func stop() {
        stopped = true
        stopTrackingNow()
        rebuilder.cancel()
        removeListeners()
    }

    // MARK: - Leave and end

    /// Stops tracking right away (before any network call), asks the server whether this phone is the organiser of a
    /// live trip (who cannot leave, D106), then releases tracker duty and deletes the member doc in one batch.
    func leave() async throws {
        stopTrackingNow()
        isClosing = true
        // Offline, the writes stay queued and the phone leaves anyway (ServerWrite). A step the server refuses because
        // this phone is no longer a member has already happened (`leaveCountsAsLeft`); anything else keeps the person
        // in the trip with a plain message.
        do {
            if trip?.status == .active { try await leaveStep(.checkNotOrganizer) }
            let releasing = car?.trackerUserId == userId ? (member?.carId ?? car?.id) : nil
            try await leaveStep(.deleteMember(releasingCar: releasing))
        } catch let still as StillInTrip {
            // Still a member (and, as far as the server says, the organiser): nothing was left, so this phone goes on.
            isClosing = false
            reevaluate()
            throw still
        } catch {
            isClosing = false
            reevaluate()
            throw LeaveFailed()
        }
        stop()
    }

    private func leaveStep(_ step: LeaveStep) async throws {
        do {
            if let leaveWriter { return try await leaveWriter(step) }
            switch step {
            case .checkNotOrganizer:
                do {
                    let snapshot = try await db.document(FirestorePaths.trip(tripId)).getDocument(source: .server)
                    if let live = try? snapshot.data(as: Trip.self), live.status == .active, live.organizerId == userId {
                        throw StillInTrip()
                    }
                } catch let still as StillInTrip {
                    throw still
                } catch {
                    return
                }
            case .deleteMember(let carId):
                // One batch, so a delete the rules refuse takes the release with it. The rules judge each write against
                // the state before the batch: the car update still sees a member.
                nonisolated(unsafe) let batch = db.batch()
                if let carId {
                    batch.updateData(
                        ["trackerUserId": FieldValue.delete(), "pausedAt": FieldValue.delete()],
                        forDocument: db.document(FirestorePaths.car(tripId: tripId, carId: carId)))
                }
                batch.deleteDocument(db.document(FirestorePaths.member(tripId: tripId, userId: userId)))
                // Offline it stays queued and the phone leaves anyway (ServerWrite).
                try await ServerWrite.commit { try await batch.commit() }
            case .confirmGone:
                // A phone that is no longer a member cannot read the doc (permission denied): that, or no doc, is left.
                let memberRef = db.document(FirestorePaths.member(tripId: tripId, userId: userId))
                let listed: Bool
                do { listed = try await memberRef.getDocument(source: .server).exists } catch where TripSessionLogic.leaveCountsAsLeft(error) { return }
                guard listed else { return }
                // Still listed: either the live organiser, whom the rules keep in (D106), or a refusal that was not about
                // that (the rules could not be evaluated for a moment): then one more delete, alone; if that is refused
                // too the person stays with the plain "check your signal" words, never told they are the organiser.
                let live = try? await db.document(FirestorePaths.trip(tripId)).getDocument(source: .server).data(as: Trip.self)
                if let live, live.status == .active, live.organizerId == userId { throw StillInTrip() }
                do { try await ServerWrite.commit { try await memberRef.delete() } } catch where TripSessionLogic.leaveCountsAsLeft(error) {
                    throw LeaveFailed()
                }
            }
        } catch where TripSessionLogic.leaveCountsAsLeft(error) {
            // A refused member delete is a left phone only if the server agrees it is no longer a member: the rules also
            // refuse the live organiser's own delete (D106).
            if case .deleteMember(let release) = step {
                // A batch with the release refused (the trip ended, the tracker already released, the car gone) must not
                // keep an ordinary member in: the delete alone goes next. For the live organiser that is refused too, and
                // the car's tracker was never touched.
                if release != nil { return try await leaveStep(.deleteMember(releasingCar: nil)) }
                try await leaveStep(.confirmGone)
            }
            return
        }
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

    // MARK: - The convoy's stopped phase (D122)

    /// Leave on a planned stop (D25 4a): true when the server took it, false when queued. A stopped phase still on ends
    /// too (D122), on its own write that Leave does not wait for, so a slow or refused Continue never holds up Leave.
    @discardableResult
    func leaveStop(_ stopId: String) async throws -> Bool {
        let sent = try await StopLeaveService.leave(tripId: tripId, stopId: stopId, userId: userId)
        if convoyStopped && mayEndConvoyStop { Task { try? await continueConvoy() } }
        return sent
    }

    /// Continue: ends the stopped phase for everyone (lead car's tracker or organizer; the rules refuse anyone else).
    func continueConvoy() async throws {
        guard trip?.stoppedAt != nil else { return }
        try await stopResumer(tripId)
    }

    /// Follows the trip's stopped phase: the value, its 90-minute end, and on the lead car's phone the 500 m move-off.
    private func syncConvoyStop() {
        #if DEBUG
        if demoLeadsStop != nil { return }
        #endif
        let now = clock()
        let current = ConvoyStop.current(trip, now: now)
        if current != convoyStop {
            convoyStop = current
            duty.setConvoyStopped(current != nil)
            stopCapTask?.cancel()
            if let since = current?.since {
                let delay = ConvoyStop.endsAt(since).timeIntervalSince(now)
                stopCapTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(delay, 0) + 1))
                    guard !Task.isCancelled else { return }
                    self?.syncConvoyStop()
                }
            }
        }
        guard let since = convoyStop?.since, isLeadTracker, isTracking, let carId = car?.id,
              let fix = positions[carId] else {
            moveOff.reset()
            return
        }
        // Only a fresh fix faster than parked speed can end it (#682): one coarse fix while parked never does.
        let moving = HazardLogic.isFresh(fix, now: now, config: .default)
            && fix.speed > ConvoyOrdering.Config.default.parkedSpeed
        if moveOff.check(phase: since, here: fix.location.coordinate, at: fix.updatedAt ?? now, moving: moving) {
            log.info("lead car moved off: the stopped phase ends")
            Task { try? await continueConvoy() }
        }
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
        trip: Trip?, member: Member?, car: Car?, stops: [PlannedStop] = [], skipsMeetingPoint: Bool = false,
        cars: [Car] = [], members: [Member] = [], positions: [String: Position]? = nil
    ) {
        if let positions { self.positions = positions }
        self.cars = cars
        self.members = members
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
    private func stopTrackingNow() { duty.stopNow() }

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
        guard !isClosing, !stopped else { return }
        syncConvoyStop()
        let hasDuty = TripSessionLogic.shouldTrack(
            userId: userId, tripStatus: trip?.status, isMember: member != nil,
            trackerUserId: car?.trackerUserId)
        // Losing tracker duty while paused drops the local pause; the doc's pause is the next tracker's to resume.
        if !hasDuty { localPausedAt = nil }
        syncExpiryTimer()
        listenToOwnAnswer()
        let wants = hasDuty && !isPaused
        guard wants, let trip, let car, let carId = car.id else {
            self.duty.reevaluate(nil)
            return
        }
        let waits = tripListener != nil
            && TripSessionLogic.waitsForAnswer(
                stops: stops, carState: car.state, tripStarted: TripSessionLogic.isStarted(trip),
                answerRead: answerReadFor == listeningAnswer && listeningAnswer != nil)
        self.duty.reevaluate(
            TrackingDuty.Wanted(
                trip: trip, car: car, carId: carId, stops: stops, skipsMeetingPoint: skipsMeetingPoint,
                waitsForAnswer: waits))
    }

    /// What the organizer's phone rebuilds the route from (D25 4d). Nil once there is nothing to rebuild here (not
    /// the organizer, not started, ended); throws while there is no location yet, so the rebuilder tries again.
    private func rebuildInput() async throws -> RouteRebuild.Input? {
        guard isOrganizer, isLiveMember, isStarted, let trip else { return nil }
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
        restTask?.cancel()
        carsListener?.remove()
        membersListener?.remove()
        carsListener = nil
        membersListener = nil
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
