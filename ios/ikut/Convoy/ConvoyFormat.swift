import Foundation

/// Display strings for the convoy list, following design/project/Map.dc.html:
/// "1.8 km" over "1 min behind", "Last seen 2 min ago", "18 min" over "to merge", "ETA 14:52".
/// Pure; the clock format takes a locale and time zone so tests don't depend on the device.
enum ConvoyFormat {
    /// Under 1 km: nearest 10 m ("850 m"). 1 to 10 km: one decimal ("1.8 km"). Beyond: whole km ("84 km").
    static func distance(_ meters: Double) -> String {
        let m = max(0, meters.isFinite ? meters : 0)
        if m < 1000 { return "\(Int((m / 10).rounded()) * 10) m" }
        let km = m / 1000
        if km < 10 {
            let tenths = (km * 10).rounded() / 10
            // 999.6 m rounds to 1000 m above; keep "1.0 km" consistent.
            return String(format: "%.1f km", tenths)
        }
        return "\(Int(km.rounded())) km"
    }

    /// Whole minutes, at least 1 ("3 min"); an hour or more reads "1 h 5 min" or "2 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(0, seconds.isFinite ? seconds : 0) / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// "1 min behind".
    static func behind(_ seconds: TimeInterval) -> String { "\(duration(seconds)) behind" }

    /// "38 km ahead" or "40 km behind" for a car `meters` along the route from mine (positive: ahead),
    /// nil when it is `beyond` meters (2 km) or closer: then the words stay as they were.
    static func relativeDistance(_ meters: Double, beyond: Double = 2000) -> String? {
        guard meters.isFinite, abs(meters) > beyond else { return nil }
        return "\(distance(abs(meters))) \(meters > 0 ? "ahead" : "behind")"
    }

    /// Km/h, whole number ("96 km/h").
    static func speed(metersPerSecond: Double) -> String {
        "\(Int((max(0, metersPerSecond.isFinite ? metersPerSecond : 0) * 3.6).rounded())) km/h"
    }

    /// A car that reached the destination.
    static let arrived = "Arrived"

    /// The "to go" line under the progress bar: "Arrived" once I'm in, else "63 km · 41 min to go",
    /// or just the distance without an ETA.
    static func toGo(remaining: Double, travelTime: TimeInterval?, arrived: Bool) -> String {
        if arrived { return Self.arrived }
        guard let travelTime else { return "\(distance(remaining)) to go" }
        return "\(distance(remaining)) · \(duration(travelTime)) to go"
    }

    /// Subtitle of a car whose tracker paused sharing.
    static let paused = "Paused"

    /// "just now", "2 min ago", "3 h ago", "2 d ago" for something `age` seconds old. Under a minute is "just now".
    /// `hourUnit` is how hours read ("h" here, "hr" in an alert's words); `days: false` keeps counting in hours.
    static func ago(_ age: TimeInterval, hourUnit: String = "h", days: Bool = true) -> String {
        let a = max(0, age.isFinite ? age : 0)
        if a < 60 { return "just now" }
        if a < 3600 { return "\(Int(a / 60)) min ago" }
        if a < 86_400 || !days { return "\(Int(a / 3600)) \(hourUnit) ago" }
        return "\(Int(a / 86_400)) d ago"
    }

    /// "Last seen 2 min ago" for a stale position `age` seconds old. Under a minute is "just now".
    static func lastSeen(age: TimeInterval) -> String { "Last seen \(ago(age))" }

    /// Short clock time in the given locale ("14:52" in en_GB, "2:52 PM" in en_US).
    static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "ETA 14:52", with the destination name when known: "ETA Ipoh 14:52".
    static func eta(_ date: Date, destination: String? = nil, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let time = clock(date, locale: locale, timeZone: timeZone)
        guard let destination, !destination.isEmpty else { return "ETA \(time)" }
        return "ETA \(destination) \(time)"
    }

    // MARK: Place short names

    /// Well-known short forms of place names ("Kuala Lumpur" -> "KL"). There is no universal source
    /// for these, so this is a small curated table, Malaysia first. Keys are lowercased.
    static let placeShortForms: [String: String] = [
        "kuala lumpur": "KL",
        "petaling jaya": "PJ",
        "johor bahru": "JB",
        "kota kinabalu": "KK",
        "kota bharu": "KB",
        "new york": "NYC",
        "new york city": "NYC",
        "los angeles": "LA",
        "san francisco": "SF",
        "washington": "DC",
        "washington, d.c.": "DC",
        "washington d.c.": "DC",
    ]

    /// The display form of a place name: its well-known short form, else the name unchanged.
    /// Display only; stored names are never changed.
    static func placeShortName(_ name: String) -> String {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return placeShortForms[key] ?? name
    }

    /// How far a joining car is from the convoy, in the unit that is honest: time while it moves, distance under
    /// the speed floor (a parked car's "2 h" is the floor talking, not the car).
    enum JoinAmount: Equatable {
        case time(TimeInterval)
        case distance(Double)

        /// "20 min", "14 km".
        var text: String {
            switch self {
            case .time(let t): return ConvoyFormat.duration(t)
            case .distance(let d): return ConvoyFormat.distance(d)
            }
        }

        /// "20 minutes", "14 km": for VoiceOver.
        var spoken: String {
            switch self {
            case .distance(let d): return ConvoyFormat.distance(d)
            case .time(let t):
                let minutes = max(1, Int((max(0, t.isFinite ? t : 0) / 60).rounded()))
                guard minutes >= 60 else { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
                let h = minutes / 60, m = minutes % 60
                let hours = h == 1 ? "1 hour" : "\(h) hours"
                return m == 0 ? hours : "\(hours) \(m) minutes"
            }
        }
    }

    /// Nil without an estimate. `speed` and `parkedSpeed` in m/s: under the floor it is the distance.
    static func joinAmount(timeToMerge: TimeInterval?, distanceToMerge: Double?, speed: Double, parkedSpeed: Double) -> JoinAmount? {
        guard let timeToMerge else { return nil }
        if speed < parkedSpeed, let distanceToMerge { return .distance(distanceToMerge) }
        return .time(timeToMerge)
    }

    /// The collapsed panel's summary parts: "3 cars driving", "Hafiz joins in 18 min",
    /// "6.4 km spread". The joiner is named by the first word of the car name, without "'s".
    /// When the joiner is my own car it reads in the second person: "You join in 18 min", "You're joining".
    /// `joinAmount`, when given, replaces `joinIn`: a slow car says how far, not how long ("You join in 14 km").
    static func convoySummary(
        driving: Int, joinerName: String?, joinIn: TimeInterval?, spread: Double?, joinerIsMe: Bool = false,
        joinAmount: JoinAmount? = nil
    ) -> (driving: String, joining: String?, spread: String?) {
        let joinText = joinAmount?.text ?? joinIn.map(duration)
        let drivingText = driving == 1 ? "1 car driving" : "\(driving) cars driving"
        var joining: String?
        if joinerIsMe {
            joining = joinText.map { "You join in \($0)" } ?? "You\u{2019}re joining"
        } else if let joinerName, !joinerName.isEmpty {
            var owner = joinerName.split(separator: " ").first.map(String.init) ?? joinerName
            for suffix in ["\u{2019}s", "'s"] where owner.hasSuffix(suffix) { owner = String(owner.dropLast(2)) }
            joining = joinText.map { "\(owner) joins in \($0)" } ?? "\(owner) joining"
        }
        return (drivingText, joining, spread.map { "\(distance($0)) spread" })
    }

    // MARK: Trip pill

    /// The convoy's motion, shown first in the trip pill at the top of the map.
    enum Motion: Equatable {
        case everyoneArrived, arrived, moving, stopped, waiting

        var text: String {
            switch self {
            case .everyoneArrived: "Everyone\u{2019}s arrived"
            case .arrived: ConvoyFormat.arrived
            case .moving: "On the move"
            case .stopped: "Stopped"
            case .waiting: "Waiting"
            }
        }

        /// Green once moving or in; amber while stopped or waiting.
        var isPositive: Bool {
            switch self {
            case .everyoneArrived, .arrived, .moving: true
            case .stopped, .waiting: false
            }
        }
    }

    /// "Everyone's arrived" / "Arrived" once the cars (or mine) are in; else "On the move" while the
    /// front car goes faster than 3 m/s, "Stopped" once it doesn't, "Waiting" with no cars.
    static func motion(mineArrived: Bool, everyoneArrived: Bool, frontSpeed: Double?) -> Motion {
        if everyoneArrived { return .everyoneArrived }
        if mineArrived { return .arrived }
        guard let frontSpeed else { return .waiting }
        return frontSpeed > 3 ? .moving : .stopped
    }

    /// The trip pill's own sharing state: "Trip ended", "Sharing paused", "Sharing location" or
    /// "Not sharing location".
    static func sharingStatus(ended: Bool, paused: Bool, sharing: Bool) -> String {
        if ended { return "Trip ended" }
        if paused { return "Sharing paused" }
        return sharing ? "Sharing location" : "Not sharing location"
    }

    /// The trip pill's subtitle parts, joined with " · ": the convoy's motion (left out once the trip
    /// ended), the sharing state, then the join code when `withCode` and known:
    /// "On the move · Sharing location · Code K7M 2QX".
    static func tripPillParts(
        motion: Motion?, ended: Bool, paused: Bool, sharing: Bool, code: String, withCode: Bool = true
    ) -> [String] {
        var parts: [String] = []
        if !ended, let motion { parts.append(motion.text) }
        parts.append(sharingStatus(ended: ended, paused: paused, sharing: sharing))
        if withCode, !code.isEmpty { parts.append("Code \(code)") }
        return parts
    }
}
