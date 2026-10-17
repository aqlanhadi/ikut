import CoreLocation
import Foundation

/// What `ApproachMonitor` calls to announce an approach. `AlertCenter` conforms.
@MainActor
protocol AlertAnnouncing: AnyObject {
    /// Announces `event` with its distance ahead in meters. Returns whether anything was announced.
    func announce(event: TripEvent, distance: Double?) async -> Bool
}

extension AlertCenter: AlertAnnouncing {}

/// Decides when an approach alert fires. Pure: no clock, no I/O.
///
/// Per event, once, for the life of the value (`reset` clears it):
/// - **Approach alert** when the distance ahead along my route is at most `alertDistance` (500 m).
///   An event first seen already inside 500 m fires at once with its real distance.
/// - **"Now" alert** (optional, `nowDistance`, off by default) at about 100 m; see `ApproachMonitor`.
///
/// Distance is `eventOffset - myOffset` on one route, so a negative distance is behind me and never
/// fires. Hysteresis: a fired stage is remembered per event id and never fires again, so GPS jitter
/// around 500 m (or a re-delivered snapshot) cannot re-trigger it, however far the distance
/// bounces back out. An event first seen behind me fires nothing, and one that is later passed
/// stays quiet.
struct ApproachCore: Sendable {
    struct Config: Sendable, Equatable {
        var alertDistance: CLLocationDistance = 500
        /// A second alert near the hazard. nil turns it off.
        var nowDistance: CLLocationDistance?
        /// An event further than this from my route is on another road or carriageway.
        var lateralTolerance: CLLocationDistance = 50

        static let `default` = Config()
    }

    enum Stage: Int, Sendable { case approach, now }

    struct Candidate: Sendable, Equatable {
        var id: String
        /// Meters along my route.
        var offset: Double
    }

    struct Fire: Sendable, Equatable {
        var id: String
        var stage: Stage
        var distance: Double
    }

    var config: Config
    private var fired: [String: Set<Int>] = [:]

    init(config: Config = .default) { self.config = config }

    mutating func evaluate(candidates: [Candidate], myOffset: Double) -> [Fire] {
        var result: [Fire] = []
        for candidate in candidates {
            let distance = candidate.offset - myOffset
            guard distance > 0 else { continue } // at or behind me
            var done = fired[candidate.id] ?? []
            if let now = config.nowDistance, distance <= now, !done.contains(Stage.now.rawValue) {
                done.insert(Stage.now.rawValue)
                done.insert(Stage.approach.rawValue)
                result.append(Fire(id: candidate.id, stage: .now, distance: distance))
            } else if distance <= config.alertDistance, !done.contains(Stage.approach.rawValue) {
                done.insert(Stage.approach.rawValue)
                result.append(Fire(id: candidate.id, stage: .approach, distance: distance))
            }
            fired[candidate.id] = done
        }
        return result
    }

    mutating func reset() { fired = [:] }
}

/// Watches my car's progress along its route and announces hazards as they come within 500 m.
///
/// Feed it with `setEvents`, `setMainRoute`, `setOwnRoute` and, on every fix, `update(position:)`.
/// While my position has no `convoyOffset` (joining) the distance is measured on my own route with
/// `routeOffset`; once merged it is measured on the main route with `convoyOffset`. Events are
/// projected onto that route and dropped when more than 50 m off it, and events from my own car or
/// user are never announced.
///
/// The "now" alert near 100 m is off by default. `AlertCenter` keys approach alerts as
/// `eventId@approach` and announces each key once, so a second call for the same event is
/// swallowed; it would need a distinct key in `AlertWording`. Turn it on with
/// `ApproachCore.Config(nowDistance: 100)` once that exists.
@MainActor
final class ApproachMonitor {
    private let announcer: any AlertAnnouncing
    private let myCarId: String
    private let myUserId: String?
    private var core: ApproachCore
    private var events: [TripEvent] = []
    private var mainRoute: RouteLine?
    private var ownRoute: RouteLine?
    private var mainOffsets: [String: Double?] = [:]
    private var ownOffsets: [String: Double?] = [:]
    private var tasks: [Task<Void, Never>] = []

    init(
        announcer: any AlertAnnouncing, myCarId: String, myUserId: String? = nil,
        config: ApproachCore.Config = .default
    ) {
        self.announcer = announcer
        self.myCarId = myCarId
        self.myUserId = myUserId
        self.core = ApproachCore(config: config)
    }

    func setEvents(_ events: [TripEvent]) { self.events = events }

    func setMainRoute(_ route: RouteLine?) {
        mainRoute = route
        mainOffsets = [:]
    }

    /// My own joining route; nil once merged or when there is none.
    func setOwnRoute(_ route: RouteLine?) {
        ownRoute = route
        ownOffsets = [:]
    }

    /// Forget what was announced (a new trip).
    func reset() {
        core.reset()
        events = []
        mainOffsets = [:]
        ownOffsets = [:]
    }

    /// Call on every fix of my own car. Returns the events announced by this call.
    @discardableResult
    func update(position: Position, now: Date = Date()) -> [String] {
        let onMain = position.convoyOffset != nil
        let route = onMain ? mainRoute : ownRoute
        guard route != nil else { return [] }
        let myOffset = position.convoyOffset ?? position.routeOffset
        var byId: [String: TripEvent] = [:]
        var candidates: [ApproachCore.Candidate] = []
        for event in events where isCandidate(event, now: now) {
            let key = HazardGeometry.key(for: event)
            guard let offset = offset(of: event, key: key, route: route, onMain: onMain) else { continue }
            byId[key] = event
            candidates.append(.init(id: key, offset: offset))
        }
        let fires = core.evaluate(candidates: candidates, myOffset: myOffset)
        for fire in fires {
            guard let event = byId[fire.id] else { continue }
            let announcer = announcer
            tasks.append(Task { _ = await announcer.announce(event: event, distance: fire.distance) })
        }
        return fires.map(\.id)
    }

    /// Waits for announcements started so far. For tests.
    func waitForAnnouncements() async {
        let pending = tasks
        tasks = []
        for task in pending { await task.value }
    }

    // MARK: Private

    private func isCandidate(_ event: TripEvent, now: Date) -> Bool {
        guard HazardGeometry.isRoadEvent(event), !HazardGeometry.isExpired(event, now: now) else { return false }
        if event.carId == myCarId { return false }
        if let myUserId, event.authorId == myUserId { return false }
        return true
    }

    private func offset(of event: TripEvent, key: String, route: RouteLine?, onMain: Bool) -> Double? {
        let cached = onMain ? mainOffsets[key] : ownOffsets[key]
        if let cached { return cached }
        let value = HazardGeometry.offset(of: event, on: route, tolerance: core.config.lateralTolerance)
        if onMain { mainOffsets[key] = .some(value) } else { ownOffsets[key] = .some(value) }
        return value
    }
}
