import CoreLocation
import FirebaseFirestore
import Foundation
import Observation

/// A stop as the organizer is editing it in the lobby: the same facts as a `PlannedStop`, plus an id that
/// exists before the stop is saved (it becomes the document id, so a stop keeps its id when moved).
struct StopDraft: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var kind: PlannedStopKind
    var minutes: Int?
    var meetAt: Date?
    /// Meters along the main route; nil until a route has been built through it.
    var routeOffset: Double?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var isMeeting: Bool { kind == .meet }

    init(
        id: String = UUID().uuidString.lowercased(), name: String, coordinate: CLLocationCoordinate2D,
        kind: PlannedStopKind, minutes: Int? = nil, meetAt: Date? = nil, routeOffset: Double? = nil
    ) {
        self.id = id
        self.name = name
        latitude = coordinate.latitude
        longitude = coordinate.longitude
        self.kind = kind
        self.minutes = kind == .meet ? nil : minutes
        self.meetAt = kind == .meet ? meetAt : nil
        self.routeOffset = routeOffset
    }

    init(_ stop: PlannedStop) {
        self.init(
            id: stop.id ?? UUID().uuidString.lowercased(), name: stop.name,
            coordinate: .init(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude),
            kind: stop.kind, minutes: stop.minutes, meetAt: stop.meetAt, routeOffset: stop.routeOffset)
    }

    func planned(order: Int) -> PlannedStop {
        PlannedStop(
            id: id, name: name, coordinate: GeoPoint(latitude: latitude, longitude: longitude),
            routeOffset: routeOffset ?? 0, kind: kind, minutes: minutes, meetAt: meetAt, note: nil, order: order)
    }
}

/// What a rebuild hands to the save: the route through the stops and the stops with their offsets.
struct StopPlanSave: Sendable {
    var route: BuiltRoute
    var stops: [PlannedStop]
    var removedIds: [String]
}

/// The pure rules for editing the list of stops.
enum StopListLogic {
    /// Where a new stop with this offset goes: after every stop that is not further along the route, so
    /// the list stays in driving order. A meeting point goes first.
    static func insertIndex(of draft: StopDraft, among items: [StopDraft]) -> Int {
        if draft.isMeeting { return 0 }
        let firstFree = items.first?.isMeeting == true ? 1 : 0
        guard let offset = draft.routeOffset else { return items.count }
        var index = firstFree
        for item in items.dropFirst(firstFree) {
            guard let other = item.routeOffset, other <= offset else { break }
            index += 1
        }
        return index
    }

    /// The list after a drag, or nil when the move isn't allowed: a meeting point stays first and nothing
    /// goes above it.
    static func moved(_ items: [StopDraft], from: IndexSet, to: Int) -> [StopDraft]? {
        var result = items
        result.move(fromOffsets: from, toOffset: to)
        guard result.map(\.id) != items.map(\.id) else { return nil }
        if let meet = result.firstIndex(where: \.isMeeting), meet != 0 { return nil }
        return result
    }

    /// The Meet choice is offered only for what would be the first stop.
    static func canMeet(among items: [StopDraft]) -> Bool { items.isEmpty }

    static func canAdd(among items: [StopDraft]) -> Bool { items.count < PlannedStop.maxCount }

    /// Total planned stop time in minutes.
    static func plannedMinutes(_ items: [StopDraft]) -> Int { items.compactMap(\.minutes).reduce(0, +) }
}

/// Edits the trip's stops in the lobby and keeps the route through them: each change rebuilds the route, leg
/// by leg, and saves the stops and the route together. A rebuild that fails is not saved: the list stays
/// as the organizer left it, the stop (or the destination) that has no road is flagged, and everyone else
/// keeps seeing the last saved plan until Try again works.
@Observable @MainActor
final class StopPlanner {
    enum Status: Equatable {
        case saved
        case building
        case failed(Failure)
    }

    struct Failure: Equatable {
        enum Place: Equatable {
            case stop(String)
            case destination
            /// Nobody knows where the route starts: no meeting point and no fix on the organizer.
            case start
            case saving
        }
        var place: Place
        var reason: RouteError
    }

    private(set) var items: [StopDraft] = []
    private(set) var status: Status = .saved
    /// Extra meters a stop's road turns back on itself, by stop id; only stops with a turn-back are in it.
    private(set) var turnBacks: [String: Double] = [:]

    /// What the trip doc says now.
    private var route = ""
    private var destination: CLLocationCoordinate2D?
    private var savedIds: [String] = []
    private var rebuildTask: Task<Void, Never>?

    private let router: LegRouting
    /// Where the organizer is now; nil without a fix.
    private let origin: @MainActor () async -> CLLocationCoordinate2D?
    private let cache = LegCache()
    private let save: @MainActor (StopPlanSave) async throws -> Void
    private let delay: Duration

    init(
        router: LegRouting = MapKitLegRouter(), delay: Duration = .milliseconds(350),
        origin: @escaping @MainActor () async -> CLLocationCoordinate2D? = { try? await RouteBuilder.currentLocation() },
        save: @escaping @MainActor (StopPlanSave) async throws -> Void
    ) {
        self.router = router
        self.origin = origin
        self.delay = delay
        self.save = save
    }

    var isBuilding: Bool { status == .building }
    var hasStops: Bool { !items.isEmpty }

    /// Follows the trip and its stops as Firestore reports them, unless an edit is being built or has failed.
    func sync(trip: Trip?, stops: [PlannedStop]) {
        guard let trip else { return }
        destination = CLLocationCoordinate2D(
            latitude: trip.destination.coordinate.latitude, longitude: trip.destination.coordinate.longitude)
        route = trip.route
        savedIds = stops.compactMap(\.id)
        guard status == .saved else { return }
        items = stops.sorted { $0.order < $1.order }.map(StopDraft.init)
        turnBacks = Self.turnBacks(route: trip.route, items: items)
    }

    // MARK: Edits

    func add(_ draft: StopDraft) {
        guard StopListLogic.canAdd(among: items) else { return }
        if draft.isMeeting && !StopListLogic.canMeet(among: items) { return }
        var draft = draft
        // Where it falls on the route as it is now; the rebuild gives the real offset.
        draft.routeOffset = draft.routeOffset ?? projectedOffset(of: draft.coordinate)
        items.insert(draft, at: StopListLogic.insertIndex(of: draft, among: items))
        rebuild()
    }

    func move(from: IndexSet, to: Int) {
        guard let moved = StopListLogic.moved(items, from: from, to: to) else { return }
        items = moved
        rebuild()
    }

    func remove(id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        rebuild()
    }

    func retry() {
        guard case .failed = status else { return }
        rebuild(immediately: true)
    }

    // MARK: Rebuild

    private func rebuild(immediately: Bool = false) {
        rebuildTask?.cancel()
        status = .building
        let snapshot = items
        let wait = immediately ? Duration.zero : delay
        rebuildTask = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled else { return }
            await self?.run(snapshot)
        }
    }

    private func run(_ edited: [StopDraft]) async {
        guard let destination else { return }
        do {
            let built = try await Self.build(
                items: edited, destination: destination, origin: origin,
                fallbackStart: Polyline.decode(route).first, router: router, cache: cache)
            try Task.checkCancellation()
            let removed = savedIds.filter { id in !edited.contains { $0.id == id } }
            do {
                try await save(StopPlanSave(
                    route: built.route, stops: built.items.enumerated().map { $1.planned(order: $0) },
                    removedIds: removed))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                items = built.items
                status = .failed(Failure(place: .saving, reason: .failed(error.localizedDescription)))
                return
            }
            guard !Task.isCancelled else { return }
            items = built.items
            route = built.route.polyline
            savedIds = built.items.map(\.id)
            turnBacks = Self.turnBacks(route: built.route.polyline, items: built.items)
            status = .saved
        } catch is CancellationError {
            return
        } catch let failure as LegFailure {
            guard !Task.isCancelled else { return }
            let via = edited.filter { !$0.isMeeting }
            let place: Failure.Place = failure.index < via.count ? .stop(via[failure.index].id) : .destination
            status = .failed(Failure(place: place, reason: failure.reason))
        } catch let error as RouteError {
            guard !Task.isCancelled else { return }
            status = .failed(Failure(place: .start, reason: error))
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(Failure(place: .destination, reason: .failed(error.localizedDescription)))
        }
    }

    /// The route through `items`, and the items with their offsets. A meeting point is the route's start.
    static func build(
        items: [StopDraft], destination: CLLocationCoordinate2D,
        origin: @MainActor () async -> CLLocationCoordinate2D? = { try? await RouteBuilder.currentLocation() },
        fallbackStart: CLLocationCoordinate2D?, router: LegRouting = MapKitLegRouter(), cache: LegCache? = nil
    ) async throws -> (route: BuiltRoute, items: [StopDraft]) {
        let meet = items.first(where: \.isMeeting)
        let via = items.filter { !$0.isMeeting }
        // The meeting point when there is one; else where the organizer is now, or without a fix where
        // the route started before.
        var start = meet?.coordinate
        if start == nil { start = await origin() }
        if start == nil { start = fallbackStart }
        guard let start else { throw RouteError.locationUnavailable }
        let built = try await StopRouting.build(
            from: start, via: via.map(\.coordinate), to: destination, router: router, cache: cache)
        var offsets = built.stopOffsets.makeIterator()
        let placed = items.map { item -> StopDraft in
            var item = item
            item.routeOffset = item.isMeeting ? 0 : offsets.next()
            return item
        }
        return (built.route, placed)
    }

    // MARK: Reading the route

    private func projectedOffset(of coordinate: CLLocationCoordinate2D) -> Double? {
        let line = RouteLine(Polyline.decode(route))
        return line.project(coordinate)?.offset
    }

    /// Stops whose road turns back, with the extra meters.
    static func turnBacks(route: String, items: [StopDraft]) -> [String: Double] {
        let line = RouteLine(Polyline.decode(route))
        guard line.segmentCount > 0 else { return [:] }
        var result: [String: Double] = [:]
        for item in items where !item.isMeeting {
            guard let offset = item.routeOffset,
                  let extra = StopRouting.uTurnExtra(on: line, stopOffset: offset)
            else { continue }
            result[item.id] = extra
        }
        return result
    }

    #if DEBUG
    /// The planner as the lobby shows it, without building anything.
    func showForDemo(items: [StopDraft], status: Status = .saved, turnBacks: [String: Double] = [:]) {
        self.items = items
        self.status = status
        self.turnBacks = turnBacks
    }
    #endif
}
