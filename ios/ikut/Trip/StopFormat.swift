import Foundation

/// The words for planned stops on the lobby card and in the add-a-stop sheet (LobbyStops.dc.html, AddStop.dc.html).
enum StopFormat {
    static func kind(_ kind: PlannedStopKind) -> String {
        switch kind {
        case .meet: "Meet"
        case .fuel: "Fuel"
        case .food: "Food"
        case .rest: "Rest"
        case .toilet: "Toilet"
        case .sight: "Sight"
        }
    }

    /// "20 min", "1 h", "1 h 15 min".
    static func length(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(rest) min"
        }
    }

    /// "9:00", the clock time of a meeting.
    static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mm"
        return formatter.string(from: date)
    }

    /// The line under a stop's name: "Fuel · 20 min", "Food", "Meet · at 9:00".
    static func detail(kind: PlannedStopKind, minutes: Int?, meetAt: Date?, timeZone: TimeZone = .current) -> String {
        var parts = [Self.kind(kind)]
        if kind == .meet {
            if let meetAt { parts.append("at \(clock(meetAt, timeZone: timeZone))") }
        } else if let minutes {
            parts.append(length(minutes: minutes))
        }
        return parts.joined(separator: " · ")
    }

    static func detail(_ stop: StopDraft, timeZone: TimeZone = .current) -> String {
        detail(kind: stop.kind, minutes: stop.minutes, meetAt: stop.meetAt, timeZone: timeZone)
    }

    /// "2 h 40", "2 h 05", "2 h", "45 min": drive time on the route card.
    static func drive(seconds: Double) -> String {
        let total = max(1, Int((seconds / 60).rounded()))
        let hours = total / 60
        let minutes = total % 60
        switch (hours, minutes) {
        case (0, _): return "\(minutes) min"
        case (_, 0): return "\(hours) h"
        default: return "\(hours) h \(String(format: "%02d", minutes))"
        }
    }

    /// "205 km · 2 h 40 + 35 min of stops", or "205 km · 2 h 25" when no stop has a length.
    static func total(distance: Double, driveSeconds: Double, stopMinutes: Int) -> String {
        var line = "\(RouteFormat.distance(distance)) · \(drive(seconds: driveSeconds))"
        if stopMinutes > 0 { line += " + \(length(minutes: stopMinutes)) of stops" }
        return line
    }

    /// "62 km": how far along the route a stop is.
    static func along(meters: Double) -> String { RouteFormat.distance(meters) }

    /// The next time the clock reads `hour:minute` after `now`: a meeting time picked as a time of day.
    static func nextTime(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date? {
        calendar.nextDate(
            after: now, matching: DateComponents(hour: hour, minute: minute), matchingPolicy: .nextTime)
    }
}
