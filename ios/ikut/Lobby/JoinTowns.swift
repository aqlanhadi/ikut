import CoreLocation
import Foundation
import Observation

/// The towns the lobby's other cars join near ("Joins near Rawang", D50): one reverse lookup per car and join offset,
/// kept in memory for the trip, asked one at a time with a pause so the geocoder isn't throttled. Only the town name
/// is kept: no car's start or join point is drawn or stored anywhere (#361), and it reads nothing but the car docs.
@Observable @MainActor
final class JoinTowns {
    typealias PlaceRequest = @MainActor (CLLocationCoordinate2D) async -> String?

    /// Town by `key(carId:offset:)`; a lookup that found nothing has no entry (the row keeps "Joins the convoy").
    private(set) var towns: [String: String] = [:]

    @ObservationIgnored private let place: PlaceRequest
    @ObservationIgnored private let pause: Duration
    /// Keys already asked (or queued), answered or not: a failed lookup isn't repeated for the same car and offset.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private var queue: [(key: String, coordinate: CLLocationCoordinate2D)] = []
    @ObservationIgnored private var pump: Task<Void, Never>?

    /// `place`: the same lookup `OwnWayInfo` uses (`RouteBuilder.placeName`), so a town is named the same way.
    init(place: @escaping PlaceRequest = { await RouteBuilder.placeName(at: $0) }, pause: Duration = .seconds(1)) {
        self.place = place
        self.pause = pause
    }

    /// The car's offset to the metre: a few metres of drift in the stored offset doesn't ask again.
    static func key(carId: String, offset: Double) -> String { "\(carId)|\(Int(offset.rounded()))" }

    /// Where along the main route a car joins, when it does: a car that starts with the convoy, never meets it or
    /// isn't known yet has none, so nothing is looked up for it.
    static func joinOffset(_ join: OwnWayJoin?) -> Double? {
        switch join {
        case .merges(let offset), .onRoute(let offset): offset
        case .startsWithConvoy, .meetsAtDestination, nil: nil
        }
    }

    /// The town for this car at this join, once known.
    func town(carId: String, join: OwnWayJoin?) -> String? {
        Self.joinOffset(join).flatMap { towns[Self.key(carId: carId, offset: $0)] }
    }

    /// Queues a lookup for each car (not yours) that joins along the way and hasn't been asked at that offset.
    /// Returns at once; the answers arrive in `towns`.
    func request(cars: [LobbyCar], main: RouteLine, hasMeetingPoint: Bool) {
        for item in cars where item.hasTracker {
            guard let carId = item.car.id,
                let offset = Self.joinOffset(LobbyContent.join(of: item.car, main: main, hasMeetingPoint: hasMeetingPoint)),
                let coordinate = main.coordinate(atOffset: offset)
            else { continue }
            let key = Self.key(carId: carId, offset: offset)
            guard asked.insert(key).inserted else { continue }
            queue.append((key, coordinate))
        }
        guard pump == nil, !queue.isEmpty else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    /// Waits until the queue is empty (for tests).
    func settle() async { await pump?.value }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if let name = await place(next.coordinate)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                towns[next.key] = name
            }
            if !queue.isEmpty { try? await Task.sleep(for: pause) }
        }
        pump = nil
    }
}
