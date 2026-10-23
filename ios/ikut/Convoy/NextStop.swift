import Foundation

/// The convoy panel's Next stop cell (RoadStops.dc.html): "R&R Tapah", "18 km · 12 min", measured from
/// the viewer's own offset on the main route to the next planned stop that is not skipped and not passed.
/// Pure, so the tests reach it without the view.
enum NextStop {
    /// Within this many meters of a stop, either side, the car is at it: 3b's here-radius. A car that
    /// pulled into an R&R a little past the point still sees it as here, not gone.
    static let hereRadius: Double = 150

    struct Cell: Equatable {
        var name: String
        /// Meters ahead along the main route; 0 once here.
        var distance: Double
        /// Nil when there is no speed or ETA to give a time from.
        var seconds: TimeInterval?
        var isHere: Bool
        /// The stop's id, for 3b to open its card from the cell.
        var stopId: String?

        /// "18 km · 12 min", just "18 km" with no time, "Here" at the stop.
        var detail: String {
            if isHere { return "Here" }
            let km = ConvoyFormat.distance(distance)
            guard let seconds else { return km }
            return "\(km) · \(ConvoyFormat.duration(seconds))"
        }
    }

    /// The first stop (by place on the route) that is not skipped and that `offset` has not left
    /// behind by more than the here-radius.
    static func next(in stops: [PlannedStop], from offset: Double) -> PlannedStop? {
        stops.filter { $0.isOpen && $0.routeOffset >= offset - hereRadius }
            .min { $0.routeOffset < $1.routeOffset }
    }

    /// Seconds per meter to the stop: the viewer's ETA to the destination spread over what is left of the
    /// route (the panel's own "to go" time), else the car's smoothed speed; nil with neither.
    static func pace(travelTimeToGo: TimeInterval?, remaining: Double, speed: Double?) -> Double? {
        if let travelTimeToGo, travelTimeToGo > 0, remaining > 500 { return travelTimeToGo / remaining }
        if let speed, speed > 0 { return 1 / speed }
        return nil
    }

    /// The cell for a car at `offset` on the main route; nil with no stop ahead, or a car with no
    /// main-route offset yet (still joining).
    static func cell(stops: [PlannedStop], offset: Double?, pace: Double?) -> Cell? {
        guard let offset, let stop = next(in: stops, from: offset) else { return nil }
        let ahead = stop.routeOffset - offset
        let here = abs(ahead) <= hereRadius
        let distance = max(0, ahead)
        return Cell(
            name: stop.name, distance: here ? 0 : distance, seconds: here ? nil : pace.map { $0 * distance },
            isHere: here, stopId: stop.id)
    }

    /// The cell for a car still on its own way in: the meeting point, if the trip has one that is not skipped,
    /// with how far its own route has to go. Nil without a meeting point or a known distance, and for any other
    /// stop: a car that has not joined has no place on the route to measure them from.
    static func joiningCell(stops: [PlannedStop], distance: Double?, seconds: TimeInterval?) -> Cell? {
        guard let distance, let meet = stops.first(where: { $0.isMeeting && $0.isOpen }) else { return nil }
        let here = distance <= hereRadius
        return Cell(
            name: meet.name, distance: here ? 0 : distance, seconds: here ? nil : seconds, isHere: here, stopId: meet.id)
    }
}
