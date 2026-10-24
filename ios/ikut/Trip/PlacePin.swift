import CoreLocation
import Foundation
import Observation

/// Coordinates typed or pasted into the search field: "3.139, 101.687", 3°08'20"N 101°41'13"E, or a Google or
/// Apple Maps link. Pure; anything out of range or without coordinates is not a match (a text search runs instead).
enum CoordinateParser {
    static func parse(_ text: String) -> CLLocationCoordinate2D? {
        let text = cleaned(text)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        if lower.hasPrefix("http") || lower.hasPrefix("maps.") || lower.hasPrefix("www.") || lower.hasPrefix("goo.gl") {
            return link(text)
        }
        return degreesMinutesSeconds(text) ?? decimal(text)
    }

    /// Without the brackets a pasted pair sits in, and the full stop or comma a sentence puts after it.
    private static func cleaned(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, "([{<".contains(first) { text.removeFirst() }
        while let last = text.last, ".,;:!?)]}>".contains(last) || last.isWhitespace { text.removeLast() }
        return text
    }

    private static let number = #"[+-]?\d{1,3}(?:\.\d+)?"#

    /// "3.139, 101.687", "3.139 101.687", "+3.139,-101.687". At least one number has a decimal point, so "3, 101"
    /// and "Jalan 2, 3" stay a text search; a space alone only separates two numbers with decimals.
    private static func decimal(_ text: String) -> CLLocationCoordinate2D? {
        guard let m = match(#"^(\#(number))\s*([,;]|\s)\s*(\#(number))$"#, in: text) else { return nil }
        guard m[1].contains(".") || m[3].contains(".") else { return nil }
        if m[2] != "," && m[2] != ";", !(m[1].contains(".") && m[3].contains(".")) { return nil }
        guard let lat = Double(m[1]), let lon = Double(m[3]) else { return nil }
        return coordinate(lat, lon)
    }

    /// 3°08'20"N 101°41'13"E, N 3°08'20" E 101°41'13", N3.139 E101.687: minutes and seconds optional, one hemisphere
    /// letter per part, before or after its number, either order.
    private static func degreesMinutesSeconds(_ text: String) -> CLLocationCoordinate2D? {
        let letter = #"([NSEWnsew])"#
        let number = #"(\d{1,3}(?:\.\d+)?)\s*°?\s*(?:(\d{1,2}(?:\.\d+)?)\s*['′’]\s*)?(?:(\d{1,2}(?:\.\d+)?)\s*(?:["″”]|''|′′)\s*)?"#
        // The letter's side is part of the pattern, so "N 3 E 101" is not read as "N 3 E" then a bare number.
        func part(leading: Bool) -> String { leading ? #"\#(letter)\s*\#(number)"# : #"\#(number)\#(letter)"# }
        var found: [String]?
        var lettersFirst = (false, false)
        for first in [false, true] {
            for second in [false, true] where found == nil {
                if let m = match(#"^\#(part(leading: first))\s*[,;]?\s*\#(part(leading: second))$"#, in: text) {
                    found = m
                    lettersFirst = (first, second)
                }
            }
        }
        guard let m = found else { return nil }
        // Groups per part: the letter and three numbers, in the order the part wrote them.
        func value(_ at: Int, leading: Bool) -> (Double, Character)? {
            let l = leading ? m[at] : m[at + 3]
            let n = leading ? at + 1 : at
            guard let degrees = Double(m[n]) else { return nil }
            let minutes = Double(m[n + 1]) ?? 0, seconds = Double(m[n + 2]) ?? 0
            guard minutes < 60, seconds < 60, let hemisphere = l.uppercased().first else { return nil }
            let sign: Double = "SW".contains(hemisphere) ? -1 : 1
            return (sign * (degrees + minutes / 60 + seconds / 3600), hemisphere)
        }
        guard let a = value(1, leading: lettersFirst.0), let b = value(5, leading: lettersFirst.1) else { return nil }
        switch ("NS".contains(a.1), "NS".contains(b.1)) {
        case (true, false): return coordinate(a.0, b.0)
        case (false, true): return coordinate(b.0, a.0)
        default: return nil
        }
    }

    /// The place a maps link points at: `ll`, `q` (when it holds coordinates), `query`, `destination`, `daddr` and
    /// Apple's `coordinate`, else Google's `!3d…!4d…` (the place), else `@lat,long`. `sll` and `center` are where the
    /// map was looking, never the place; `address=` and a `q=` that is a name are not coordinates.
    private static func link(_ text: String) -> CLLocationCoordinate2D? {
        let withScheme = text.lowercased().hasPrefix("http") ? text : "https://" + text
        if let items = URLComponents(string: withScheme)?.queryItems {
            for key in ["ll", "q", "query", "destination", "daddr", "coordinate"] {
                for item in items where item.name == key {
                    if let value = item.value, let found = decimal(value.trimmingCharacters(in: .whitespaces)) { return found }
                }
            }
        }
        if let m = match(#"!3d(-?\d{1,3}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)"#, in: text), let lat = Double(m[1]), let lon = Double(m[2]) {
            return coordinate(lat, lon)
        }
        if let m = match(#"@(\#(number)),(\#(number))"#, in: text), let lat = Double(m[1]), let lon = Double(m[2]) {
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

    /// Asks for the name of `c` after `delay` of quiet; a newer spot cancels this one, so a burst of typing asks once.
    func start(_ c: CLLocationCoordinate2D, after delay: Duration = .zero) {
        task?.cancel()
        generation += 1
        let mine = generation
        coordinate = c
        found = nil
        isNaming = true
        task = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, mine == generation else { return }
            }
            await resolve(c, generation: mine)
        }
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
        coordinate = c
        found = nil
        isNaming = true
        await resolve(c, generation: generation)
    }

    private func resolve(_ c: CLLocationCoordinate2D, generation mine: Int) async {
        let answer = await geocoder.lookup(c)
        guard mine == generation else { return }
        found = answer
        isNaming = false
    }
}
