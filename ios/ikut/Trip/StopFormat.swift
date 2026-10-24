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
        minutes >= 1 ? ConvoyFormat.duration(TimeInterval(minutes) * 60) : "\(minutes) min"
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

    /// "205 km · 2 h 40 min + 35 min of stops", or "205 km · 2 h 25 min" when no stop has a length.
    static func total(distance: Double, driveSeconds: Double, stopMinutes: Int) -> String {
        var line = "\(RouteFormat.distance(distance)) · \(ConvoyFormat.duration(driveSeconds))"
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

/// The words of the notes under a stop and under the list (LobbyStops.dc.html and what it doesn't draw).
enum StopNoteText {
    /// Stops on a highway's rest area: fuel, rest and toilet. A meal or a sight is somewhere else, so it is "this stop".
    static func isRestArea(_ kind: PlannedStopKind) -> Bool { [.fuel, .rest, .toilet].contains(kind) }

    static func turnBack(kind: PlannedStopKind, extraMeters: Double) -> (title: String, detail: String) {
        let km = max(1, Int((extraMeters / 1000).rounded()))
        if isRestArea(kind) {
            return ("This R&R is on the other side of the highway",
                    "The route turns back at the next exit, about \(km) km extra. Pick another stop, or leave it.")
        }
        return ("This stop is across the road", "The route turns back at the next exit, about \(km) km extra.")
    }

    static func failureTitle(_ failure: StopPlanner.Failure, stopName: String?, destinationName: String) -> String {
        switch failure.place {
        case .stop: "Couldn’t find a road to \(stopName ?? "this stop")"
        case .destination: "Couldn’t find a road to \(destinationName)"
        case .start: "Can’t find where you are"
        case .saving: "Couldn’t save the stops"
        }
    }

    static func failureDetail(_ failure: StopPlanner.Failure) -> String {
        switch (failure.place, failure.reason) {
        case (.start, _): return "Check that location is on, then try again."
        case (.saving, _): return "The change wasn’t accepted. Try again in a moment."
        case (.stop, .noRoute): return "There’s no road to this stop from the one before. Pick another place."
        case (.destination, .noRoute): return "There’s no road to the destination from the stop before. Pick another place."
        default: return "Maps didn’t answer. Try again, or pick another place."
        }
    }

    /// An edit that is queued because there is no connection: it saves by itself later.
    static let queuedTitle = "Not saved yet"
    static let queuedDetail = "It saves when you’re back online."
}
