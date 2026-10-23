import CoreLocation
import Foundation

/// Who is at a stop (D25 piece 3b), worked out from positions alone: nothing is written, so there is nothing to
/// go stale on the server. A stop is a place on the route (`Target`), whatever put it there: a planned stop now,
/// a stop chosen mid-trip (D4) later, which builds a `Target` from its own place and offset and gets arrival,
/// the "3 of 4 here" count and the card for free.
enum StopArrival {
    /// A place on the main route that cars arrive at.
    struct Target: Equatable, Sendable {
        var latitude: Double
        var longitude: Double
        /// Meters along the main route.
        var routeOffset: Double
        /// The meeting point: joining cars head for it on their own route, so their time to merge is their time to it.
        var isMeeting = false

        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

        init(latitude: Double, longitude: Double, routeOffset: Double, isMeeting: Bool = false) {
            self.latitude = latitude
            self.longitude = longitude
            self.routeOffset = routeOffset
            self.isMeeting = isMeeting
        }

        init(_ stop: PlannedStop) {
            self.init(
                latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude,
                routeOffset: stop.routeOffset, isMeeting: stop.isMeeting)
        }
    }

    enum Status: Equatable, Sendable {
        /// Within `NextStop.hereRadius` of the stop on a fresh fix.
        case here
        /// Meters and seconds left, each nil when it can't be told (no pace, no distance).
        case away(distance: Double?, seconds: TimeInterval?)
        /// Within the here-radius, but on a fix older than 60 s: the car may have left, so it is not counted.
        case lastSeenHere
        /// No position at all yet.
        case unknown
        /// Past the stop along the route (more than the here-radius beyond it): it drove by, so no "N min away".
        case passed
    }

    struct Row: Equatable, Identifiable, Sendable {
        var id: String
        var car: Car
        var status: Status
        /// The car said it is skipping this stop (`SkipAnswers`): shown, but not counted and not waited for.
        var skipping = false
        var isHere: Bool { status == .here }
    }

    struct Tally: Equatable, Sendable {
        var rows: [Row]
        /// Skipping cars leave the count: "3 of 3 here" with a fourth car skipping. A car with no position yet still
        /// counts (the convoy is waiting for it; its row says "Waiting for location").
        var counted: [Row] { rows.filter { !$0.skipping } }
        var here: Int { counted.filter(\.isHere).count }
        var total: Int { counted.count }
        var allHere: Bool { total > 0 && here == total }
        /// "3 of 4 here".
        var title: String { "\(here) of \(total) here" }
    }

    /// The card for a stop exists only while the stop is still on: a skipped (or unknown) stop has none.
    static func target(stopId: String, in stops: [PlannedStop]) -> Target? {
        stops.first { $0.id == stopId && $0.isOpen }.map(Target.init)
    }

    /// "stop 1 of 2": the place of a stop among those still on (not skipped), by route order; nil when it is off.
    static func place(of stopId: String, in stops: [PlannedStop]) -> (index: Int, count: Int)? {
        let active = stops.filter(\.isOpen).sorted { $0.routeOffset < $1.routeOffset }
        guard let i = active.firstIndex(where: { $0.id == stopId }) else { return nil }
        return (i + 1, active.count)
    }

    /// One car. `offset` is its main-route offset (nil while joining); `pace` is seconds per meter, else the
    /// car's own `speed` is used. A fix older than `HazardLogic.Config.staleAfter` (60 s) never counts as here,
    /// however close it was: the car may have left.
    static func status(
        position: Position?, offset: Double?, target: Target, pace: Double?, speed: Double,
        timeToMerge: TimeInterval? = nil, now: Date, config: HazardLogic.Config = .default
    ) -> Status {
        guard let position else { return .unknown }
        let straight = RouteLine.haversine(
            .init(latitude: position.location.latitude, longitude: position.location.longitude), target.coordinate)
        let alongRoute = offset.map { abs(target.routeOffset - $0) }
        let near = straight <= NextStop.hereRadius || (alongRoute ?? .infinity) <= NextStop.hereRadius
        if near { return HazardLogic.isFresh(position, now: now, config: config) ? .here : .lastSeenHere }
        if let offset, offset > target.routeOffset { return .passed }
        let perMeter = pace ?? (speed > 0 ? 1 / speed : nil)
        if let alongRoute { return .away(distance: alongRoute, seconds: perMeter.map { $0 * alongRoute }) }
        // A joining car: its way in goes to the meeting point, so its own time to merge is the time to it.
        if target.isMeeting, let timeToMerge { return .away(distance: straight, seconds: timeToMerge) }
        return .away(distance: straight, seconds: perMeter.map { $0 * straight })
    }

    /// Every car in the trip once, convoy and joining, by badge number.
    static func tally(
        target: Target, convoy: [ConvoyEntry], joining: [JoiningEntry], pace: Double?, now: Date,
        skipping: Set<String> = []
    ) -> Tally {
        var rows: [Row] = convoy.map {
            Row(id: $0.id, car: $0.car, status: status(
                position: $0.position, offset: $0.convoyOffset, target: target, pace: pace, speed: $0.speed, now: now))
        }
        rows += joining.map {
            Row(id: $0.id, car: $0.car, status: status(
                position: $0.position, offset: nil, target: target, pace: pace, speed: $0.speed,
                timeToMerge: $0.timeToMerge, now: now))
        }
        for i in rows.indices where skipping.contains(rows[i].id) { rows[i].skipping = true }
        rows.sort { a, b in
            let na = a.car.number ?? Int.max, nb = b.car.number ?? Int.max
            return na != nb ? na < nb : a.id < b.id
        }
        return Tally(rows: rows)
    }

    /// What a row says: "Skipping" for a skipping car, else `words(status)`.
    static func words(_ row: Row) -> String { row.skipping ? "Skipping" : words(row.status) }

    /// "Here", "3 min away", "9 km away" (no time to give), "Waiting for location".
    static func words(_ status: Status) -> String {
        switch status {
        case .here: "Here"
        case .away(_, let seconds?): "\(ConvoyFormat.duration(seconds)) away"
        case .away(let distance?, nil): "\(ConvoyFormat.distance(distance)) away"
        case .away: "On the way"
        case .lastSeenHere: "Last seen here"
        case .unknown: "Waiting for location"
        case .passed: "Drove past"
        }
    }
}

/// Reading a stop's answers (D25 5a wrote them, 5b shows them). Pure.
enum SkipAnswers {
    /// The car ids that said they are skipping this stop. Pass `among` (the cars still in the trip) to leave out
    /// answers from cars that are gone, or nil to take every answer as it is.
    static func skipping(_ answers: [StopAnswer], among carIds: Set<String>? = nil) -> Set<String> {
        Set(answers.compactMap { answer in
            guard answer.answer == .skip, let id = answer.id else { return nil }
            if let carIds, !carIds.contains(id) { return nil }
            return id
        })
    }

    /// Whether the car has said it is skipping.
    static func isSkipping(carId: String, in answers: [StopAnswer]) -> Bool {
        skipping(answers).contains(carId)
    }

    /// The viewer's car may say "we'll skip": it is not the lead car, the stop is not skipped for everyone, and
    /// the car is still more than the here-radius short of it (the rules check the same, from the car's last
    /// reported place: exactly 150 m short is already there). `carOffset` is its place on the main route, nil
    /// before it has merged. A meeting point takes it only from a joining car (`isJoining`): a car with no way in
    /// of its own has nothing to skip (#215; the rules check the car's state).
    static func canSkip(
        stop: PlannedStop, isLeadCar: Bool, carOffset: Double?, tripStarted: Bool, isJoining: Bool = true
    ) -> Bool {
        guard tripStarted, !isLeadCar, stop.isOpen else { return false }
        if stop.isMeeting, !isJoining { return false }
        guard let carOffset else { return true }
        return carOffset < stop.routeOffset - NextStop.hereRadius
    }

    /// What everyone reads about the cars skipping: "Daniel’s car is skipping R&R Tapah", one line per car up to
    /// two; with more, one line: "3 cars are skipping R&R Tapah".
    static func lines(skippingCars cars: [Car], stopName: String) -> [String] {
        let sorted = cars.sorted { ($0.number ?? Int.max, $0.id ?? "") < ($1.number ?? Int.max, $1.id ?? "") }
        if sorted.count > 2 { return ["\(sorted.count) cars are skipping \(stopName)"] }
        return sorted.map { "\(StopLeave.ownerWord($0))’s car is skipping \(stopName)" }
    }
}
