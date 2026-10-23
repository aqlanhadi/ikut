import Foundation

/// One announcement: what the banner shows, what the notification says and what is read aloud.
struct TripAlert: Sendable, Equatable, Identifiable {
    /// Unique per announcement: the event id, plus `@approach` for an approach alert.
    let id: String
    let eventId: String
    let tripId: String
    let type: EventType
    let category: EventCategory
    let severity: Severity
    /// Meters ahead, for approach alerts; nil when the alert is for an event that just arrived.
    let distance: Double?
    let title: String
    let body: String
    let spoken: String
    /// What the alert is about: a trip event, or a car coming up behind mine.
    var kind: Kind = .event

    enum Kind: Sendable, Equatable {
        case event
        /// "Aisha’s car is 3.3 km behind you" (D26), on the phones of a car parked ahead, about 2 minutes
        /// before the nearest car behind reaches it. `eventId` is then that car's id. Shown as its own
        /// pill (`CatchUpPill`), never as a banner.
        case catchUp
    }
}

/// All the alert copy in one place. Pure, so it is easy to test.
enum AlertWording {
    /// Name used when the reporter's name is unknown.
    static let unknownCar = "another car"

    /// `far` is how far the asking car is from mine when over 2 km ("40 km behind"), for a stop request.
    static func alert(
        for event: TripEvent, tripId: String, distance: Double? = nil, authorName: String?,
        far: String? = nil, now: Date
    ) -> TripAlert {
        let car = carPhrase(authorName)
        let ago = relativeTime(since: event.createdAt, now: now)
        let id = alertId(eventId: event.id ?? "", approach: distance != nil)
        let lead = line(for: event, car: car)
        let farPart = event.category == .stopRequest ? far : nil
        return TripAlert(
            id: id, eventId: event.id ?? "", tripId: tripId, type: event.type, category: event.category,
            severity: event.severity, distance: distance,
            title: title(for: event, distance: distance),
            body: ([lead, farPart, ago].compactMap { $0 }).joined(separator: " · "),
            spoken: spoken(for: event, car: car, distance: distance, authorName: authorName, far: farPart))
    }

    /// "Wyna needs fuel. Tap OK.", or "Wyna needs fuel, 40 km behind. Tap OK." when the car is over 2 km
    /// away. Only the reason is spoken, never the message a passenger typed, and no place (there is
    /// none). Voice answers are not built yet, so it never says "say OK".
    static func spokenStopRequest(for type: EventType, authorName: String?, far: String? = nil) -> String {
        let trimmed = authorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = trimmed.isEmpty ? "Another car" : trimmed
        let need = StopRequestState.need(for: type)
        return "\(who) \(need)\(far.map { ", \($0)" } ?? ""). Tap OK."
    }

    /// Spoken "Aisha’s car is 3.3 km behind you."; the pill and the notification read "Aisha’s car is
    /// behind you" over "3.3 km · about 2 min away". Once per car per trip.
    static func catchUp(tripId: String, myCarId: String, due: CatchUpHeadsUp.Due) -> TripAlert {
        let distance = distanceText(due.distance)
        return TripAlert(
            id: due.stop == 1 ? "\(myCarId)@catchup" : "\(myCarId)@catchup\(due.stop)", eventId: due.carId, tripId: tripId, type: .other("catchUp"),
            category: .status, severity: .medium, distance: due.distance,
            title: "\(due.carPhrase) is behind you",
            body: "\(distance) · about \(ConvoyFormat.duration(due.seconds)) away",
            spoken: "\(due.carPhrase) is \(distance) behind you.", kind: .catchUp)
    }

    static func alertId(eventId: String, approach: Bool) -> String {
        approach ? "\(eventId)@approach" : eventId
    }

    /// "Aqlan’s car", or "another car".
    static func carPhrase(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? unknownCar : "\(trimmed)’s car"
    }

    /// "just now", "6 min ago", "2 hr ago". Unknown or future times read as "just now".
    static func relativeTime(since date: Date?, now: Date) -> String {
        guard let date else { return "just now" }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60) hr ago"
    }

    /// Short name of what was reported, e.g. "Debris".
    static func label(for type: EventType) -> String {
        switch type {
        case .debris: "Debris"
        case .accident: "Accident"
        case .pothole: "Pothole"
        case .animal: "Animal on the road"
        case .stoppedVehicle: "Stopped vehicle"
        case .roadworks: "Roadworks"
        case .heavyRain: "Heavy rain"
        case .trafficJam: "Traffic jam"
        case .stopRest, .stopFuel, .stopFood, .stopToilet: "Stop request"
        case .pullingOver: "Pulling over"
        case .carTrouble: "Car trouble"
        case .runningLate: "Running late"
        case .message, .other: "Message"
        }
    }

    /// Distance as spoken and shown: rounded to 50 m below a kilometre, "1.2 km" above.
    static func distanceText(_ meters: Double) -> String {
        if meters >= 1_000 {
            let km = (meters / 100).rounded() / 10
            return km == km.rounded() ? "\(Int(km)) km" : "\(km) km"
        }
        let rounded = max(50, Int((meters / 50).rounded()) * 50)
        return "\(rounded) meters"
    }

    // MARK: Pieces

    private static func title(for event: TripEvent, distance: Double?) -> String {
        switch event.category {
        case .hazard, .condition:
            if let distance { return "\(label(for: event.type)) ahead in \(distanceText(distance))" }
            return "\(label(for: event.type)) reported"
        case .stopRequest: return "Stop request"
        case .status: return "Convoy update"
        case .message: return "New message"
        }
    }

    /// The sentence naming the event and who sent it, without the time.
    private static func line(for event: TripEvent, car: String) -> String {
        switch event.category {
        case .hazard, .condition:
            return "\(label(for: event.type)) reported by \(car)"
        case .stopRequest, .status:
            return "\(capitalized(car)) \(statement(for: event.type))"
        case .message:
            if let text = event.message { return "\(capitalized(car)): “\(text)”" }
            return "Message from \(car)"
        }
    }

    private static func spoken(
        for event: TripEvent, car: String, distance: Double?, authorName: String?, far: String?
    ) -> String {
        switch event.category {
        case .hazard, .condition:
            let what = label(for: event.type)
            if let distance { return "\(what) ahead in \(distanceText(distance)), reported by \(car)." }
            return "\(what) reported by \(car)."
        case .stopRequest:
            return spokenStopRequest(for: event.type, authorName: authorName, far: far)
        case .status:
            return "\(capitalized(car)) \(statement(for: event.type))."
        case .message:
            if let text = event.message { return "Message from \(car): \(text)" }
            return "Message from \(car)."
        }
    }

    private static func statement(for type: EventType) -> String {
        switch type {
        case .stopRest: "wants a rest stop"
        case .stopFuel: "wants to stop for fuel"
        case .stopFood: "wants to stop for food"
        case .stopToilet: "needs a toilet break"
        case .pullingOver: "is pulling over"
        case .carTrouble: "has car trouble"
        case .runningLate: "is running late"
        default: "sent an update"
        }
    }

    private static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
