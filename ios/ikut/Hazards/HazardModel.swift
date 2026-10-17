import Foundation
import Observation

/// Observable feed for the map's hazard markers. Inputs are plain values pushed in by the host,
/// like `ConvoyModel`; there is no Firestore here. Joining cars' own routes are decoded from
/// `Car.route` in `setCars`.
///
/// Events expire by time, so call `run()` (or `refresh()` on your own timer) to drop them on time.
@Observable
@MainActor
final class HazardModel {
    private(set) var markers: [HazardMarker] = []

    @ObservationIgnored private let config: HazardLogic.Config
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private var events: [TripEvent] = []
    @ObservationIgnored private var cars: [Car] = []
    @ObservationIgnored private var positions: [String: Position] = [:]
    @ObservationIgnored private var mainRoute: RouteLine?
    @ObservationIgnored private var ownRoutes: [String: RouteLine] = [:]
    @ObservationIgnored private var ownRouteSources: [String: String] = [:]
    @ObservationIgnored private var cache = HazardOffsetCache()

    init(config: HazardLogic.Config = .default, clock: @escaping @MainActor () -> Date = { Date() }) {
        self.config = config
        self.clock = clock
    }

    func setEvents(_ events: [TripEvent]) {
        self.events = events
        refresh()
    }

    func setCars(_ cars: [Car]) {
        self.cars = cars
        var routes: [String: RouteLine] = [:]
        var sources: [String: String] = [:]
        for car in cars where car.state == .joining {
            guard let encoded = car.route else { continue }
            let id = ConvoyOrdering.carID(car)
            sources[id] = encoded
            if ownRouteSources[id] == encoded {
                if let existing = ownRoutes[id] { routes[id] = existing }
            } else {
                // The route changed (or is new): offsets cached for the old one are stale, even
                // when the new one does not decode.
                cache.resetOwn(carId: id)
                if let line = ConvoyOrdering.ownRoute(encoded) { routes[id] = line }
            }
        }
        ownRoutes = routes
        ownRouteSources = sources
        refresh()
    }

    func setPositions(_ positions: [String: Position]) {
        self.positions = positions
        refresh()
    }

    func setMainRoute(_ route: RouteLine?) {
        mainRoute = route
        cache.resetMain()
        refresh()
    }

    func refresh(now: Date? = nil) {
        let next = HazardLogic.markers(
            events: events, cars: cars, positions: positions, mainRoute: mainRoute, ownRoutes: ownRoutes,
            now: now ?? clock(), config: config, cache: &cache)
        if next != markers { markers = next }
    }

    /// Ticks `refresh` every `interval` until cancelled. Use as `.task { await model.run() }`.
    func run(every interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            refresh()
        }
    }
}
