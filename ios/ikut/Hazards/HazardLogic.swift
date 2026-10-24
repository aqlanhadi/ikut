import CoreLocation
import Foundation
import SwiftUI

// MARK: Geometry

/// Where an event sits along a route.
enum HazardGeometry {
    /// Meters along `route` for the event's `location`, or nil when the event is more than
    /// `tolerance` meters from the route (another road, or the other carriageway).
    ///
    /// `TripEvent.routeOffset` is relative to the *reporter's* route, which may be their own joining
    /// route, so it must not be compared with offsets on another route. Always project the location.
    static func offset(of event: TripEvent, on route: RouteLine?, tolerance: CLLocationDistance) -> CLLocationDistance? {
        guard let route, let projection = route.project(coordinate(of: event)), projection.distance <= tolerance
        else { return nil }
        return projection.offset
    }

    static func coordinate(of event: TripEvent) -> CLLocationCoordinate2D {
        event.location.coordinate
    }

    static func key(for event: TripEvent) -> String {
        event.id ?? "\(event.location.latitude),\(event.location.longitude)"
    }

    static func isExpired(_ event: TripEvent, now: Date) -> Bool {
        event.expiresAt.map { $0 <= now } ?? false
    }

    /// Hazards and conditions get map markers and approach alerts. Stop requests have their own
    /// stop markers, and statuses and messages have no place on the road.
    static func isRoadEvent(_ event: TripEvent) -> Bool {
        event.category == .hazard || event.category == .condition
    }
}

/// Remembers event offsets so a fix every second doesn't re-project every event onto the route.
/// Events don't move, so an entry only goes stale when its route changes (`reset`).
struct HazardOffsetCache {
    private var main: [String: Double?] = [:]
    private var own: [String: [String: Double?]] = [:]

    mutating func mainOffset(of event: TripEvent, on route: RouteLine?, tolerance: CLLocationDistance) -> Double? {
        let key = HazardGeometry.key(for: event)
        if let cached = main[key] { return cached }
        let value = HazardGeometry.offset(of: event, on: route, tolerance: tolerance)
        main[key] = .some(value)
        return value
    }

    mutating func ownOffset(
        of event: TripEvent, carId: String, on route: RouteLine?, tolerance: CLLocationDistance
    ) -> Double? {
        let key = HazardGeometry.key(for: event)
        if let cached = own[carId]?[key] { return cached }
        let value = HazardGeometry.offset(of: event, on: route, tolerance: tolerance)
        own[carId, default: [:]][key] = .some(value)
        return value
    }

    /// Forget main-route offsets (the main route changed).
    mutating func resetMain() { main = [:] }

    /// Forget one car's own-route offsets (its route changed).
    mutating func resetOwn(carId: String) { own[carId] = nil }

    mutating func reset() {
        main = [:]
        own = [:]
    }
}

// MARK: Marker view-model

/// Colour family for a marker; the view maps it to a `Color`.
enum HazardTone: Sendable, Equatable {
    case high, medium, low

    init(_ severity: Severity) {
        switch severity {
        case .high: self = .high
        case .medium: self = .medium
        case .low: self = .low
        }
    }
}

/// What the map draws for one hazard: a symbol in a severity-coloured circle, plus a chip.
struct HazardMarker: Identifiable, Equatable, Sendable {
    var id: String
    var type: EventType
    var latitude: Double
    var longitude: Double
    var symbol: String
    /// "Debris".
    var label: String
    /// "4 min ago", or "just now".
    var ageText: String
    /// "Debris · 4 min ago", following Map.dc.html.
    var chipText: String
    var tone: HazardTone
    /// Meters along the main route; nil when the event is not on the main route.
    var mainOffset: Double?

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    var accessibilityLabel: String { "Hazard: \(chipText)" }

    static let fallbackSymbol = "exclamationmark.triangle.fill"

    /// Symbol and name come from the report sheet's options, so the map matches what was tapped.
    static func presentation(for type: EventType) -> (symbol: String, label: String) {
        if let option = ReportOption.all.first(where: { $0.type == type }) {
            return (option.symbol, option.label)
        }
        return (fallbackSymbol, AlertWording.label(for: type))
    }

    init(event: TripEvent, mainOffset: Double?, now: Date) {
        let (symbol, label) = Self.presentation(for: event.type)
        let age = AlertWording.relativeTime(since: event.createdAt, now: now)
        self.id = HazardGeometry.key(for: event)
        self.type = event.type
        self.latitude = event.location.latitude
        self.longitude = event.location.longitude
        self.symbol = symbol
        self.label = label
        self.ageText = age
        self.chipText = "\(label) · \(age)"
        self.tone = HazardTone(event.severity)
        self.mainOffset = mainOffset
    }
}

// MARK: Logic

/// Which hazards to show, and whether everyone has driven past them. Pure.
///
/// **Visible** means: a hazard or condition, not expired (`expiresAt > now`), and not passed by all.
///
/// **Passed by all.** An event is passed by all when at least one car has passed it and no car
/// still has to. Only cars with a fresh position (updated within `staleAfter`, 60 s; a position
/// whose server timestamp is still pending counts as fresh) take part. A stale car is ignored: it
/// may have dropped out, and one dead phone must not keep a hazard on everyone's map.
///
/// - A **convoy car** (position has a `convoyOffset`) has passed when `convoyOffset` is greater than
///   the event's main-route offset plus `passMargin` (100 m, so a car beside the hazard, or GPS
///   noise, does not count). Otherwise it still has to pass. If the event is not on the main route
///   (more than `lateralTolerance`, 50 m, from it) the car is not affected and is ignored.
/// - A **joining car** (position without `convoyOffset`) is judged on its own route first: if the
///   event lies on that route, it has passed when its `routeOffset` exceeds the event's own-route
///   offset plus the margin, else it still has to. If the event is not on its own route but is on
///   the main route, the car will reach it only if it merges before the event: `Car.mergeOffset`
///   below the event's main offset (or unknown, which is assumed) means it still has to pass;
///   a merge point at or beyond the event means the car never drives past it and is ignored.
/// - A car with no position is ignored.
///
/// With no relevant car at all nothing has passed, so the marker stays until it expires.
///
/// Nothing is written: the rules let only the author expire an event (and the organizer or lead for
/// stop requests), so hiding is purely client-side and every phone reaches the same answer from the
/// same data.
enum HazardLogic {
    struct Config: Sendable, Equatable {
        /// How far beyond the event a car must be to count as having passed it.
        var passMargin: CLLocationDistance = 100
        /// An event further than this from a route is not on it.
        var lateralTolerance: CLLocationDistance = 50
        var staleAfter: TimeInterval = 60

        static let `default` = Config()
    }

    static func isFresh(_ position: Position, now: Date, config: Config) -> Bool {
        position.updatedAt.map { now.timeIntervalSince($0) <= config.staleAfter } ?? true
    }

    static func isPassedByAll(
        event: TripEvent,
        cars: [Car],
        positions: [String: Position],
        mainRoute: RouteLine?,
        ownRoutes: [String: RouteLine] = [:],
        now: Date,
        config: Config = .default,
        cache: inout HazardOffsetCache
    ) -> Bool {
        let main = cache.mainOffset(of: event, on: mainRoute, tolerance: config.lateralTolerance)
        var passers = 0
        for car in cars {
            let id = ConvoyOrdering.carID(car)
            guard let position = positions[id], isFresh(position, now: now, config: config) else { continue }
            if let convoyOffset = position.convoyOffset {
                guard let main else { continue }
                if convoyOffset > main + config.passMargin { passers += 1 } else { return false }
            } else if let own = cache.ownOffset(
                of: event, carId: id, on: ownRoutes[id], tolerance: config.lateralTolerance)
            {
                if position.routeOffset > own + config.passMargin { passers += 1 } else { return false }
            } else if let main {
                if let merge = car.mergeOffset, merge >= main { continue }
                return false
            }
        }
        return passers > 0
    }

    /// Markers for every visible event, in the order given.
    static func markers(
        events: [TripEvent],
        cars: [Car],
        positions: [String: Position],
        mainRoute: RouteLine?,
        ownRoutes: [String: RouteLine] = [:],
        now: Date,
        config: Config = .default,
        cache: inout HazardOffsetCache
    ) -> [HazardMarker] {
        var result: [HazardMarker] = []
        for event in events where HazardGeometry.isRoadEvent(event) && !HazardGeometry.isExpired(event, now: now) {
            if isPassedByAll(
                event: event, cars: cars, positions: positions, mainRoute: mainRoute, ownRoutes: ownRoutes,
                now: now, config: config, cache: &cache)
            { continue }
            let main = cache.mainOffset(of: event, on: mainRoute, tolerance: config.lateralTolerance)
            result.append(HazardMarker(event: event, mainOffset: main, now: now))
        }
        return result
    }
}
