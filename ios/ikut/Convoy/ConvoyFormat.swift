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

    /// Km/h, whole number ("96 km/h").
    static func speed(metersPerSecond: Double) -> String {
        "\(Int((max(0, metersPerSecond.isFinite ? metersPerSecond : 0) * 3.6).rounded())) km/h"
    }

    /// The viewer's own car, wherever the convoy names cars.
    static let me = "Me"

    /// A car that reached the destination.
    static let arrived = "Arrived"

    /// The panel's status pill: "Everyone's arrived" once all cars are in, "Arrived" once mine is,
    /// nil otherwise (the caller shows motion).
    static func arrivalStatus(mineArrived: Bool, everyoneArrived: Bool) -> String? {
        if everyoneArrived { return "Everyone\u{2019}s arrived" }
        return mineArrived ? arrived : nil
    }

    /// The "to go" line under the progress bar: "Arrived" once I'm in, else "63 km · 41 min to go",
    /// or just the distance without an ETA.
    static func toGo(remaining: Double, travelTime: TimeInterval?, arrived: Bool) -> String {
        if arrived { return Self.arrived }
        guard let travelTime else { return "\(distance(remaining)) to go" }
        return "\(distance(remaining)) · \(duration(travelTime)) to go"
    }

    /// Subtitle of a car whose tracker paused sharing.
    static let paused = "Paused"

    /// "Last seen 2 min ago" for a stale position `age` seconds old. Under a minute is "just now".
    static func lastSeen(age: TimeInterval) -> String {
        let a = max(0, age.isFinite ? age : 0)
        if a < 60 { return "Last seen just now" }
        if a < 3600 { return "Last seen \(Int(a / 60)) min ago" }
        if a < 86_400 { return "Last seen \(Int(a / 3600)) h ago" }
        return "Last seen \(Int(a / 86_400)) d ago"
    }

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

    /// "Arriving 4:35 PM".
    static func arriving(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Arriving \(clock(date, locale: locale, timeZone: timeZone))"
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

    /// The collapsed panel's summary parts: "3 cars driving", "Hafiz joins in 18 min",
    /// "6.4 km spread". The joiner is named by the first word of the car name, without "'s".
    static func convoySummary(
        driving: Int, joinerName: String?, joinIn: TimeInterval?, spread: Double?
    ) -> (driving: String, joining: String?, spread: String?) {
        let drivingText = driving == 1 ? "1 car driving" : "\(driving) cars driving"
        var joining: String?
        if let joinerName, !joinerName.isEmpty {
            var owner = joinerName.split(separator: " ").first.map(String.init) ?? joinerName
            for suffix in ["\u{2019}s", "'s"] where owner.hasSuffix(suffix) { owner = String(owner.dropLast(2)) }
            joining = joinIn.map { "\(owner) joins in \(duration($0))" } ?? "\(owner) joining"
        }
        return (drivingText, joining, spread.map { "\(distance($0)) spread" })
    }
}
