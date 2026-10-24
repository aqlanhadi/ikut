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
    /// The row is the viewer's own car: it gets the "You" tag after its name.
    var isMine = false
    /// Reached the destination: the trailing column shows an "Arrived" pill.
    var hasArrived = false
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
    /// The reference car's place on the main route when it was asked; the planned stops ahead of it add their time.
    var referenceOffset: Double = 0
    /// When the reference car arrives: `requestedAt + travelTime`.
    var arrival: Date { requestedAt.addingTimeInterval(travelTime) }
}

/// Observable convoy state for the map's list. Inputs are plain values pushed in by the trip session:
/// `setCars`, `setPositions`, `setMainRoute` (or `update`), plus `run()` to keep staleness and
/// ETAs moving between fixes. No Firestore here.
///
/// ETAs: one MKDirections request per refresh, for the ETA reference car (the lead when fresh, else
/// the car with the most cars around it: `ConvoyOrdering`) to the end of the main route, paced by `ETARefreshSchedule`. Every other convoy car's
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
    /// Town names of cars parked far from the viewer ("Rawang"), by car id, as the reverse geocoder answers.
    private(set) var placeNames: [String: String] = [:]
    /// The viewer's car, for the distance in the rows ("38 km ahead"); nil when not in a car.
    var myCarId: String? {
        didSet { if myCarId != oldValue { lookUpPlaceNames() } }
    }

    // MARK: Configuration

    @ObservationIgnored private let provider: any ETAProviding
    @ObservationIgnored private let schedule: ETARefreshSchedule
    @ObservationIgnored private let config: ConvoyOrdering.Config
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let placeNamer: @MainActor (CLLocationCoordinate2D) async -> String?

    // MARK: Inputs and bookkeeping

    @ObservationIgnored private var cars: [Car] = []
    @ObservationIgnored private var positions: [String: Position] = [:]
    @ObservationIgnored private var mainRoute: RouteLine?
    /// The trip's planned stops (D25): each one still ahead adds its planned length to the arrival times.
    private(set) var stops: [PlannedStop] = []
    @ObservationIgnored private var smoother = SpeedSmoother()
    @ObservationIgnored private var mergeOffsets: [String: Double] = [:]
    @ObservationIgnored private var lastRequest: (at: Date, from: CLLocationCoordinate2D, carId: String)?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var etaTask: Task<Void, Never>?
    /// Cars that have been together this session (`ConvoySnapshot.together`), in memory only: after a
    /// relaunch a gap that is already wide stays quiet until it closes and opens again.
    @ObservationIgnored private var together: Set<CarPair> = []
    /// Where each far car's place name was looked up, the lookups in flight, and when to try again.
    @ObservationIgnored private var placeLookedUpAt: [String: CLLocationCoordinate2D] = [:]
    @ObservationIgnored private var placeTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var placeRetryAt: [String: Date] = [:]

    init(
        provider: any ETAProviding = MapKitETAProvider(),
        schedule: ETARefreshSchedule = .default,
        config: ConvoyOrdering.Config = .default,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        clock: @escaping @MainActor () -> Date = { Date() },
        placeNamer: @escaping @MainActor (CLLocationCoordinate2D) async -> String? = {
            await RouteBuilder.placeName(at: $0)
        }
    ) {
        self.placeNamer = placeNamer
        self.provider = provider
        self.schedule = schedule
        self.config = config
        self.locale = locale
        self.timeZone = timeZone
        self.clock = clock
    }

    // MARK: Inputs

    func setStops(_ stops: [PlannedStop]) { self.stops = stops }

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
            mainRoute: mainRoute, ownMergeOffsets: mergeOffsets, together: together, config: config)
        together = snapshot.together
        lookUpPlaceNames()
        requestETAIfNeeded(now: now)
    }

    /// Waits for in-flight place-name lookups. For tests.
    func waitForPlaceNames() async {
        for task in placeTasks.values { await task.value }
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
            self?.finishETA(result, carId: ref.id, requestedAt: now, offset: ref.convoyOffset)
        }
    }

    private func finishETA(_ result: Result<TimeInterval, Error>, carId: String, requestedAt: Date, offset: Double) {
        etaTask = nil
        switch result {
        case .success(let t) where t.isFinite && t >= 0:
            failures = 0
            frontETA = FrontETA(carId: carId, requestedAt: requestedAt, travelTime: t, referenceOffset: offset)
        default:
            failures += 1
        }
    }

    /// Arrival time at the destination for a convoy car: the reference ETA plus its time behind the
    /// reference, plus the planned length of every stop still ahead of the reference (`StopDelay`).
    /// Nil before the first ETA arrives, or for cars ahead of the reference (stale fronts).
    func arrival(forCar id: String) -> Date? {
        guard let drive = driveArrival(forCar: id), let eta = frontETA else { return nil }
        return drive.addingTimeInterval(stopDelay(for: eta))
    }

    /// The same without the stops: when the car gets there by driving alone. The Next stop cell's pace comes from it.
    func driveArrival(forCar id: String) -> Date? {
        guard let eta = frontETA, let entry = convoy.first(where: { $0.id == id }),
              let behind = entry.timeBehindReference else { return nil }
        // The ETA belongs to the reference it was requested for; if the reference changed since,
        // the gaps no longer line up until the next answer.
        guard snapshot.etaReference?.id == eta.carId else { return nil }
        return eta.arrival.addingTimeInterval(behind)
    }

    /// Counted from when the ETA was asked, so what is left of a stop does not shift the arrival as the clock runs.
    private func stopDelay(for eta: FrontETA) -> TimeInterval {
        guard !stops.isEmpty else { return 0 }
        let length = mainRoute?.length ?? 0
        let speed = convoy.first(where: { $0.id == eta.carId })?.speed
        let pace = NextStop.pace(
            travelTimeToGo: eta.travelTime, remaining: max(0, length - eta.referenceOffset), speed: speed)
        return StopDelay.seconds(stops: stops, from: eta.referenceOffset, now: eta.requestedAt, pace: pace)
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

    var convoyRows: [ConvoyRowText] { convoyRows(myCarId: myCarId) }

    /// The rows, with the viewer's own car marked `isMine`. A car more than 2 km from the viewer's along the
    /// route says how far instead of its speed: "38 km ahead · parked near Rawang", "12 km behind".
    func convoyRows(myCarId: String?) -> [ConvoyRowText] {
        convoy.map { e in
            let mine = e.id == myCarId
            let leadPrefix = e.isLead ? "Lead · " : ""
            let subtitle = e.isPaused
                ? ConvoyFormat.paused
                : e.isStale
                    ? ConvoyFormat.lastSeen(age: e.age ?? 0)
                    : leadPrefix + (farText(e, myCarId: myCarId) ?? ConvoyFormat.speed(metersPerSecond: e.speed))
            let primary: String
            let secondary: String
            if e.hasArrived {
                primary = ConvoyFormat.arrived
                secondary = ""
            } else if let gap = e.gap {
                primary = ConvoyFormat.distance(gap.distance)
                secondary = ConvoyFormat.behind(gap.time)
            } else {
                primary = e.isLead ? "Lead" : "Front"
                // A front car ahead of the reference (parked far on, or stale) has no arrival time of its own.
                let aheadOfReference = snapshot.etaReference != nil && e.timeBehindReference == nil
                secondary = arrival(forCar: e.id).map {
                    ConvoyFormat.eta($0, locale: locale, timeZone: timeZone)
                } ?? (aheadOfReference ? "" : "Calculating ETA")
            }
            return ConvoyRowText(
                id: e.id, number: e.car.number, name: e.car.name, color: e.car.color,
                subtitle: subtitle, subtitleIsWarning: e.isStale,
                trailingPrimary: primary, trailingSecondary: secondary,
                isStale: e.isStale, isSeparated: !e.hasArrived && (e.gap?.hasDrifted ?? false),
                isMine: mine, hasArrived: e.hasArrived)
        }
    }

    /// Time to merge while the car moves, distance under the speed floor; nil without an estimate.
    func joinAmount(_ e: JoiningEntry) -> ConvoyFormat.JoinAmount? {
        ConvoyFormat.joinAmount(
            timeToMerge: e.timeToMerge, distanceToMerge: e.distanceToMerge, speed: e.speed, parkedSpeed: config.parkedSpeed)
    }

    /// The collapsed summary: my own joining car first ("You join in 14 km"), else the first with a merge time.
    func summaryParts(myCarId: String?) -> (driving: String, joining: String?, spread: String?) {
        let joiner = joining.first(where: { $0.id == myCarId })
            ?? joining.first(where: { $0.timeToMerge != nil }) ?? joining.first
        return ConvoyFormat.convoySummary(
            driving: convoy.count, joinerName: joiner?.car.name, joinIn: joiner?.timeToMerge,
            spread: convoy.count > 1 ? snapshot.spread : nil,
            joinerIsMe: joiner != nil && joiner?.id == myCarId,
            joinAmount: joiner.flatMap { joinAmount($0) })
    }

    /// The panel header's words for my own trip; the joining line only while my car is in the joining list.
    func headerText(
        car: Car?, join: OwnWayJoin?, ownStartTown: String?, mainStartTown: String?, joinPlace: String?, destination: String
    ) -> ConvoyHeader.Text {
        let mine = joining.first(where: { $0.id == myCarId })
        return ConvoyHeader.text(
            car: car, joinEntry: mine, join: join, ownStartTown: ownStartTown, mainStartTown: mainStartTown,
            joinPlace: joinPlace, destination: destination, amount: mine.flatMap { joinAmount($0) })
    }

    var joiningRows: [JoiningRowText] { joiningRows(myCarId: nil) }

    func joiningRows(myCarId: String?) -> [JoiningRowText] {
        joining.map { e in
            JoiningRowText(
                id: e.id, number: e.car.number, name: e.car.name, color: e.car.color,
                subtitle: e.isPaused
                    ? ConvoyFormat.paused
                    : e.isStale
                    ? ConvoyFormat.lastSeen(age: e.age ?? 0)
                    : (e.position == nil ? "Waiting for location" : ConvoyFormat.speed(metersPerSecond: e.speed)),
                subtitleIsWarning: e.isStale,
                trailingPrimary: joinAmount(e)?.text ?? "--",
                trailingSecondary: "to merge", isStale: e.isStale)
        }
    }

    // MARK: Far cars

    /// Meters along the route from my car to `carId`, positive when it is ahead; nil unless both are in
    /// the convoy.
    func distance(fromMyCarTo carId: String) -> Double? { snapshot.distance(from: myCarId, to: carId) }

    /// "38 km ahead · parked near Rawang", "38 km ahead" while it moves, or nil within 2 km of my car
    /// (and for my own car, or a car that has arrived).
    private func farText(_ e: ConvoyEntry, myCarId: String?) -> String? {
        guard e.id != myCarId, !e.hasArrived, let meters = snapshot.distance(from: myCarId, to: e.id),
              let far = ConvoyFormat.relativeDistance(meters, beyond: config.groupRadius) else { return nil }
        guard e.isParked else { return far }
        guard let place = placeNames[e.id] else { return "\(far) · parked" }
        return "\(far) · parked near \(ConvoyFormat.placeShortName(place))"
    }

    /// Looks up the town of each car parked more than 2 km from mine, once, and again only if it moves
    /// 2 km. A lookup that finds nothing is tried again after a minute.
    private func lookUpPlaceNames() {
        let now = clock()
        for (id, at) in placeRetryAt where at <= now {
            placeRetryAt[id] = nil
            placeLookedUpAt[id] = nil
        }
        for e in convoy where e.isParked && e.id != myCarId && !e.hasArrived && placeTasks[e.id] == nil {
            guard let meters = snapshot.distance(from: myCarId, to: e.id), abs(meters) > config.groupRadius else { continue }
            let here = CLLocationCoordinate2D(latitude: e.position.location.latitude, longitude: e.position.location.longitude)
            if let last = placeLookedUpAt[e.id], RouteLine.haversine(last, here) < 2000 { continue }
            placeLookedUpAt[e.id] = here
            let id = e.id
            let namer = placeNamer
            placeTasks[id] = Task { [weak self] in
                let name = await namer(here)
                guard let self else { return }
                self.placeTasks[id] = nil
                if let name { self.placeNames[id] = name } else { self.placeRetryAt[id] = self.clock().addingTimeInterval(60) }
            }
        }
    }

    // MARK: Private

    private func recomputeMergeOffsets() {
        guard let main = mainRoute else { mergeOffsets = [:]; return }
        mergeOffsets = ConvoyOrdering.mergeOffsets(cars: cars.filter { $0.state == .joining }, main: main)
    }
}
