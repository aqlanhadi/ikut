import CoreLocation
import Foundation
import Observation

/// The towns the lobby's other cars join near ("Joins near Rawang", D50): one reverse lookup per car and join offset,
/// kept in memory for the trip (`shared(for:)`, so reopening the lobby doesn't ask again), asked one at a time with a
/// pause so the geocoder isn't throttled. Only the town name is kept: no car's start or join point is drawn or stored
/// anywhere (#361), and it reads nothing but the car docs.
@Observable @MainActor
final class JoinTowns {
    typealias PlaceRequest = @MainActor (CLLocationCoordinate2D) async -> String?

    /// Town by `key(carId:offset:)`; a lookup that found nothing has no entry (the row keeps "Joins the convoy").
    private(set) var towns: [String: String] = [:]

    @ObservationIgnored private let place: PlaceRequest
    @ObservationIgnored private let pause: Duration
    /// Answered lookups so far per key, and the `opens` count at the last one: a lookup that found nothing is asked
    /// once more on a later open (a throttled one may work then), and no more than twice.
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var attemptOpen: [String: Int] = [:]
    @ObservationIgnored private var opens = 0
    /// Keys queued or in flight.
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var queue: [(key: String, coordinate: CLLocationCoordinate2D)] = []
    @ObservationIgnored private var pump: Task<Void, Never>?
    /// Bumped by `cancel()`, so a pump that was cancelled can't write or clear what a newer one owns.
    @ObservationIgnored private var generation = 0

    /// `place`: the same lookup `OwnWayInfo` uses (`RouteBuilder.placeName`), so a town is named the same way.
    init(place: @escaping PlaceRequest = { await RouteBuilder.placeName(at: $0) }, pause: Duration = .seconds(1)) {
        self.place = place
        self.pause = pause
    }

    // MARK: Per trip

    private static var stores: [String: JoinTowns] = [:]

    /// The trip's towns, shared by every opening of its lobby.
    static func shared(for tripId: String) -> JoinTowns {
        if let found = stores[tripId] { return found }
        let made = JoinTowns()
        stores[tripId] = made
        return made
    }

    /// Stops every lookup and forgets every town (a different person signs in).
    static func forgetAll() {
        for store in stores.values { store.cancel() }
        stores = [:]
    }

    // MARK: Keys and offsets

    /// The car's offset to the metre: a few metres of drift in the stored offset doesn't ask again.
    static func key(carId: String, offset: Double) -> String { "\(carId)|\(Int(offset.clamped(0...1e9).rounded()))" }

    /// Where along the main route (`length` meters) a car joins, when it does and when that isn't the start: a car
    /// that starts with the convoy, is already on the main route (it has no route of its own, so a town would be where it is now), never meets it, isn't known yet, or joins within `startsWithin` of the start (a
    /// town there is the start's) has none, so nothing is looked up for it. A stored offset that isn't a number is
    /// none; a huge one is the route's end.
    static func joinOffset(_ join: OwnWayJoin?, length: Double) -> Double? {
        let raw: Double
        switch join {
        case .merges(let offset): raw = offset
        case .onRoute, .startsWithConvoy, .meetsAtDestination, nil: return nil
        }
        guard raw.isFinite, !length.isNaN else { return nil }
        let offset = max(0, min(raw, length))
        return offset < OwnWayLogic.startsWithin ? nil : offset
    }

    /// The town for this car at this join, once known.
    func town(carId: String, join: OwnWayJoin?, mainLength: Double) -> String? {
        Self.joinOffset(join, length: mainLength).flatMap { towns[Self.key(carId: carId, offset: $0)] }
    }

    // MARK: Asking

    /// A lobby was opened: failures from earlier openings may be asked once more.
    func open() { opens += 1 }

    /// Queues a lookup for each car (not yours) that joins along the way and hasn't been answered at that offset.
    /// `joins` are worked out once by the caller. Returns at once; the answers arrive in `towns`.
    func request(cars: [LobbyCar], joins: [String: LobbyContent.CarJoin], main: RouteLine) {
        for item in cars where item.hasTracker {
            guard let carId = item.car.id,
                let offset = Self.joinOffset(joins[carId]?.join, length: main.length),
                let coordinate = main.coordinate(atOffset: offset)
            else { continue }
            let key = Self.key(carId: carId, offset: offset)
            guard towns[key] == nil, !pending.contains(key) else { continue }
            if let done = attempts[key], done >= 2 || attemptOpen[key] == opens { continue }
            pending.insert(key)
            queue.append((key, coordinate))
        }
        guard pump == nil, !queue.isEmpty else { return }
        let mine = generation
        pump = Task { [weak self] in await self?.drain(mine) }
    }

    /// Stops the lookups and drops the queue. Keys never answered are forgotten, so a later request asks again.
    func cancel() {
        generation += 1
        pump?.cancel()
        pump = nil
        queue = []
        pending = []
    }

    /// Waits until the queue is empty (for tests).
    func settle() async { await pump?.value }

    private func drain(_ mine: Int) async {
        while mine == generation, !Task.isCancelled, !queue.isEmpty {
            let next = queue.removeFirst()
            let name = await place(next.coordinate)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard mine == generation, !Task.isCancelled else { return }
            pending.remove(next.key)
            attempts[next.key, default: 0] += 1
            attemptOpen[next.key] = opens
            if let name, !name.isEmpty { towns[next.key] = name }
            if !queue.isEmpty { try? await Task.sleep(for: pause) }
        }
        if mine == generation { pump = nil }
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
