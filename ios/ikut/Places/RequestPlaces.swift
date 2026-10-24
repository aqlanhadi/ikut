import Foundation

/// What a stop request asked for. Port of the reasons in `tools/osm/places.mjs` (`REASON_WINDOW`, `NEEDS`).
enum RequestNeed: Sendable, Hashable {
    case toilet, fuel, food, rest

    init?(_ type: EventType) {
        switch type {
        case .stopToilet: self = .toilet
        case .stopFuel: self = .fuel
        case .stopFood: self = .food
        case .stopRest: self = .rest
        default: return nil
        }
    }

    /// How soon the need wants a stop, in seconds of driving from the front car. Toilet is urgent, food can wait.
    var window: Double {
        switch self {
        case .toilet: 20 * 60
        case .fuel: 40 * 60
        case .rest: 45 * 60
        case .food: 60 * 60
        }
    }

    /// The facility a place must have to serve it; a rest needs only parking.
    var facility: PlaceFacility? {
        switch self {
        case .toilet: .toilets
        case .fuel: .fuel
        case .food: .food
        case .rest: nil
        }
    }

    private var word: String? {
        switch self {
        case .toilet: "toilets"
        case .fuel: "fuel"
        case .food: "food"
        case .rest: nil
        }
    }

    fileprivate static func words(_ needs: [RequestNeed]) -> [String] {
        var seen: [String] = []
        for word in needs.compactMap(\.word) where !seen.contains(word) { seen.append(word) }
        return seen
    }
}

/// One place on a stop request card: the rows read "R&R Tapah", "18 km ahead · about 12 min", "Fuel, toilets, food".
struct RequestPlace: Sendable, Identifiable, Equatable {
    var id: String
    var name: String
    var minutes: Int
    /// "18 km ahead · about 12 min".
    var whereText: String
    /// "Toilets, no fuel", ready to show.
    var whyText: String

    static func == (a: RequestPlace, b: RequestPlace) -> Bool { a.id == b.id && a.whereText == b.whereText && a.whyText == b.whyText }
}

/// Where the convoy's front is, and how fast it goes, for ranking places ahead of it.
struct RequestFront: Sendable, Equatable {
    /// Meters along the trip's route.
    var offset: Double
    /// Meters per second while it is really moving, else nil.
    var speed: Double?
    /// The trip's planned average (route length over `routeSeconds`), else nil.
    var plannedSpeed: Double?

    /// The front car's speed while moving, else the trip's planned average, else 90 km/h.
    var pace: Double {
        if let speed, speed > RequestFront.moving { return speed }
        if let plannedSpeed, plannedSpeed > 0 { return plannedSpeed }
        return PlaceRules.fallbackSpeed
    }

    /// About 18 km/h: slower than that the car is parked or crawling, and says nothing about the pace.
    static let moving: Double = 5
}

/// Places for a stop request: ahead of the front car on our carriageway, reachable within the most urgent open
/// reason's window, covering every open reason, nearest first. Port of `rankForRequest`, `requestWhere` and
/// `requestWhy` in `tools/osm/places.mjs`.
enum RequestPlaces {
    /// At most `max`, best first. `speed` is m/s; `fuelRange` (meters) replaces the fuel window when given.
    static func rank(
        _ candidates: [PlaceAlong], frontOffset: Double, reasons: [RequestNeed], speed: Double,
        fuelRange: Double? = nil, max: Int = PlaceRules.requestMax
    ) -> [(place: PlaceAlong, minutes: Int, whereText: String, why: String)] {
        guard !reasons.isEmpty, speed > 0 else { return [] }
        let limit = reasons.map { $0 == .fuel && fuelRange != nil ? fuelRange! / speed : $0.window }.min()!
        func covers(_ p: PlaceAlong) -> Bool { reasons.allSatisfy { $0.facility.map(p.facilities.contains) ?? true } }
        func cost(_ r: (place: PlaceAlong, secs: Double)) -> Double {
            r.secs + (SuggestStops.isRnR(r.place) ? 0 : PlaceRules.laybyPenalty)
        }
        let rows = candidates
            .filter { $0.ours && $0.routeOffset > frontOffset + PlaceRules.minAhead }
            .map { (place: $0, secs: ($0.routeOffset - frontOffset) / speed) }
            .filter { $0.secs <= limit }
            .sorted { a, b in
                let (ca, cb) = (covers(a.place), covers(b.place))
                return ca != cb ? ca : cost(a) < cost(b)
            }
        return rows.prefix(max).map { row in
            (row.place, Int((row.secs / 60).rounded()), requestWhere(row.place.routeOffset - frontOffset, row.secs),
             requestWhy(row.place, reasons))
        }
    }

    /// "18 km ahead · about 12 min", the RequestStop canvas's words for a place on the route ahead of the front.
    static func requestWhere(_ meters: Double, _ secs: Double) -> String {
        "\(Swift.max(1, Int((meters / 1000).rounded()))) km ahead · about \(Swift.max(1, Int((secs / 60).rounded()))) min"
    }

    /// "toilets" or "toilets, no fuel": what the place has and lacks of what was asked for ("parking" for a rest).
    static func requestWhy(_ place: PlaceAlong, _ reasons: [RequestNeed]) -> String {
        let asked = RequestNeed.words(reasons)
        func has(_ word: String) -> Bool {
            switch word {
            case "toilets": place.facilities.contains(.toilets)
            case "fuel": place.facilities.contains(.fuel)
            default: place.facilities.contains(.food)
            }
        }
        let have = asked.filter(has), lack = asked.filter { !has($0) }
        return [have.isEmpty ? (asked.isEmpty ? "parking" : "") : have.joined(separator: ", "),
                lack.isEmpty ? "" : "no \(lack.joined(separator: ", "))"]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// What the card shows for a place: its name, else "R&R", "Lay-by" or "Petrol station" by kind.
    static func name(_ place: PlaceAlong) -> String {
        if let name = place.name, !name.isEmpty { return name }
        switch place.kind {
        case .fuel: return "Petrol station"
        case .services: return SuggestStops.isRnR(place) ? "R&R" : "Lay-by"
        case .restArea: return "Lay-by"
        }
    }

    /// "Toilets, no fuel": the first letter up.
    static func display(_ words: String) -> String { words.prefix(1).uppercased() + words.dropFirst() }

    /// The list for the card: places on `route` ahead of `front`, for every open reason together.
    static func list(
        reasons: [RequestNeed], front: RequestFront, route: RouteLine,
        sites: [PlaceSite] = OurSide.bundledSites, fuel: [FuelStation] = OurSide.bundledFile?.fuel ?? []
    ) -> [RequestPlace] {
        guard !reasons.isEmpty, route.segmentCount > 0 else { return [] }
        let candidates = PlaceSide.along(sites: sites, fuel: fuel, line: route)
        return rank(candidates, frontOffset: front.offset, reasons: reasons, speed: front.pace).map {
            RequestPlace(
                id: $0.place.id, name: name($0.place), minutes: $0.minutes, whereText: $0.whereText,
                whyText: display($0.why))
        }
    }
}
