import Foundation

/// Time the planned stops still ahead add to an arrival (D25 piece 4c). Pure, so the tests reach it without
/// the model. The drive itself still comes from the one MKDirections answer; this only adds the waiting.
enum StopDelay {
    /// Seconds a car at `offset` on the main route loses to the stops still ahead of it, counted from `now`.
    /// - A stop not skipped and not left, at or ahead of `offset` (a car a little past the point still counts
    ///   it, `NextStop.hereRadius`), adds its planned `minutes` (none: 0).
    /// - A stop the lead car has reached (`arrivedAt`) adds what is left of it, `leavingAt - now`, never below 0.
    /// - A meeting point adds the wait until `meetAt` when the drive there would be earlier. That needs `pace`
    ///   (seconds per meter) to know the drive; without it the wait is not counted.
    static func seconds(stops: [PlannedStop], from offset: Double, now: Date, pace: Double?) -> TimeInterval {
        let ahead = stops
            .filter { $0.isOpen && $0.routeOffset >= offset - NextStop.hereRadius }
            .sorted { $0.routeOffset < $1.routeOffset }
        var clock = now
        var at = offset
        var driving: TimeInterval = 0
        for stop in ahead {
            let drive = pace.map { $0 * max(0, stop.routeOffset - at) } ?? 0
            driving += drive
            var arrive = clock.addingTimeInterval(drive)
            if stop.isMeeting {
                if pace != nil, let meetAt = stop.meetAt { arrive = max(arrive, meetAt) }
                clock = arrive
            } else if stop.arrivedAt != nil {
                clock = max(arrive, StopLeave.leavingAt(stop) ?? arrive)
            } else {
                clock = arrive.addingTimeInterval(TimeInterval((stop.minutes ?? 0) * 60))
            }
            at = max(at, stop.routeOffset)
        }
        return max(0, clock.timeIntervalSince(now) - driving)
    }
}
