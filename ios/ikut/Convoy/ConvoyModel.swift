import CoreLocation
import FirebaseFirestore
import Foundation
import Observation

/// One list row, as strings, following Map.dc.html.
struct ConvoyRowText: Equatable, Identifiable, Sendable {
    var id: String
    var number: Int?
    var name: String
    var color: String
    /// "Lead · 96 km/h", "92 km/h", "Paused" or "Last seen 2 min ago".
    var subtitle: String
    /// The subtitle is a warning (stale car).
    var subtitleIsWarning: Bool
    /// Right column, top: "Lead", "Front" or the gap distance ("1.8 km").
    var trailingPrimary: String
    /// Right column, bottom: "ETA 14:52" for the front row, "1 min behind" for the others.
    var trailingSecondary: String
    var isStale: Bool
    var isSeparated: Bool
}

struct JoiningRowText: Equatable, Identifiable, Sendable {
    var id: String
    var number: Int?
    var name: String
    var color: String
    /// "84 km/h", or "Last seen 2 min ago".
    var subtitle: String
    var subtitleIsWarning: Bool
    /// "18 min", or "--" when unknown.
    var trailingPrimary: String
    /// "to merge".
    var trailingSecondary: String
    var isStale: Bool
}

/// Front-car ETA, as last answered by the ETA provider.
struct FrontETA: Equatable, Sendable {
    var carId: String
    var requestedAt: Date
    var travelTime: TimeInterval
    /// When the reference car arrives: `requestedAt + travelTime`.
    var arrival: Date { requestedAt.addingTimeInterval(travelTime) }
}

/// Observable convoy state for the map's list. Inputs are plain values pushed in by the trip session:
/// `setCars`, `setPositions`, `setMainRoute` (or `update`), plus `run()` to keep staleness and
/// ETAs moving between fixes. No Firestore here.
///
/// ETAs: one MKDirections request per refresh, for the ETA reference car (front-most car with a fresh
/// position) to the end of the main route, paced by `ETARefreshSchedule`. Every other convoy car's
/// ETA is the reference ETA plus its time behind the reference (the sum of the gap times). Joining
/// cars get `now + timeToMerge`, from their speed and own-route distance: no MKDirections request,
/// because per-car requests would hit Apple's throttle. The last good ETA is kept while a refresh is
/// pending or failing.
@Observable
@MainActor
final class ConvoyModel {
    // MARK: Outputs

    private(set) var snapshot: ConvoySnapshot = .empty
    private(set) var frontETA: FrontETA?
    var convoy: [ConvoyEntry] { snapshot.convoy }
    var joining: [JoiningEntry] { snapshot.joining }
    /// Set by the owner for "ETA Ipoh 14:52"; optional.
    var destinationName: String?

    // MARK: Configuration

    @ObservationIgnored private let provider: any ETAProviding
    @ObservationIgnored private let schedule: ETARefreshSchedule
    @ObservationIgnored private let config: ConvoyOrdering.Config
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone

    // MARK: Inputs and bookkeeping

    @ObservationIgnored private var cars: [Car] = []
    @ObservationIgnored private var positions: [String: Position] = [:]
    @ObservationIgnored private var mainRoute: RouteLine?
    @ObservationIgnored private var smoother = SpeedSmoother()
    @ObservationIgnored private var mergeOffsets: [String: Double] = [:]
    @ObservationIgnored private var lastRequest: (at: Date, from: CLLocationCoordinate2D, carId: String)?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var etaTask: Task<Void, Never>?

    init(
        provider: any ETAProviding = MapKitETAProvider(),
        schedule: ETARefreshSchedule = .default,
        config: ConvoyOrdering.Config = .default,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        clock: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.provider = provider
        self.schedule = schedule
        self.config = config
        self.locale = locale
        self.timeZone = timeZone
        self.clock = clock
    }

    // MARK: Inputs

    func setCars(_ cars: [Car]) {
        self.cars = cars
        recomputeMergeOffsets()
        refresh()
    }

    func setPositions(_ positions: [String: Position]) {
        self.positions = positions
        smoother.ingest(positions)
        refresh()
    }

    func setMainRoute(_ route: RouteLine?) {
        mainRoute = route
        recomputeMergeOffsets()
        refresh()
    }

    func update(cars: [Car], positions: [String: Position]) {
        self.cars = cars
        self.positions = positions
        smoother.ingest(positions)
        recomputeMergeOffsets()
        refresh()
    }

    /// Recomputes the order for the current time (positions go stale without new data) and asks for
    /// a new ETA if the schedule says so. Cheap; safe to call often.
    func refresh(now: Date? = nil) {
        let now = now ?? clock()
        snapshot = ConvoyOrdering.order(
            cars: cars, positions: positions, now: now, speeds: smoother.all,
            mainRoute: mainRoute, ownMergeOffsets: mergeOffsets, config: config)
        requestETAIfNeeded(now: now)
    }

    /// Ticks `refresh` every `interval` until cancelled. Use as `.task { await model.run() }`.
    func run(every interval: Duration = .seconds(5)) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { break }
            refresh()
        }
    }

    /// Waits for an in-flight ETA request. For tests.
    func waitForETA() async { await etaTask?.value }

    // MARK: ETA

    private var destination: CLLocationCoordinate2D? { mainRoute?.coordinates.last }

    private func requestETAIfNeeded(now: Date) {
        guard etaTask == nil, let destination, let ref = snapshot.etaReference else { return }
        let here = CLLocationCoordinate2D(
            latitude: ref.position.location.latitude, longitude: ref.position.location.longitude)
        let moved: CLLocationDistance
        if let last = lastRequest, last.carId == ref.id {
            moved = RouteLine.haversine(last.from, here)
        } else {
            moved = .infinity
        }
        guard schedule.shouldRequest(
            lastRequest: lastRequest?.at, movedSince: moved, now: now, consecutiveFailures: failures)
        else { return }
        lastRequest = (now, here, ref.id)
        let provider = provider
        etaTask = Task { [weak self] in
            let result: Result<TimeInterval, Error>
            do { result = .success(try await provider.travelTime(from: here, to: destination)) }
            catch { result = .failure(error) }
            self?.finishETA(result, carId: ref.id, requestedAt: now)
        }
    }

    private func finishETA(_ result: Result<TimeInterval, Error>, carId: String, requestedAt: Date) {
        etaTask = nil
        switch result {
        case .success(let t) where t.isFinite && t >= 0:
            failures = 0
            frontETA = FrontETA(carId: carId, requestedAt: requestedAt, travelTime: t)
        default:
            failures += 1
        }
    }

    /// Arrival time at the destination for a convoy car: the reference ETA plus its time behind the
    /// reference. Nil before the first ETA arrives, or for cars ahead of the reference (stale fronts).
    func arrival(forCar id: String) -> Date? {
        guard let eta = frontETA, let entry = convoy.first(where: { $0.id == id }),
              let behind = entry.timeBehindReference else { return nil }
        // The ETA belongs to the reference it was requested for; if the reference changed since,
        // the gaps no longer line up until the next answer.
        guard snapshot.etaReference?.id == eta.carId else { return nil }
        return eta.arrival.addingTimeInterval(behind)
    }

    /// When a joining car reaches its merge point, from its speed and own-route distance.
    func mergeArrival(forCar id: String, now: Date? = nil) -> Date? {
        guard let entry = joining.first(where: { $0.id == id }), let t = entry.timeToMerge else { return nil }
        return (now ?? clock()).addingTimeInterval(t)
    }

    // MARK: Strings

    /// "3 in Convoy".
    var title: String { "\(convoy.count) in Convoy" }

    /// "Spread 6.4 km · ETA Ipoh 14:52"; either part is dropped when unknown.
    var subtitle: String {
        var parts: [String] = []
        if let spread = snapshot.spread { parts.append("Spread \(ConvoyFormat.distance(spread))") }
        if let reference = snapshot.etaReference, let date = arrival(forCar: reference.id) {
            parts.append(ConvoyFormat.eta(date, destination: destinationName, locale: locale, timeZone: timeZone))
        }
        return parts.joined(separator: " · ")
    }

    /// "Arriving 4:35 PM" for the front, nil until known.
    var arrivingText: String? {
        guard let reference = snapshot.etaReference, let date = arrival(forCar: reference.id) else { return nil }
        return ConvoyFormat.arriving(date, locale: locale, timeZone: timeZone)
    }

    var convoyRows: [ConvoyRowText] {
        convoy.map { e in
            let leadPrefix = e.isLead ? "Lead · " : ""
            let subtitle = e.isPaused
                ? ConvoyFormat.paused
                : e.isStale
                    ? ConvoyFormat.lastSeen(age: e.age ?? 0)
                    : leadPrefix + ConvoyFormat.speed(metersPerSecond: e.speed)
            let primary: String
            let secondary: String
            if let gap = e.gap {
                primary = ConvoyFormat.distance(gap.distance)
                secondary = ConvoyFormat.behind(gap.time)
            } else {
                primary = e.isLead ? "Lead" : "Front"
                secondary = arrival(forCar: e.id).map {
                    ConvoyFormat.eta($0, locale: locale, timeZone: timeZone)
                } ?? "Calculating ETA"
            }
            return ConvoyRowText(
                id: e.id, number: e.car.number, name: e.car.name, color: e.car.color,
                subtitle: subtitle, subtitleIsWarning: e.isStale,
                trailingPrimary: primary, trailingSecondary: secondary,
                isStale: e.isStale, isSeparated: e.gap?.isSeparated ?? false)
        }
    }

    var joiningRows: [JoiningRowText] {
        joining.map { e in
            JoiningRowText(
                id: e.id, number: e.car.number, name: e.car.name, color: e.car.color,
                subtitle: e.isPaused
                    ? ConvoyFormat.paused
                    : e.isStale
                    ? ConvoyFormat.lastSeen(age: e.age ?? 0)
                    : (e.position == nil ? "Waiting for location" : ConvoyFormat.speed(metersPerSecond: e.speed)),
                subtitleIsWarning: e.isStale,
                trailingPrimary: e.timeToMerge.map(ConvoyFormat.duration) ?? "--",
                trailingSecondary: "to merge", isStale: e.isStale)
        }
    }

    // MARK: Private

    private func recomputeMergeOffsets() {
        guard let main = mainRoute else { mergeOffsets = [:]; return }
        mergeOffsets = ConvoyOrdering.mergeOffsets(cars: cars.filter { $0.state == .joining }, main: main)
    }
}
