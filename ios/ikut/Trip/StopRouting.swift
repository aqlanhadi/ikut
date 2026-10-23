import CoreLocation
import Foundation

/// One drive between two places, as MapKit answers it.
struct RouteLeg: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    /// Meters, as MapKit reports it.
    var distance: Double
    /// Seconds.
    var travelTime: Double
    var name: String
}

/// Gets one leg of a route. A protocol so tests use synthetic roads and never ask MapKit.
protocol LegRouting: Sendable {
    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg
}

/// The trip's main route through its stops: legs joined into one line, with where each stop falls on it.
struct StopRoute: Sendable {
    var route: BuiltRoute
    /// Meters along `route`, one per via point, in order; each is where its leg ends.
    var stopOffsets: [Double]
}

/// A leg that could not be routed. `index` is the leg that failed: leg `i` ends at via point `i`, and the
/// last leg ends at the destination.
struct LegFailure: Error, Equatable {
    var index: Int
    var reason: RouteError
}

enum StopRouting {
    /// Two legs whose ends are this close are one point where they meet: the second leg's first point is dropped.
    static let junctionTolerance: CLLocationDistance = 3

    /// Joins `legs` into one polyline. Offsets are measured on the joined line, so they agree with every
    /// other offset on the route (`RouteLine`).
    static func join(_ legs: [RouteLeg]) -> StopRoute {
        var coordinates: [CLLocationCoordinate2D] = []
        var junctions: [Int] = []
        for (i, leg) in legs.enumerated() {
            var points = leg.coordinates
            if let last = coordinates.last, let first = points.first,
               RouteLine.haversine(last, first) <= junctionTolerance {
                points.removeFirst()
            }
            coordinates += points
            if i < legs.count - 1 { junctions.append(max(0, coordinates.count - 1)) }
        }
        let line = RouteLine(coordinates)
        let names = legs.map(\.name).filter { !$0.isEmpty }
        // The road to name is the one the longest leg drives on.
        let name = legs.max { $0.distance < $1.distance }.flatMap { $0.name.isEmpty ? nil : $0.name } ?? names.first ?? ""
        let route = BuiltRoute(
            distance: line.length, travelTime: legs.reduce(0) { $0 + $1.travelTime }, name: name,
            polyline: Polyline.encode(coordinates))
        return StopRoute(route: route, stopOffsets: junctions.map { line.cumulative[min($0, line.cumulative.count - 1)] })
    }

    /// Leg by leg, in order, start → via points → destination. A leg already routed (`cache`) isn't asked for again.
    @MainActor
    static func build(
        from start: CLLocationCoordinate2D, via: [CLLocationCoordinate2D], to destination: CLLocationCoordinate2D,
        router: LegRouting, cache: LegCache? = nil
    ) async throws -> StopRoute {
        join(try await legs(from: start, via: via, to: destination, router: router, cache: cache))
    }

    /// The legs `build` joins, each asked for in order.
    @MainActor
    static func legs(
        from start: CLLocationCoordinate2D, via: [CLLocationCoordinate2D], to destination: CLLocationCoordinate2D,
        router: LegRouting, cache: LegCache? = nil
    ) async throws -> [RouteLeg] {
        let points = [start] + via + [destination]
        var legs: [RouteLeg] = []
        for i in 0..<(points.count - 1) {
            try Task.checkCancellation()
            if let cached = cache?.leg(from: points[i], to: points[i + 1]) {
                legs.append(cached)
                continue
            }
            do {
                let leg = try await router.leg(from: points[i], to: points[i + 1])
                guard leg.coordinates.count >= 2 else { throw RouteError.noRoute }
                cache?.store(leg, from: points[i], to: points[i + 1])
                legs.append(leg)
            } catch let error as RouteError {
                throw LegFailure(index: i, reason: error)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw LegFailure(index: i, reason: .failed(error.localizedDescription))
            }
        }
        return legs
    }

    // MARK: Which side of the highway

    /// A stop's route is counted as turning back when the road passes the point where it reaches the stop,
    /// carries on at least `minLoop` meters away, and comes back to it. The radius covers a dual
    /// carriageway and an R&R's slip road: the signature of an R&R on the other carriageway,
    /// reached by going on to the next interchange and turning round.
    static let uTurnRadius: CLLocationDistance = 250
    static let uTurnMinLoop: CLLocationDistance = 1_500
    static let uTurnMaxLoop: CLLocationDistance = 30_000
    private static let uTurnStep: CLLocationDistance = 25

    /// Extra meters the route drives because it turns back near the stop at `stopOffset`, or nil when it doesn't.
    /// Counts both the turn before the stop (past it, then back) and the one after (leaving the wrong way).
    static func uTurnExtra(on line: RouteLine, stopOffset: Double) -> Double? {
        guard let stop = line.coordinate(atOffset: stopOffset) else { return nil }
        var extra = 0.0
        // Before: the last time the road was within the radius, at least `minLoop` before the stop.
        var offset = stopOffset - uTurnMinLoop
        let lowest = max(0, stopOffset - uTurnMaxLoop)
        while offset >= lowest {
            if let c = line.coordinate(atOffset: offset), RouteLine.haversine(c, stop) < uTurnRadius {
                extra += stopOffset - offset
                break
            }
            offset -= uTurnStep
        }
        // After: the first time the road is back within the radius, at least `minLoop` past the stop.
        offset = stopOffset + uTurnMinLoop
        let highest = min(line.length, stopOffset + uTurnMaxLoop)
        while offset <= highest {
            if let c = line.coordinate(atOffset: offset), RouteLine.haversine(c, stop) < uTurnRadius {
                extra += offset - stopOffset
                break
            }
            offset += uTurnStep
        }
        return extra > 0 ? extra : nil
    }
}

/// Legs already routed this session, so an edit only asks MapKit for the legs it changed
/// (Apple throttles MKDirections).
@MainActor
final class LegCache {
    private var legs: [String: RouteLeg] = [:]

    private func key(_ from: CLLocationCoordinate2D, _ to: CLLocationCoordinate2D) -> String {
        func part(_ c: CLLocationCoordinate2D) -> String { String(format: "%.4f,%.4f", c.latitude, c.longitude) }
        return "\(part(from))>\(part(to))"
    }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> RouteLeg? { legs[key(from, to)] }
    func store(_ leg: RouteLeg, from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) { legs[key(from, to)] = leg }
}
