import Foundation

/// One suggested break: the R&R, how far into the drive it is, the mark it answers and one line of why. Port of
/// `suggestStops` in `tools/osm/places.mjs`.
struct StopSuggestion: Sendable, Identifiable {
    var place: PlaceAlong
    /// Seconds of driving to the place's `routeOffset`.
    var at: Double
    /// The mark (2 h, 4 h...) it answers.
    var target: Double
    /// "110 min along · fuel, food, toilets".
    var why: String
    var id: String { place.id }
}

enum SuggestStops {
    /// OSM tags some lay-bys `services` (Tanjung Malim, Bikam: a pump and a stall); their names give them away.
    /// "Hentian sebelah" is Malay for lay-by.
    private static let layby = "lay-?by|hentian sebelah"

    /// The app's stop kind for a place, by the most pressing thing it has: fuel, then food, toilets, else rest.
    static func stopKind(_ place: PlaceAlong) -> PlannedStopKind {
        if place.facilities.contains(.fuel) { return .fuel }
        if place.facilities.contains(.food) { return .food }
        if place.facilities.contains(.toilets) { return .toilet }
        return .rest
    }

    /// An R&R good enough to suggest on its own: services with fuel (and so food and toilets), not a lay-by or a
    /// lone pump.
    static func isRnR(_ place: PlaceAlong) -> Bool {
        place.kind == .services && place.facilities.contains(.fuel)
            && place.name?.range(of: layby, options: [.regularExpression, .caseInsensitive]) == nil
    }

    /// "fuel, food, toilets, EV charging": what a place has, in that order.
    static func facilityWords(_ place: PlaceAlong) -> String {
        let f = place.facilities
        return [f.contains(.fuel) ? "fuel" : nil, f.contains(.food) ? "food" : nil,
                f.contains(.toilets) ? "toilets" : nil, f.contains(.ev) ? "EV charging" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func score(_ place: PlaceAlong) -> Int {
        (place.facilities.contains(.ev) ? 2 : 0) + (place.facilities.contains(.toilets) ? 1 : 0)
    }

    /// "Suggest stops" in the lobby: about every `every` seconds of driving, the R&R on our carriageway nearest that
    /// time, within `window` either side; none in the last `minFromEnd` of the trip. A trip with no such time but
    /// at least `halfwayFrom` long gets one stop near halfway instead, so KL to Ipoh (2 h 24 min) still gets a
    /// break. Time along the route is `routeSeconds` spread evenly over its length, as the app's ETAs do.
    /// `existing` are the route offsets of stops the organizer already has: one near a mark counts as its break.
    /// Returns the picks in route order.
    static func suggest(
        candidates: [PlaceAlong], routeLength: Double, routeSeconds: Double,
        every: Double = PlaceRules.every, window: Double = PlaceRules.window,
        minFromEnd: Double = PlaceRules.minFromEnd, halfwayFrom: Double = PlaceRules.halfwayFrom,
        existing: [Double] = []
    ) -> [StopSuggestion] {
        guard routeLength > 0, routeSeconds > 0 else { return [] }
        func time(_ offset: Double) -> Double { offset / routeLength * routeSeconds }
        let pool = candidates.filter { $0.ours && isRnR($0) }
        var targets: [(target: Double, window: Double)] = []
        var t = every
        while t <= routeSeconds - minFromEnd { targets.append((t, window)); t += every }
        // Too short for a break every 2 h, long enough to want one: one stop near halfway, anywhere in the middle
        // half of the trip.
        if targets.isEmpty && routeSeconds >= halfwayFrom { targets.append((routeSeconds / 2, routeSeconds / 4)) }
        var picks: [StopSuggestion] = []
        var last = 0.0
        for (target, window) in targets {
            if existing.contains(where: { abs(time($0) - target) <= window }) { continue }
            let near = pool
                .map { (place: $0, at: time($0.routeOffset)) }
                .filter { abs($0.at - target) <= window && $0.at > last && $0.at <= routeSeconds - minFromEnd }
            // Nearest the target; a tie (within `tie`) goes to the one with more for everyone (EV, then toilets).
            guard let best = near.min(by: { a, b in
                let d = abs(a.at - target) - abs(b.at - target)
                if abs(d) > PlaceRules.tie { return d < 0 }
                let s = score(b.place) - score(a.place)
                return s != 0 ? s < 0 : d < 0
            }) else { continue }
            last = best.at
            picks.append(StopSuggestion(
                place: best.place, at: best.at, target: target,
                why: "\(Int((best.at / 60).rounded())) min along · \(facilityWords(best.place))"))
        }
        return picks
    }
}
