import ActivityKit
import FirebaseAuth
import Foundation
import OSLog
import UIKit

/// What the controller needs from ActivityKit, so a test can stand in for it.
@MainActor
protocol ConvoyActivityClient: AnyObject {
    /// There is an activity for this trip that can be updated: active, or stale or pending (ActivityKit marks an
    /// activity stale when its stale date passes; it is still there and takes updates).
    var isRunning: Bool { get }
    /// The person swiped the activity away: it is not started again for this trip in this session (#727).
    var isDismissed: Bool { get }
    /// Live Activities are on for ikut (the person can switch them off in Settings; then nothing shows and nothing is asked).
    var isEnabled: Bool { get }
    func start(tripId: String, state: ConvoyActivityAttributes.ContentState, staleDate: Date?) throws
    func update(_ state: ConvoyActivityAttributes.ContentState, staleDate: Date?)
    /// Ends it. `dismissAfter` nil: at once. Otherwise it stays that long on the Lock Screen with `state` as its last word.
    func end(final state: ConvoyActivityAttributes.ContentState?, dismissAfter: TimeInterval?)
}

/// The Live Activity's life on the car's tracker phone (D3 piece 2a): starts it while a trip's lobby or map is open and
/// this phone is the car's tracker, keeps it current from the convoy data the map reads, and ends it.
///
/// Updates are paced (`Pacing`): a new state at once, other changes at most every 15 s, and one on the 30 s heartbeat
/// even when nothing changed, so a car stuck in a jam does not read Not updating. The stale date comes from the others'
/// data (`ConvoyActivityLogic.staleDate`), not from these sends.
///
/// Seams for piece 2b, none built: the 5 s hazard cadence (`Pacing.minGap` per kind), the OK button, the fresh activity
/// after about 3 hours, alerts through the update (note 10) and "Leave now" per-minute updates.
@MainActor
final class ConvoyActivityController {
    /// What the owner of the open trip says each tick.
    enum Wanted {
        /// The trip has not loaded: nothing to do yet.
        case loading
        /// Not this phone's job, or the trip is gone (left, deleted, no longer the tracker): no activity.
        case no
        case yes(ConvoyActivityInput)
    }

    enum Pacing {
        static let minGap: TimeInterval = 15
        static let heartbeat: TimeInterval = 30
        /// How long Arrived and Trip ended stay on the Lock Screen (note 8).
        static let finalStay: TimeInterval = 15 * 60

        /// Going into Hazard ahead, Stop request or Sharing paused (the last word before tracking stops) goes at once; every other change, a new kind included, waits for
        /// `minGap`, so a state that flips back and forth (the 150 m edge of a stop, a catch-up) cannot send every
        /// tick: at most 4 updates a minute (#721). An unchanged state goes after `heartbeat`.
        static func shouldSend(
            into kind: ConvoyActivityAttributes.Kind, kindChanged: Bool, changed: Bool, sinceLast: TimeInterval
        ) -> Bool {
            if kindChanged, kind == .hazardAhead || kind == .stopRequest || kind == .sharingPaused { return true }
            if kindChanged || changed { return sinceLast >= minGap }
            return sinceLast >= heartbeat
        }
    }

    @ObservationIgnored private let client: ConvoyActivityClient
    private let tripId: String
    private let wanted: () -> Wanted
    private let clock: () -> Date
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "LiveActivity")
    private var last: (state: ConvoyActivityAttributes.ContentState, at: Date)?
    /// Arrived or Trip ended was sent as the last update: nothing more is sent, and leaving the trip leaves it to go by itself.
    private(set) var isFinished = false
    private var ticker: Task<Void, Never>?
    private var startFailureLogged = false

    init(
        tripId: String, client: ConvoyActivityClient, clock: @escaping () -> Date = { Date() },
        wanted: @escaping () -> Wanted
    ) {
        self.tripId = tripId
        self.client = client
        self.clock = clock
        self.wanted = wanted
    }

    /// Checks every 5 s until `leave()`. Cheap: a state that has not changed sends nothing.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                tick()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The trip screen closed: leaving, a deleted trip or signing out end it at once with nothing shown; Arrived and
    /// Trip ended are left to go by themselves after their 15 minutes.
    func leave() {
        ticker?.cancel()
        ticker = nil
        guard !isFinished, client.isRunning else { return }
        client.end(final: nil, dismissAfter: nil)
    }

    func tick() {
        guard !isFinished else { return }
        switch wanted() {
        case .loading:
            return
        case .no:
            if client.isRunning { client.end(final: nil, dismissAfter: nil) }
        case .yes(let input):
            send(input)
        }
    }

    private func send(_ input: ConvoyActivityInput) {
        let (state, stale) = ConvoyActivityLogic.state(input)
        let now = clock()
        if state.kind == .arrived || state.kind == .tripEnded {
            finish(with: state)
            return
        }
        guard client.isRunning else {
            // Switched off in Settings, or swiped away by the person: not started again.
            guard client.isEnabled, !client.isDismissed else { return }
            do {
                try client.start(tripId: tripId, state: state, staleDate: stale)
                last = (state, now)
            } catch {
                if !startFailureLogged {
                    startFailureLogged = true
                    log.notice("could not start the live activity: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }
        let previous = last?.state
        // The date the newest data arrived changes every update; only what the person reads counts as a change.
        var same = state
        same.dataAt = previous?.dataAt
        let changed = previous != same
        guard Pacing.shouldSend(
            into: state.kind, kindChanged: previous?.kind != state.kind, changed: changed,
            sinceLast: last.map { now.timeIntervalSince($0.at) } ?? .infinity) else { return }
        client.update(state, staleDate: stale)
        last = (state, now)
    }

    /// Arrived and Trip ended are the last update: an activity already on the Lock Screen takes it and goes after 15
    /// minutes. None running (swiped away, ended, or an ended trip opened later) starts nothing: a fresh "Arrived" an hour
    /// after the fact would be false.
    private func finish(with state: ConvoyActivityAttributes.ContentState) {
        isFinished = true
        if client.isRunning { client.end(final: state, dismissAfter: Pacing.finalStay) }
    }
}

/// A background task's id, ended once whichever of the work and the expiry comes first.
private final class BackgroundTask: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
    func end() {
        guard id != .invalid else { return }
        let ended = id
        id = .invalid
        Task { @MainActor in UIApplication.shared.endBackgroundTask(ended) }
    }
}

/// ActivityKit's calls are async and not main-actor, so the activity is held where Swift 6 can pass it around.
private final class ActivityBox: @unchecked Sendable {
    let activity: Activity<ConvoyActivityAttributes>
    init(_ activity: Activity<ConvoyActivityAttributes>) { self.activity = activity }

    func update(_ state: ConvoyActivityAttributes.ContentState, staleDate: Date?) async {
        await activity.update(.init(state: state, staleDate: staleDate))
    }

    func end(final state: ConvoyActivityAttributes.ContentState?, dismissAfter: TimeInterval?) async {
        if let state, let dismissAfter {
            await activity.end(
                .init(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(dismissAfter)))
        } else {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

/// ActivityKit's real thing: one activity per trip, found again after a relaunch.
@MainActor
final class ActivityKitClient: ConvoyActivityClient {
    private var box: ActivityBox?
    private let tripId: String

    init(tripId: String) {
        self.tripId = tripId
        // One per trip: a relaunch picks up the one already on the Lock Screen, and ends any other.
        for existing in Activity<ConvoyActivityAttributes>.activities {
            let found = ActivityBox(existing)
            if existing.attributes.tripId == tripId, box == nil {
                box = found
            } else {
                Task { await found.end(final: nil, dismissAfter: nil) }
            }
        }
    }

    /// Only ended and dismissed count as gone: a stale or pending activity is still there and takes updates.
    var isRunning: Bool {
        guard let state = box?.activity.activityState else { return false }
        switch state {
        case .ended, .dismissed: return false
        default: return true
        }
    }

    private static var dismissedTrips: Set<String> = []
    var isDismissed: Bool {
        if box?.activity.activityState == .dismissed { Self.dismissedTrips.insert(tripId) }
        return Self.dismissedTrips.contains(tripId)
    }
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func start(tripId: String, state: ConvoyActivityAttributes.ContentState, staleDate: Date?) throws {
        box = ActivityBox(try Activity.request(
            attributes: ConvoyActivityAttributes(tripId: tripId), content: .init(state: state, staleDate: staleDate)))
    }

    func update(_ state: ConvoyActivityAttributes.ContentState, staleDate: Date?) {
        guard let box else { return }
        Self.keepAwake { await box.update(state, staleDate: staleDate) }
    }

    func end(final state: ConvoyActivityAttributes.ContentState?, dismissAfter: TimeInterval?) {
        guard let current = box else { return }
        box = nil
        Self.keepAwake { await current.end(final: state, dismissAfter: dismissAfter) }
    }

    /// The last word before the phone locks (Trip ended, Sharing paused) must get out even if iOS is about to suspend the
    /// app: the update runs inside a background task.
    private static func keepAwake(_ work: @escaping @Sendable () async -> Void) {
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "liveActivityUpdate") { task.end() }
        Task {
            await work()
            task.end()
        }
    }
}

extension ConvoyActivityController {
    /// The app's: reads the open trip's session and map. Only the car's tracker phone, on a trip it is still in.
    static func live(session: TripSession, map: TripMapModel) -> ConvoyActivityController {
        var loaded = false
        return ConvoyActivityController(tripId: session.tripId, client: ActivityKitClient(tripId: session.tripId)) {
            // A trip seen once and now gone is deleted (or this person was removed): the activity goes at once.
            // Signed out (or into another account): the person's activity goes at once.
            guard Auth.auth().currentUser?.uid == session.userId else { return .no }
            guard session.trip != nil else { return loaded || session.membershipLost ? .no : .loading }
            loaded = true
            guard let car = session.car else { return session.membershipLost ? .no : .loading }
            // Only the car's tracker phone, on a trip it is still in (Arrived and Trip ended still show their last update).
            guard car.trackerUserId == session.userId, !session.userId.isEmpty, session.isLiveMember || session.isEnded
            else { return .no }
            return ConvoyActivityInput.snapshot(session: session, map: map, joinPlace: map.joinPlaceName).map { .yes($0) } ?? .loading
        }
    }
}
