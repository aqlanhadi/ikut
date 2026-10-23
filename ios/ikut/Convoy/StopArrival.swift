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
    }

    struct Row: Equatable, Identifiable, Sendable {
        var id: String
        var car: Car
        var status: Status
        var isHere: Bool { status == .here }
    }

    struct Tally: Equatable, Sendable {
        var rows: [Row]
        var here: Int { rows.filter(\.isHere).count }
        var total: Int { rows.count }
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
        let perMeter = pace ?? (speed > 0 ? 1 / speed : nil)
        if let alongRoute { return .away(distance: alongRoute, seconds: perMeter.map { $0 * alongRoute }) }
        // A joining car: its way in goes to the meeting point, so its own time to merge is the time to it.
        if target.isMeeting, let timeToMerge { return .away(distance: straight, seconds: timeToMerge) }
        return .away(distance: straight, seconds: perMeter.map { $0 * straight })
    }

    /// Every car in the trip once, convoy and joining, by badge number.
    static func tally(
        target: Target, convoy: [ConvoyEntry], joining: [JoiningEntry], pace: Double?, now: Date
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
        rows.sort { a, b in
            let na = a.car.number ?? Int.max, nb = b.car.number ?? Int.max
            return na != nb ? na < nb : a.id < b.id
        }
        return Tally(rows: rows)
    }

    /// "Here", "3 min away", "9 km away" (no time to give), "Waiting for location".
    static func words(_ status: Status) -> String {
        switch status {
        case .here: "Here"
        case .away(_, let seconds?): "\(ConvoyFormat.duration(seconds)) away"
        case .away(let distance?, nil): "\(ConvoyFormat.distance(distance)) away"
        case .away: "On the way"
        case .lastSeenHere: "Last seen here"
        case .unknown: "Waiting for location"
        }
    }
}
