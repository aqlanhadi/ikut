import CoreLocation
import Foundation
import UserNotifications

/// A circular region around an upcoming hazard.
struct HazardRegion: Equatable, Sendable, Identifiable {
    /// The event id; also the region identifier.
    var id: String
    var latitude: Double
    var longitude: Double
    var radius: CLLocationDistance
    /// "Debris".
    var label: String
    /// Meters ahead along my route when selected.
    var distanceAhead: Double
    /// When the event expires; an entry after that posts nothing. nil never expires.
    var expiresAt: Date?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Which hazards to register as regions. Pure.
///
/// Candidates are hazards and conditions that are active, not mine, on my route (within 50 m) and
/// ahead of me (offset beyond `myOffset`), minus `exclude` (for example markers already hidden).
/// They are ordered nearest first and capped at `maxRegions` (15; the system allows 20 monitored
/// conditions per app, and this leaves room for others).
enum HazardRegionSelector {
    struct Config: Sendable, Equatable {
        var radius: CLLocationDistance = 500
        var maxRegions = 15
        var lateralTolerance: CLLocationDistance = 50

        static let `default` = Config()
    }

    static func select(
        events: [TripEvent],
        route: RouteLine?,
        myOffset: Double,
        myCarId: String,
        myUserId: String? = nil,
        exclude: Set<String> = [],
        now: Date,
        config: Config = .default
    ) -> [HazardRegion] {
        guard let route else { return [] }
        var found: [HazardRegion] = []
        for event in events where HazardGeometry.isRoadEvent(event) && !HazardGeometry.isExpired(event, now: now) {
            let key = HazardGeometry.key(for: event)
            guard !exclude.contains(key), event.carId != myCarId, myUserId.map({ event.authorId != $0 }) ?? true,
                  let offset = HazardGeometry.offset(of: event, on: route, tolerance: config.lateralTolerance),
                  offset > myOffset
            else { continue }
            found.append(HazardRegion(
                id: key, latitude: event.location.latitude, longitude: event.location.longitude,
                radius: config.radius, label: HazardMarker.presentation(for: event.type).label,
                distanceAhead: offset - myOffset, expiresAt: event.expiresAt))
        }
        found.sort { a, b in
            a.distanceAhead != b.distanceAhead ? a.distanceAhead < b.distanceAhead : a.id < b.id
        }
        return Array(found.prefix(config.maxRegions))
    }

    /// What to add and remove to go from the monitored ids to `desired`. A region that is monitored
    /// and still desired is left alone (no churn); a region whose centre or radius changed is
    /// not expected, since events don't move.
    static func diff(current: [String], desired: [HazardRegion]) -> (add: [HazardRegion], remove: [String]) {
        let have = Set(current)
        let want = Set(desired.map(\.id))
        return (desired.filter { !have.contains($0.id) }, current.filter { !want.contains($0) })
    }
}

/// The region-monitoring backend: `CLMonitor` in production.
@MainActor
protocol RegionMonitoring: AnyObject {
    func add(_ region: HazardRegion) async
    func remove(id: String) async
    /// Identifiers of regions I have entered.
    func entries() -> AsyncStream<String>
}

/// Keeps up to ~15 circular regions registered around upcoming hazards, so the system can wake the
/// app and post "Debris ahead" when distance checks have stopped (app suspended).
///
/// The host calls `update` with my route and offset as fixes arrive; the registered set only
/// changes when the selection does. Each region's entry is handled once.
@MainActor
final class HazardRegionMonitor {
    private let backend: any RegionMonitoring
    private let config: HazardRegionSelector.Config
    private let onEnter: @MainActor (HazardRegion) -> Void
    private(set) var monitored: [HazardRegion] = []
    private var desired: [HazardRegion] = []
    private var applying = false
    private var entered: Set<String> = []
    private var listenTask: Task<Void, Never>?
    private var lastEventIds: Set<String> = []
    private var lastOffset: Double?

    /// How far I travel before the selection is recomputed without an event change.
    static let refreshDistance: Double = 200

    init(
        backend: any RegionMonitoring, config: HazardRegionSelector.Config = .default,
        onEnter: @escaping @MainActor (HazardRegion) -> Void
    ) {
        self.backend = backend
        self.config = config
        self.onEnter = onEnter
    }

    /// Posts a local notification on entry, unless the app is in the foreground (the approach
    /// monitor and `AlertCenter` handle it there).
    convenience init(
        backend: any RegionMonitoring, notifier: any HazardNotifying,
        config: HazardRegionSelector.Config = .default, isForeground: @escaping @MainActor () -> Bool
    ) {
        self.init(backend: backend, config: config) { region in
            guard !isForeground() else { return }
            Task { await notifier.post(region) }
        }
    }

    func start() {
        guard listenTask == nil else { return }
        let stream = backend.entries()
        listenTask = Task { [weak self] in
            for await id in stream {
                guard !Task.isCancelled, let self else { return }
                self.handleEntry(id)
            }
        }
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        desired = []
        lastEventIds = []
        lastOffset = nil
        await apply()
        entered = []
    }

    /// Recomputes the regions and registers or removes the difference. Skips the work when the events
    /// are unchanged and I have moved under `refreshDistance`, unless `force`.
    func update(
        events: [TripEvent], route: RouteLine?, myOffset: Double, myCarId: String, myUserId: String? = nil,
        exclude: Set<String> = [], now: Date = Date(), force: Bool = false
    ) async {
        let ids = Set(events.map(HazardGeometry.key(for:)))
        if !force, ids == lastEventIds, let lastOffset, abs(myOffset - lastOffset) < Self.refreshDistance { return }
        lastEventIds = ids
        lastOffset = myOffset
        desired = HazardRegionSelector.select(
            events: events, route: route, myOffset: myOffset, myCarId: myCarId, myUserId: myUserId,
            exclude: exclude, now: now, config: config)
        await apply()
    }

    private func apply() async {
        guard !applying else { return } // the running loop picks up the newer `desired`
        applying = true
        defer { applying = false }
        while true {
            let plan = HazardRegionSelector.diff(current: monitored.map(\.id), desired: desired)
            if plan.add.isEmpty && plan.remove.isEmpty { return }
            for id in plan.remove {
                await backend.remove(id: id)
                monitored.removeAll { $0.id == id }
            }
            for region in plan.add {
                await backend.add(region)
                monitored.append(region)
            }
        }
    }

    /// The selection is only recomputed after 200 m or an event change, so a registered region can
    /// outlive its event; entering it then is ignored.
    private func handleEntry(_ id: String, now: Date = Date()) {
        guard let region = monitored.first(where: { $0.id == id }), entered.insert(id).inserted else { return }
        if let expiresAt = region.expiresAt, expiresAt <= now { return }
        onEnter(region)
    }

    /// For tests: delivers an entry as the backend would.
    func simulateEntry(_ id: String) { handleEntry(id) }
}

// MARK: Notification

@MainActor
protocol HazardNotifying: AnyObject {
    func post(_ region: HazardRegion) async
}

/// Local notification for a region entry: "Debris ahead".
@MainActor
final class LocalHazardNotifier: HazardNotifying {
    private let center: UNUserNotificationCenter
    private let tripId: String

    init(tripId: String, center: UNUserNotificationCenter = .current()) {
        self.tripId = tripId
        self.center = center
    }

    static func content(for region: HazardRegion, tripId: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(region.label) ahead"
        content.body = "About \(AlertWording.distanceText(region.radius)) ahead on your route."
        content.sound = .default
        content.interruptionLevel = AlertCenter.interruptionLevel
        content.threadIdentifier = AlertCenter.threadIdentifier(tripId: tripId)
        return content
    }

    func post(_ region: HazardRegion) async {
        let request = UNNotificationRequest(
            identifier: "ikut.hazard.region.\(region.id)",
            content: Self.content(for: region, tripId: tripId), trigger: nil)
        try? await center.add(request)
    }
}

// MARK: CLMonitor

/// `CLMonitor`-backed regions. Needs Always location authorization to wake the app. Only one
/// `CLMonitor` with a given name may exist at a time, so create one of these per trip session.
@MainActor
final class CLMonitorRegionMonitor: RegionMonitoring {
    private let name: String
    private var monitor: CLMonitor?
    private var ids: Set<String> = []

    init(name: String = "ikut.hazards") { self.name = name }

    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor(name)
        monitor = created
        return created
    }

    func add(_ region: HazardRegion) async {
        let monitor = await ensureMonitor()
        let condition = CLMonitor.CircularGeographicCondition(center: region.coordinate, radius: region.radius)
        await monitor.add(condition, identifier: region.id, assuming: .unsatisfied)
        ids.insert(region.id)
    }

    func remove(id: String) async {
        let monitor = await ensureMonitor()
        await monitor.remove(id)
        ids.remove(id)
    }

    func entries() -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                let monitor = await self.ensureMonitor()
                do {
                    for try await event in await monitor.events where event.state == .satisfied {
                        continuation.yield(event.identifier)
                    }
                } catch {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
