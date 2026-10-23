import Foundation

/// "R&R Tapah in 2 km. Take the exit." (D25 piece 3a): when this phone's car comes within about 2 km of a
/// planned stop ahead, once per stop. A stop is a point at its `routeOffset` on the main route, compared
/// with the car's own offset, the way a hazard is (`ApproachCore`, with a 2 km distance).
///
/// - A skipped stop, a meeting point (cars are on their own routes until they get there, and the first
///   stop sits at offset 0) and a stop behind the car never fire.
/// - Once per stop for the life of the value: GPS jitter around 2 km, or driving on past it, never fires
///   it again.
struct StopApproach: Sendable {
    static let alertDistance: Double = 2_000
    /// The pill goes when the car is this close: from there the car is arriving (piece 3b's card).
    static let arrivedDistance: Double = 150

    struct Due: Equatable, Sendable {
        var stopId: String
        var name: String
        var kind: PlannedStopKind
        var minutes: Int?
        /// Meters from the car to the stop when it fired.
        var distance: Double
    }

    private var core = ApproachCore(config: .init(alertDistance: alertDistance))

    init() {}

    /// The stops that just came within 2 km, nearest first, for a car at `myOffset`; empty without an offset.
    mutating func check(stops: [PlannedStop], myOffset: Double?) -> [Due] {
        guard let myOffset else { return [] }
        let candidates = stops.compactMap { stop -> ApproachCore.Candidate? in
            guard let id = stop.id, stop.isOpen, !stop.isMeeting else { return nil }
            return .init(id: id, offset: stop.routeOffset)
        }
        return core.evaluate(candidates: candidates, myOffset: myOffset).compactMap { fire in
            guard let stop = stops.first(where: { $0.id == fire.id }) else { return nil }
            return Due(stopId: fire.id, name: stop.name, kind: stop.kind, minutes: stop.minutes, distance: fire.distance)
        }.sorted { $0.distance < $1.distance }
    }

    /// True while the pill should stay: the stop is still active, ahead, and not yet at the door.
    static func isShowing(_ stop: PlannedStop?, distance: Double?) -> Bool {
        guard let stop, stop.isOpen, let distance else { return false }
        return distance > arrivedDistance
    }
}

extension PlannedStopKind {
    /// "Fuel", "Food", ...: the word in the pill's second line.
    var word: String {
        switch self {
        case .meet: "Meeting point"
        case .fuel: "Fuel"
        case .food: "Food"
        case .rest: "Rest"
        case .toilet: "Toilet"
        case .sight: "Sight"
        }
    }

    /// What to do at the stop. A highway R&R (fuel, rest, toilet) is left by its exit; a food or sight stop
    /// is as often in a town, so it only says it is coming.
    var approachAdvice: String {
        switch self {
        case .fuel, .rest, .toilet: "Take the exit"
        case .food: "Food stop ahead"
        case .sight, .meet: "Coming up"
        }
    }
}

extension AlertWording {
    /// Pill "R&R Tapah in 2 km" over "Take the exit · Fuel · 20 min"; spoken "R&R Tapah in 2 km. Take the exit."
    static func stopApproach(tripId: String, due: StopApproach.Due) -> TripAlert {
        let distance = distanceText(due.distance)
        let advice = due.kind.approachAdvice
        let body = ([advice, due.kind.word] + (due.minutes.map { ["\($0) min"] } ?? [])).joined(separator: " · ")
        return TripAlert(
            id: "\(due.stopId)@stopapproach", eventId: due.stopId, tripId: tripId, type: .other("stopApproach"),
            category: .status, severity: .medium, distance: due.distance,
            title: "\(due.name) in \(distance)", body: body,
            spoken: "\(due.name) in \(distance). \(advice).", kind: .stopApproach)
    }
}
