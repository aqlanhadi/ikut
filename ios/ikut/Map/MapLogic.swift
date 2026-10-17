import CoreLocation
import Foundation

// Pure logic behind the live map: markers, camera modes and route overlays. No MapKit views,
// no Firestore; everything comes in as arguments so it can be unit-tested.

/// A latitude/longitude pair that is `Equatable` and `Sendable`, unlike `CLLocationCoordinate2D`.
struct MapCoordinate: Equatable, Sendable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ c: CLLocationCoordinate2D) {
        self.init(latitude: c.latitude, longitude: c.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

// MARK: - Markers

/// One car on the map.
struct MapMarker: Identifiable, Equatable, Sendable {
    var id: String
    var number: Int?
    var name: String
    var colorHex: String
    var coordinate: MapCoordinate
    /// Degrees clockwise from north; nil when unknown.
    var heading: Double?
    /// Position older than the stale threshold (60 s).
    var isStale: Bool
    /// "2 min ago" for a stale car.
    var ageText: String?
    /// The designated lead car.
    var isLead: Bool
    /// Still on its own route, not merged into the convoy yet.
    var isJoining: Bool
    var isMine: Bool
    /// The tracker paused sharing (and the pause has not expired). Shown instead of the age.
    var isPaused = false

    /// "Aqlan", "Hafiz · joining", "Daniel · 2 min ago", "Wyna · Paused".
    var label: String {
        var parts = [MapMarkerBuilder.shortName(name)]
        if isJoining { parts.append("joining") }
        if isPaused {
            parts.append("Paused")
        } else if isStale, let ageText {
            parts.append(ageText)
        }
        return parts.joined(separator: " · ")
    }
}

enum MapMarkerBuilder {
    /// A marker for every car that has a position: the convoy first, then the joining cars.
    static func markers(from snapshot: ConvoySnapshot, myCarId: String?, now: Date = Date()) -> [MapMarker] {
        var result: [MapMarker] = []
        for e in snapshot.convoy {
            result.append(marker(
                id: e.id, car: e.car, position: e.position, isStale: e.isStale, age: e.age,
                isJoining: false, myCarId: myCarId, now: now))
        }
        for e in snapshot.joining {
            guard let position = e.position else { continue }
            result.append(marker(
                id: e.id, car: e.car, position: position, isStale: e.isStale, age: e.age,
                isJoining: true, myCarId: myCarId, now: now))
        }
        return result
    }

    private static func marker(
        id: String, car: Car, position: Position, isStale: Bool, age: TimeInterval?,
        isJoining: Bool, myCarId: String?, now: Date
    ) -> MapMarker {
        MapMarker(
            id: id, number: car.number, name: car.name, colorHex: car.color,
            coordinate: MapCoordinate(latitude: position.location.latitude, longitude: position.location.longitude),
            heading: validHeading(position.heading), isStale: isStale,
            ageText: isStale ? agoText(age ?? 0) : nil,
            isLead: car.isLead, isJoining: isJoining, isMine: id == myCarId,
            isPaused: TripSessionLogic.isPaused(car, now: now))
    }

    /// A heading in 0..<360, or nil when it is missing (negative or not a number).
    static func validHeading(_ heading: Double) -> Double? {
        guard heading.isFinite, heading >= 0 else { return nil }
        return heading.truncatingRemainder(dividingBy: 360)
    }

    /// "2 min ago", from `ConvoyFormat.lastSeen` without its prefix.
    static func agoText(_ age: TimeInterval) -> String {
        let text = ConvoyFormat.lastSeen(age: age)
        let prefix = "Last seen "
        return text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    }

    /// "Wyna’s X70" -> "Wyna"; names without a possessive are kept as they are.
    static func shortName(_ name: String) -> String {
        for marker in ["’s ", "'s "] {
            if let range = name.range(of: marker) {
                let head = name[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty { return head }
            }
        }
        return name
    }

    /// Screen rotation for a marker's arrow: its heading relative to where the map's top points.
    static func rotation(heading: Double, cameraHeading: Double) -> Double {
        let r = (heading - cameraHeading).truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}

// MARK: - Camera

enum MapMode: Equatable, Sendable {
    /// Keep my car in view.
    case follow
    /// Keep every fresh car in view.
    case fit
    /// The user is panning; the camera is left alone.
    case free
}

/// A rectangle of the map, as center and spans in degrees.
struct GeoRegion: Equatable, Sendable {
    var center: MapCoordinate
    var latitudeSpan: Double
    var longitudeSpan: Double
}

enum CameraTarget: Equatable, Sendable {
    case follow(center: MapCoordinate, distance: Double)
    case fit(GeoRegion)
}

enum MapCameraLogic {
    /// Extra room around the cars as a fraction of their spread. The bottom is large because the
    /// convoy panel covers the lower part of the screen.
    struct Padding: Equatable, Sendable {
        var top: Double
        var bottom: Double
        var side: Double
        static let `default` = Padding(top: 0.3, bottom: 0.9, side: 0.5)
    }

    /// Smallest rectangle shown, in degrees (about 1.1 km), so one car or a tight group is not
    /// zoomed in to the street.
    static let minimumSpan = 0.01
    /// Camera distance in follow mode, meters.
    static let followDistance = 2500.0
    /// In follow mode the car sits in the upper part of the screen: the camera center is this
    /// fraction of the distance south of it.
    static let followLift = 0.18
    /// Rough height over width of the map on a phone. A fit on a wide group would otherwise leave
    /// spare height split evenly above and below, hiding the southern cars under the panel.
    static let viewAspect = 3.0

    /// What the camera should show; nil in free mode, when the user is in charge.
    /// - `me`: my car's (or my device's) coordinate, nil if unknown. Follow falls back to the
    ///   convoy rectangle then.
    /// - `fresh`: cars with a recent position; `all`: every marker, used when none is fresh.
    /// - `fallback`: the route's ends, used when there are no cars at all.
    static func target(
        mode: MapMode, me: MapCoordinate?, fresh: [MapCoordinate], all: [MapCoordinate],
        fallback: [MapCoordinate], padding: Padding = .default
    ) -> CameraTarget? {
        switch mode {
        case .free:
            return nil
        case .follow:
            if let me {
                return .follow(center: followCenter(me, distance: followDistance), distance: followDistance)
            }
            return fitTarget(fresh: fresh, all: all, fallback: fallback, padding: padding)
        case .fit:
            return fitTarget(fresh: fresh, all: all, fallback: fallback, padding: padding)
        }
    }

    private static func fitTarget(
        fresh: [MapCoordinate], all: [MapCoordinate], fallback: [MapCoordinate], padding: Padding
    ) -> CameraTarget? {
        let points = !fresh.isEmpty ? fresh : (!all.isEmpty ? all : fallback)
        return fitRegion(points, padding: padding, aspect: viewAspect).map(CameraTarget.fit)
    }

    /// The camera center that puts `coordinate` above the middle of the screen.
    static func followCenter(_ coordinate: MapCoordinate, distance: Double) -> MapCoordinate {
        let metersPerDegree = 111_320.0
        return MapCoordinate(
            latitude: coordinate.latitude - distance * followLift / metersPerDegree,
            longitude: coordinate.longitude)
    }

    /// Bounding box of `coordinates` grown by `padding`, never smaller than `minimumSpan`.
    /// With an `aspect` (height over width) the rectangle is made at least that tall by extending
    /// it southward, so the cars stay at the top. Nil for no coordinates.
    static func fitRegion(
        _ coordinates: [MapCoordinate], padding: Padding = .default, minimumSpan: Double = MapCameraLogic.minimumSpan,
        aspect: Double = 0
    ) -> GeoRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates {
            minLat = min(minLat, c.latitude)
            maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude)
            maxLon = max(maxLon, c.longitude)
        }
        let midLat = (minLat + maxLat) / 2
        let midLon = (minLon + maxLon) / 2
        let dLat = max(maxLat - minLat, minimumSpan)
        let dLon = max(maxLon - minLon, minimumSpan)
        var south = midLat - dLat / 2 - dLat * padding.bottom
        let north = midLat + dLat / 2 + dLat * padding.top
        let lonSpan = min(dLon * (1 + 2 * padding.side), 350)
        south = min(south, north - lonSpan * aspect)
        return GeoRegion(
            center: MapCoordinate(latitude: (south + north) / 2, longitude: midLon),
            latitudeSpan: min(north - south, 170),
            longitudeSpan: lonSpan)
    }

    /// Any drag, pinch or rotate by the user hands the camera back to them.
    static func mode(afterUserGestureFrom mode: MapMode) -> MapMode { .free }

    /// Follow my car when I am the tracker, my phone otherwise; each falls back to the other.
    static func myCoordinate(
        isTracker: Bool, carPosition: MapCoordinate?, device: MapCoordinate?
    ) -> MapCoordinate? {
        isTracker ? (carPosition ?? device) : (device ?? carPosition)
    }
}

// MARK: - Route overlays

extension RouteLine {
    /// The route from its start to `offset` meters along it, ending exactly at that point.
    func prefix(toOffset offset: CLLocationDistance) -> [CLLocationCoordinate2D] {
        guard !isEmpty else { return [] }
        let end = min(max(offset, 0), length)
        var result = coordinates.indices.filter { cumulative[$0] < end }.map { coordinates[$0] }
        if let tip = coordinate(atOffset: end) { result.append(tip) }
        return result
    }
}

/// A joining car's own route, cut where it meets the main route.
struct RouteOverlay: Identifiable, Equatable, Sendable {
    /// The car's id.
    var id: String
    var colorHex: String
    var path: [MapCoordinate]
    /// Where the route meets the main route; nil if it never does.
    var merge: MapCoordinate?
}

enum RouteOverlays {
    /// Own routes to draw: cars still joining that have a usable route. Each is cut at the point
    /// where it joins `mainRoute` for good (`RouteLine.mergeOffset`); a route that never joins is
    /// drawn whole, and one that is on the main route from the start is not drawn at all.
    static func overlays(cars: [Car], mainRoute: RouteLine?) -> [RouteOverlay] {
        cars.compactMap { car in
            guard car.state == .joining, let id = car.id,
                  let own = TripSessionLogic.routeLine(from: car.route), own.coordinates.count > 1
            else { return nil }
            var path = own.coordinates
            var merge: MapCoordinate?
            if let mainRoute, let m = mainRoute.mergeOffset(of: own) {
                path = own.prefix(toOffset: m.otherOffset)
                merge = path.last.map(MapCoordinate.init)
            }
            guard path.count > 1 else { return nil }
            return RouteOverlay(id: id, colorHex: car.color, path: path.map(MapCoordinate.init), merge: merge)
        }
    }

    /// A route stays on screen until its car has merged (is in the convoy).
    static func visible(_ overlays: [RouteOverlay], convoyIds: Set<String>) -> [RouteOverlay] {
        overlays.filter { !convoyIds.contains($0.id) }
    }
}

// MARK: - Copy

enum SeparationWarning {
    /// "Daniel is 4.6 km behind the car ahead." or, for several, "2 cars have fallen behind."
    /// Nil when nothing is separated.
    static func text(_ separated: [ConvoyEntry]) -> String? {
        guard let first = separated.first else { return nil }
        if separated.count > 1 { return "\(separated.count) cars have fallen behind." }
        let name = MapMarkerBuilder.shortName(first.car.name)
        guard let gap = first.gap else { return "\(name) has fallen behind." }
        return "\(name) is \(ConvoyFormat.distance(gap.distance)) behind the car ahead."
    }
}

// MARK: - Report

/// Where the report pin goes.
struct DeviceFix: Equatable, Sendable {
    var coordinate: MapCoordinate
    /// Degrees clockwise from north; negative when unknown.
    var course: Double
}

enum MapReportSnapshot {
    /// The latest location for the report sheet. The tracker uses its car's position; anyone else
    /// uses the phone's own fix. Route: the car's own route while joining, else the main route.
    /// `previousOffset` is only known from the car's position, along whichever route is used.
    static func make(
        isTracker: Bool, carPosition: Position?, device: DeviceFix?,
        carState: CarState?, mainRoute: RouteLine?, ownRoute: RouteLine?, now: Date
    ) -> ReportSnapshot? {
        let joining = carState == .joining
        let route = joining ? (ownRoute ?? mainRoute) : mainRoute
        let usesOwn = joining && ownRoute != nil
        if isTracker || device == nil, let p = carPosition {
            let offset = usesOwn ? p.routeOffset : p.convoyOffset
            return ReportSnapshot(
                coordinate: CLLocationCoordinate2D(latitude: p.location.latitude, longitude: p.location.longitude),
                heading: p.heading, route: route, previousOffset: offset, capturedAt: now)
        }
        guard let device else { return nil }
        return ReportSnapshot(
            coordinate: device.coordinate.clCoordinate, heading: device.course, route: route,
            previousOffset: nil, capturedAt: now)
    }
}

// MARK: - Chip placement

/// Which side of its marker a name chip goes on. Chips sit to the right unless that would run
/// past the usable width (screen edge, minus the room kept for the camera mode control).
enum MapChipPlacement {
    enum Side: Equatable, Sendable { case trailing, leading }

    /// Space kept at the right edge for the mode control (44 pt wide, 12 pt from the edge) plus a gap.
    static let reservedTrailing: CGFloat = 68
    /// Distance from the marker's center to the near edge of its chip.
    static let gap: CGFloat = 50

    /// `markerX` is the marker's center in screen space, `containerWidth` the map's width. An
    /// unknown position (before the first layout) keeps the chip on the right.
    static func side(
        markerX: CGFloat?, chipWidth: CGFloat, containerWidth: CGFloat,
        reservedTrailing: CGFloat = reservedTrailing
    ) -> Side {
        guard let markerX, containerWidth > 0 else { return .trailing }
        let rightEnd = markerX + gap + chipWidth
        if rightEnd <= containerWidth - reservedTrailing { return .trailing }
        // Flip only if the left side has room; otherwise stay where more of it is visible.
        let leftStart = markerX - gap - chipWidth
        return leftStart >= 8 || leftStart > containerWidth - reservedTrailing - rightEnd ? .leading : .trailing
    }
}

// MARK: - Stop host helpers

extension TripMapModel {
    /// What the stop sheet and card need from this screen; nil until the trip knows my car.
    func stopContext(tripId: String, userId: String, isOrganizer: Bool) -> StopContext? {
        guard let carId = myCarId else { return nil }
        return StopContext(
            tripId: tripId, userId: userId, carId: carId, isOrganizer: isOrganizer,
            snapshot: { [weak self] in self?.reportSnapshot() },
            mainRoute: mainRoute,
            frontOffset: { [weak self] in self?.convoy.convoy.first?.convoyOffset })
    }
}
