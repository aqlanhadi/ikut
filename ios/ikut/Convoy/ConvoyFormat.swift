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
}
