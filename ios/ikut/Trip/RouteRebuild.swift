import CoreLocation
import Foundation
import Observation

/// The main route rebuilt mid-trip (D25 4d): after a new destination, or a stop skipped for everyone.
///
/// The new route keeps the old one, point for point, up to where the organizer is, then goes from that point on
/// the old line through the open stops still ahead to the destination. So every offset behind the organizer (the meeting point,
/// stops passed or left, cars and hazards there) means the same on both lines, and only the stretch ahead moves.
enum RouteRebuild {
    /// What the organizer's phone knows when it rebuilds.
    struct Input: Sendable {
        var route: String
        var routeSeconds: Double?
        var stops: [PlannedStop]
        var destination: CLLocationCoordinate2D
        var destinationName: String
        /// Where the organizer is now.
        var organizer: CLLocationCoordinate2D
        /// The organizer car's last `convoyOffset`; nil while it is joining. Picks the right stretch where the
        /// route passes the same road twice (into a town and back out).
        var organizerOffset: Double?
    }

    struct Result: Sendable, Equatable {
        var route: BuiltRoute
        /// The new `routeOffset` by stop id: the stops ahead that the rules let move (not reached yet).
        var offsets: [String: Double]
        /// The organizer's line: "The route now goes through R&R Tapah and Ipoh".
        var sentence: String
    }

    /// Meters along `line` where the organizer is.
    static func cutOffset(on line: RouteLine, organizer: CLLocationCoordinate2D, organizerOffset: Double?) -> Double? {
        let hint = organizerOffset.flatMap { offset in line.cumulative.lastIndex { $0 <= offset } }
        return line.project(organizer, hint: hint.map { min($0, max(0, line.segmentCount - 1)) })?.offset
    }

    /// The stops the new route goes through, in order: open (not skipped, not left), not the meeting point, and
    /// beyond `cut` on the old route. A stop behind the organizer it did not stop at counts as passed.
    static func ahead(_ stops: [PlannedStop], cut: Double) -> [PlannedStop] {
        stops.filter { $0.isOpen && !$0.isMeeting && $0.routeOffset > cut }.sorted { $0.order < $1.order }
    }

    @MainActor
    static func build(_ input: Input, router: LegRouting) async throws -> Result {
        let old = RouteLine(Polyline.decode(input.route))
        guard old.segmentCount > 0,
              let cut = cutOffset(on: old, organizer: input.organizer, organizerOffset: input.organizerOffset)
        else { throw RouteError.noRoute }
        let prefix = CarRouteLogic.truncate(old, atOffset: cut)
        // The new legs start on the old line where the organizer is nearest, never at the organizer's own fix: the
        // route is shared with every member, also while the organizer's sharing is paused, and it never jumps
        // across country from a side road.
        let start = prefix[prefix.count - 1]
        let via = ahead(input.stops, cut: cut)
        let legs = try await StopRouting.legs(
            from: start, via: via.map { CLLocationCoordinate2D(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }, to: input.destination, router: router)
        let prefixSeconds = old.length > 0 ? (input.routeSeconds ?? 0) * cut / old.length : 0
        let kept = RouteLeg(coordinates: prefix, distance: cut, travelTime: prefixSeconds, name: "")
        let joined = StopRouting.join([kept] + legs)
        // The first junction is where the kept stretch ends; one per stop after it.
        var offsets: [String: Double] = [:]
        for (stop, offset) in zip(via, joined.stopOffsets.dropFirst()) where stop.arrivedAt == nil {
            if let id = stop.id { offsets[id] = offset }
        }
        return Result(
            route: joined.route, offsets: offsets,
            sentence: sentence(through: via.map(\.name) + [input.destinationName]))
    }

    /// "The route now goes through R&R Tapah and Ipoh"; with no stops left, "The route now goes straight to Ipoh".
    static func sentence(through names: [String]) -> String {
        guard names.count > 1 else { return "The route now goes straight to \(names.first ?? "the destination")" }
        return "The route now goes through \(names.dropLast().joined(separator: ", ")) and \(names[names.count - 1])"
    }
}

/// Runs the rebuild on the organizer's phone and keeps at it: a skip for everyone lands even offline, and the
/// rebuild after it waits until Maps answers, trying again after 15 s, 30 s, 1 min, then every 2 min, and after a
/// relaunch (the wish is kept per trip). The organizer reads one line on the map meanwhile, and once it is done.
@Observable @MainActor
final class RouteRebuilder {
    struct Notice: Equatable {
        var text: String
        /// Still waiting for a route; else the route was rebuilt.
        var waiting: Bool
    }

    nonisolated static let waitingLine = "The route will change once you have signal again"
    nonisolated static let noFixLine = "The route will change once your phone finds where you are"
    nonisolated static let noRoadLine = "Maps can't find a road for the new route yet. Trying again soon"

    /// What the organizer reads while the rebuild waits, by what went wrong.
    nonisolated static func waitingLine(for error: Error) -> String {
        let reason = (error as? LegFailure)?.reason ?? (error as? RouteError)
        switch reason {
        case .locationUnavailable: return noFixLine
        case .noRoute: return noRoadLine
        default: return waitingLine
        }
    }
    nonisolated static let retryDelays: [Duration] = [.seconds(15), .seconds(30), .seconds(60), .seconds(120)]
    nonisolated static let noticeTime: Duration = .seconds(8)

    private(set) var notice: Notice?
    private(set) var isPending = false

    /// What the trip looks like now. Nil when there is nothing to rebuild from this phone (not the organizer, the trip
    /// has not started or has ended): the wish is dropped. Throws when it may work later (no fix yet). Set by the session.
    @ObservationIgnored var input: @MainActor () async throws -> RouteRebuild.Input? = { nil }
    @ObservationIgnored private let tripId: String
    @ObservationIgnored private let router: LegRouting
    @ObservationIgnored private let write: @MainActor (RouteRebuild.Result, DestinationResult?) async throws -> Void
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// A new destination is being built and written: the retry loop waits for it, so the two never write at once.
    @ObservationIgnored private var changing = false

    init(
        tripId: String, router: LegRouting = MapKitLegRouter(), defaults: UserDefaults = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        write: @escaping @MainActor (RouteRebuild.Result, DestinationResult?) async throws -> Void
    ) {
        self.tripId = tripId
        self.router = router
        self.defaults = defaults
        self.sleep = sleep
        self.write = write
    }

    private var pendingKey: String { "routeRebuild.pending.\(tripId)" }

    /// After a skip for everyone: rebuild now, and keep trying until it works.
    func request() {
        isPending = true
        defaults.set(true, forKey: pendingKey)
        startLoop()
    }

    private func startLoop() {
        guard task == nil, !changing, isPending else { return }
        task = Task { [weak self] in await self?.retryLoop() }
    }

    /// A rebuild asked for before a relaunch and not done yet.
    func resumeIfPending() {
        guard task == nil, defaults.bool(forKey: pendingKey) else { return }
        request()
    }

    /// The organizer picked a new destination mid-trip: once, now. Throws so the search can say what went wrong.
    /// A retry in flight is stopped and waited for first, so a route built for the old destination never lands after
    /// this one; the new route also carries out any skip still waiting, and if it fails the retries go on.
    func changeDestination(to destination: DestinationResult) async throws {
        changing = true
        defer {
            changing = false
            startLoop()
        }
        if let running = task {
            running.cancel()
            await running.value
        }
        guard var input = try await input() else { throw RouteError.locationUnavailable }
        input.destination = destination.coordinate
        input.destinationName = destination.name
        let result = try await RouteRebuild.build(input, router: router)
        try await write(result, destination)
        finished(result)
    }

    func cancel() {
        task?.cancel()
        task = nil
        noticeTask?.cancel()
    }

    private func retryLoop() async {
        var attempt = 0
        while isPending, !Task.isCancelled {
            do {
                guard let input = try await input() else {
                    dropWish()
                    break
                }
                let result = try await RouteRebuild.build(input, router: router)
                try await write(result, nil)
                finished(result)
            } catch is CancellationError {
                break
            } catch {
                notice = Notice(text: Self.waitingLine(for: error), waiting: true)
                let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
                attempt += 1
                do { try await sleep(delay) } catch { break }
            }
        }
        task = nil
    }

    private func dropWish() {
        isPending = false
        defaults.removeObject(forKey: pendingKey)
        if notice?.waiting == true { notice = nil }
    }

    private func finished(_ result: RouteRebuild.Result) {
        dropWish()
        notice = Notice(text: result.sentence, waiting: false)
        noticeTask?.cancel()
        noticeTask = Task { [weak self, sleep] in
            try? await sleep(Self.noticeTime)
            guard !Task.isCancelled, let self, self.notice?.waiting == false else { return }
            self.notice = nil
        }
    }

    #if DEBUG
    func showForDemo(_ notice: Notice?) { self.notice = notice }
    #endif
}
