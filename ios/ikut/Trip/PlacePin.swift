import CoreLocation
import Foundation
import Observation

/// Coordinates typed or pasted into the search field: "3.139, 101.687", 3°08'20"N 101°41'13"E, or a Google or
/// Apple Maps link. Pure; anything out of range or without coordinates is not a match (a text search runs instead).
enum CoordinateParser {
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("maps.") || lower.hasPrefix("www.") || lower.hasPrefix("goo.gl") {
            return link(text)
        }
        return degreesMinutesSeconds(text) ?? decimal(text)
    }

    private static let number = #"[+-]?\d{1,3}(?:\.\d+)?"#

    /// "3.139, 101.687", "3.139 101.687", "+3.139,-101.687". A space alone only separates numbers with decimals, so
    /// "12 34" stays a text search.
    private static func decimal(_ text: String) -> CLLocationCoordinate2D? {
        guard let m = match(#"^(\#(number))\s*([,;]|\s)\s*(\#(number))$"#, in: text) else { return nil }
        if m[2] != "," && m[2] != ";", !(m[1].contains(".") && m[3].contains(".")) { return nil }
        guard let lat = Double(m[1]), let lon = Double(m[3]) else { return nil }
        return coordinate(lat, lon)
    }

    /// 3°08'20"N 101°41'13"E; minutes and seconds optional, hemisphere letters required, either order.
    private static func degreesMinutesSeconds(_ text: String) -> CLLocationCoordinate2D? {
        let part = #"(\d{1,3}(?:\.\d+)?)\s*°?\s*(?:(\d{1,2}(?:\.\d+)?)\s*['′’]\s*)?(?:(\d{1,2}(?:\.\d+)?)\s*(?:["″”]|''|′′)\s*)?([NSEWnsew])"#
        guard let m = match(#"^\#(part)\s*[,;]?\s*\#(part)$"#, in: text) else { return nil }
        func value(_ at: Int) -> (Double, Character)? {
            guard let degrees = Double(m[at]) else { return nil }
            let minutes = Double(m[at + 1]) ?? 0, seconds = Double(m[at + 2]) ?? 0
            guard minutes < 60, seconds < 60, let hemisphere = m[at + 3].uppercased().first else { return nil }
            let sign: Double = "SW".contains(hemisphere) ? -1 : 1
            return (sign * (degrees + minutes / 60 + seconds / 3600), hemisphere)
        }
        guard let a = value(1), let b = value(5) else { return nil }
        switch ("NS".contains(a.1), "NS".contains(b.1)) {
        case (true, false): return coordinate(a.0, b.0)
        case (false, true): return coordinate(b.0, a.0)
        default: return nil
        }
    }

    /// Google Maps (`@lat,long`, `q=`, `ll=`, `!3d…!4d…`) and Apple Maps (`ll=`, `q=` or `sll=` with coordinates).
    /// `address=` and a `q=` that is a name are not coordinates.
    private static func link(_ text: String) -> CLLocationCoordinate2D? {
        let withScheme = text.lowercased().hasPrefix("http") ? text : "https://" + text
        if let items = URLComponents(string: withScheme)?.queryItems {
            for key in ["ll", "q", "query", "sll", "center", "destination", "daddr"] {
                for item in items where item.name == key {
                    if let value = item.value, let found = decimal(value.trimmingCharacters(in: .whitespaces)) { return found }
                }
            }
        }
        if let m = match(#"@(\#(number)),(\#(number))"#, in: text), let lat = Double(m[1]), let lon = Double(m[2]) {
            return coordinate(lat, lon)
        }
        if let m = match(#"!3d(-?\d{1,3}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)"#, in: text), let lat = Double(m[1]), let lon = Double(m[2]) {
            return coordinate(lat, lon)
        }
        return nil
    }

    private static func match(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<found.numberOfRanges).map { index in
            Range(found.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    private static func coordinate(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D? {
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// What a reverse geocode found at a spot.
struct GeocodedName: Equatable, Sendable {
    var name: String?
    var locality: String?
}

/// Reverse geocoding, behind a protocol so tests feed answers. nil when offline or nothing is there.
@MainActor
protocol ReverseGeocoding {
    func lookup(_ coordinate: CLLocationCoordinate2D) async -> GeocodedName?
}

struct CLReverseGeocoder: ReverseGeocoding {
    func lookup(_ coordinate: CLLocationCoordinate2D) async -> GeocodedName? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        return GeocodedName(
            name: placemark.areasOfInterest?.first ?? placemark.name,
            locality: placemark.locality ?? placemark.subLocality ?? placemark.subAdministrativeArea)
    }
}

enum PinName {
    /// "3.139, 101.687".
    static func coordinates(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.3f, %.3f", c.latitude, c.longitude)
    }

    /// The place's name, else "Near <locality>", else the coordinates. Never blank.
    static func title(_ found: GeocodedName?, at c: CLLocationCoordinate2D) -> String {
        if let name = found?.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let town = found?.locality?.trimmingCharacters(in: .whitespacesAndNewlines), !town.isEmpty { return "Near \(town)" }
        return coordinates(c)
    }

    /// The pin as a place to pick, named as above.
    static func place(_ found: GeocodedName?, at c: CLLocationCoordinate2D) -> DestinationResult {
        DestinationResult(name: title(found, at: c), subtitle: coordinates(c), coordinate: c)
    }
}

/// Names one spot at a time: a pasted pin, or where the map came to rest. Only the newest spot's answer is kept.
@Observable @MainActor
final class PinNamer {
    private(set) var coordinate: CLLocationCoordinate2D?
    /// Nil until the geocode answers (or when it found nothing).
    private(set) var found: GeocodedName?
    private(set) var isNaming = false

    @ObservationIgnored private let geocoder: ReverseGeocoding
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(geocoder: ReverseGeocoding = CLReverseGeocoder()) { self.geocoder = geocoder }

    /// What the pin is called now: the geocoded name once it answers, the coordinates before.
    var place: DestinationResult? { coordinate.map { PinName.place(found, at: $0) } }

    func start(_ c: CLLocationCoordinate2D) {
        task?.cancel()
        coordinate = c
        found = nil
        isNaming = true
        task = Task { await lookup(c) }
    }

    #if DEBUG
    func setForDemo(_ c: CLLocationCoordinate2D?, _ found: GeocodedName?) {
        coordinate = c
        self.found = found
    }
    #endif

    func clear() {
        task?.cancel()
        generation += 1
        coordinate = nil
        found = nil
        isNaming = false
    }

    /// One geocode for `c`; an answer that arrives after a newer spot was asked for is dropped.
    func lookup(_ c: CLLocationCoordinate2D) async {
        generation += 1
        let mine = generation
        coordinate = c
        found = nil
        isNaming = true
        let answer = await geocoder.lookup(c)
        guard mine == generation else { return }
        found = answer
        isNaming = false
    }
}
