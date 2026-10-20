import CoreLocation
import Foundation

// The after-trip recap (design/project/Summary.dc.html and RecapMap.dc.html), as pure logic.
//
// What the server keeps limits what a recap can say:
// - Positions: one doc per car, overwritten on each fix, so there is no track to replay; only
//   where each car was last seen. They are deleted 7 days after `endedAt`.
// - Events: hazards, conditions and messages expire (45/60/30 min) and are purged 1 hour after
//   `expiresAt`, even while the trip runs; resolved stops likewise. Everything else goes 7 days
//   after the end. So a recap built right at the end can miss early hazards.
// `RecapSnapshot` is therefore cached on the phone and merged with each fresh fetch, so what was
// seen once stays in the recap.

/// A car as the recap needs it.
struct RecapCar: Codable, Sendable, Equatable {
    var id: String
    var name: String
    var color: String
    var number: Int?
    var isLead: Bool
}

/// A car's last known position.
struct RecapPosition: Codable, Sendable, Equatable {
    var carId: String
    var latitude: Double
    var longitude: Double
    /// Meters along the main route; nil until the car merged.
    var convoyOffset: Double?
    var updatedAt: Date?

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// A trip event as the recap needs it.
struct RecapEvent: Codable, Sendable, Equatable {
    var id: String
    /// `EventType.rawValue`.
    var type: String
    var carId: String
    var authorId: String
    var latitude: Double
    var longitude: Double
    var createdAt: Date?
    var expiresAt: Date?
    var message: String?
    /// Name of the pinned stop place, for stop requests.
    var placeName: String?

    var eventType: EventType { EventType(rawValue: type) }
    var category: EventCategory { eventType.category }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// Everything fetched for a recap; Codable so it can be cached on the phone.
struct RecapSnapshot: Codable, Sendable, Equatable {
    var tripId: String
    var name: String
    var destinationName: String
    var destinationLatitude: Double
    var destinationLongitude: Double
    /// Encoded polyline of the main route.
    var route: String
    var createdAt: Date?
    var endedAt: Date?
    var cars: [RecapCar]
    /// userId -> display name.
    var memberNames: [String: String]
    /// userId -> car id.
    var memberCars: [String: String]
    var positions: [RecapPosition]
    var events: [RecapEvent]

    var destination: CLLocationCoordinate2D { .init(latitude: destinationLatitude, longitude: destinationLongitude) }
}

/// One stat tile.
struct RecapStat: Equatable, Sendable {
    var label: String
    var value: String
    var unit: String
    var note: String
}

/// One "Road Trip Awards" card.
struct RecapAward: Equatable, Sendable {
    enum Kind: String, Sendable { case lead, firstIn, reporter, stopCaller, sweeper }
    var kind: Kind
    var title: String
    var detail: String
    var carId: String
}

/// One timeline row.
struct RecapTimelineItem: Equatable, Sendable, Identifiable {
    enum Kind: String, Sendable { case trip, stop, hazard, car }
    var id: String
    var kind: Kind
    var time: Date
    var title: String
    var detail: String
    /// SF Symbol.
    var symbol: String
    /// Where it happened, when known (for the map).
    var latitude: Double?
    var longitude: Double?

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }
}

/// A car's arrival, derived from where it was last seen.
struct RecapArrival: Equatable, Sendable {
    var carId: String
    /// Last fix near the destination. Trackers keep writing while parked, so this is "seen at the
    /// destination by", not the exact minute the car pulled in.
    var time: Date
}

/// The computed recap.
struct Recap: Equatable, Sendable {
    var title: String
    var subtitle: String
    var startedAt: Date?
    var endedAt: Date?
    var duration: TimeInterval?
    /// Main route length in meters; nil without a usable route.
    var routeDistance: Double?
    var carCount: Int
    var peopleCount: Int
    var stopCount: Int
    var roadReportCount: Int
    var arrivals: [RecapArrival]
    /// Gap between the first and last car along the main route at the end, in meters.
    var finalSpread: Double?
    var stats: [RecapStat]
    var awards: [RecapAward]
    var timeline: [RecapTimelineItem]
    /// Plain-language notes about data the recap could not use.
    var notes: [String]
}

enum RecapLogic {
    /// A car whose last fix is this close to the destination counts as arrived.
    static let arrivalRadius: CLLocationDistance = 1_000
    /// Positions and events are deleted this long after the trip ends.
    static let retention: TimeInterval = 7 * 24 * 3600

    // MARK: Merge

    /// Fresh data wins; events and positions only in the cache (purged on the server since) are kept.
    static func merge(cached: RecapSnapshot?, fresh: RecapSnapshot) -> RecapSnapshot {
        guard let cached, cached.tripId == fresh.tripId else { return fresh }
        var out = fresh
        let freshEventIds = Set(fresh.events.map(\.id))
        out.events += cached.events.filter { !freshEventIds.contains($0.id) }
        out.events.sort { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        let freshPositionIds = Set(fresh.positions.map(\.carId))
        out.positions += cached.positions.filter { !freshPositionIds.contains($0.carId) }
        let freshCarIds = Set(fresh.cars.map(\.id))
        out.cars += cached.cars.filter { !freshCarIds.contains($0.id) }
        out.memberNames = cached.memberNames.merging(fresh.memberNames) { _, new in new }
        out.memberCars = cached.memberCars.merging(fresh.memberCars) { _, new in new }
        return out
    }

    // MARK: Pieces

    static func duration(start: Date?, end: Date?) -> TimeInterval? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    static func routeDistance(_ encoded: String) -> Double? {
        let coords = Polyline.decode(encoded)
        guard coords.count > 1 else { return nil }
        return RouteLine(coords).length
    }

    /// Cars last seen within `arrivalRadius` of the destination, earliest first.
    static func arrivals(positions: [RecapPosition], destination: CLLocationCoordinate2D) -> [RecapArrival] {
        positions
            .compactMap { p -> RecapArrival? in
                guard let time = p.updatedAt, RouteLine.haversine(p.coordinate, destination) <= arrivalRadius else { return nil }
                return RecapArrival(carId: p.carId, time: time)
            }
            .sorted { $0.time == $1.time ? $0.carId < $1.carId : $0.time < $1.time }
    }

    /// Distance between the front and back car along the main route at their last fixes.
    static func finalSpread(positions: [RecapPosition]) -> Double? {
        let offsets = positions.compactMap(\.convoyOffset)
        guard offsets.count > 1, let lo = offsets.min(), let hi = offsets.max() else { return nil }
        return hi - lo
    }

    static func isRoadReport(_ e: RecapEvent) -> Bool { e.category == .hazard || e.category == .condition }

    /// "Aqlan’s Myvi" style label: the car's name.
    static func carName(_ id: String, in s: RecapSnapshot) -> String {
        s.cars.first { $0.id == id }?.name ?? "A car"
    }

    static func personName(_ userId: String, in s: RecapSnapshot) -> String {
        s.memberNames[userId] ?? "Someone"
    }

    /// The car that did the most of `filter`, with its count; ties go to the earliest.
    static func top(_ events: [RecapEvent], where filter: (RecapEvent) -> Bool) -> (carId: String, count: Int)? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for e in events where filter(e) {
            if counts[e.carId] == nil { order.append(e.carId) }
            counts[e.carId, default: 0] += 1
        }
        // Strictly greater only, so the earliest car keeps a tie.
        var best: (carId: String, count: Int)?
        for carId in order {
            let count = counts[carId] ?? 0
            if count > (best?.count ?? 0) { best = (carId, count) }
        }
        return best
    }

    static func awards(_ s: RecapSnapshot, arrivals: [RecapArrival]) -> [RecapAward] {
        var out: [RecapAward] = []
        if let lead = s.cars.first(where: \.isLead) {
            out.append(.init(kind: .lead, title: "Lead Car", detail: "\(lead.name) led the convoy", carId: lead.id))
        }
        if let first = arrivals.first {
            out.append(.init(kind: .firstIn, title: "First In", detail: "\(carName(first.carId, in: s)) reached \(s.destinationName) first", carId: first.carId))
        }
        if let r = top(s.events, where: isRoadReport) {
            let what = r.count == 1 ? "1 road report" : "\(r.count) road reports"
            out.append(.init(kind: .reporter, title: "Eagle Eye", detail: "\(carName(r.carId, in: s)) sent \(what)", carId: r.carId))
        }
        if let r = top(s.events, where: { $0.category == .stopRequest }) {
            let what = r.count == 1 ? "the only stop" : "\(r.count) stops"
            out.append(.init(kind: .stopCaller, title: "Pit Boss", detail: "\(carName(r.carId, in: s)) called \(what)", carId: r.carId))
        }
        let merged = s.positions.compactMap { p in p.convoyOffset.map { (position: p, offset: $0) } }
        if merged.count > 1, let back = merged.min(by: { $0.offset < $1.offset })?.position,
           s.cars.first(where: { $0.id == back.carId })?.isLead != true {
            out.append(.init(kind: .sweeper, title: "The Sweeper", detail: "\(carName(back.carId, in: s)) kept the back of the convoy", carId: back.carId))
        }
        return out
    }

    static func timeline(_ s: RecapSnapshot, arrivals: [RecapArrival], originName: String?) -> [RecapTimelineItem] {
        var items: [RecapTimelineItem] = []
        let route = Polyline.decode(s.route)
        if let start = s.createdAt {
            let from = originName.map { " from \($0)" } ?? ""
            items.append(.init(
                id: "start", kind: .trip, time: start, title: "Trip started",
                detail: "\(s.cars.count) \(s.cars.count == 1 ? "car" : "cars") set off\(from)", symbol: "flag.fill",
                latitude: route.first?.latitude, longitude: route.first?.longitude))
        }
        for e in s.events {
            guard let time = e.createdAt else { continue }
            let who = personName(e.authorId, in: s)
            let label = HazardMarker.presentation(for: e.eventType).label
            switch e.category {
            case .hazard, .condition:
                items.append(.init(
                    id: e.id, kind: .hazard, time: time, title: "\(label) reported",
                    detail: [who, e.message].compactMap { $0 }.joined(separator: " · "),
                    symbol: e.category == .hazard ? "exclamationmark.triangle.fill" : "cloud.rain.fill",
                    latitude: e.latitude, longitude: e.longitude))
            case .stopRequest:
                items.append(.init(
                    id: e.id, kind: .stop, time: time, title: "\(who) asked for a \(stopNoun(e.eventType))",
                    detail: carName(e.carId, in: s), symbol: "fuelpump.fill",
                    latitude: e.latitude, longitude: e.longitude))
                // A stop resolved before the trip ended has its expiry set to the resolve time.
                if let resolved = e.expiresAt, resolved <= (s.endedAt ?? .distantFuture) {
                    let place = e.placeName.map { "Stopped at \($0)" } ?? "Stop done"
                    items.append(.init(
                        id: e.id + "-done", kind: .stop, time: resolved, title: place,
                        detail: "Back on the road \(minutesText(resolved.timeIntervalSince(time))) after the request",
                        symbol: "checkmark.circle.fill", latitude: e.latitude, longitude: e.longitude))
                }
            case .status:
                items.append(.init(
                    id: e.id, kind: .car, time: time, title: "\(carName(e.carId, in: s)): \(label.lowercased())",
                    detail: who, symbol: "car.fill", latitude: e.latitude, longitude: e.longitude))
            case .message:
                items.append(.init(
                    id: e.id, kind: .car, time: time, title: "\(who) said",
                    detail: e.message ?? label, symbol: "text.bubble.fill", latitude: e.latitude, longitude: e.longitude))
            }
        }
        if let first = arrivals.first, let last = arrivals.last {
            let detail = arrivals.count > 1
                ? "\(carName(first.carId, in: s)) in first · last car in by \(clock(last.time))"
                : "\(carName(first.carId, in: s)) at the destination"
            items.append(.init(
                id: "arrived", kind: .trip, time: first.time, title: "Arrived in \(s.destinationName)",
                detail: detail, symbol: "mappin.circle.fill",
                latitude: s.destinationLatitude, longitude: s.destinationLongitude))
        }
        if let end = s.endedAt {
            items.append(.init(id: "end", kind: .trip, time: end, title: "Trip ended", detail: "Location sharing stopped", symbol: "flag.checkered", latitude: nil, longitude: nil))
        }
        return items.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
    }

    static func stopNoun(_ type: EventType) -> String {
        switch type {
        case .stopFuel: "fuel stop"
        case .stopFood: "food stop"
        case .stopToilet: "toilet stop"
        default: "rest stop"
        }
    }

    static func minutesText(_ seconds: TimeInterval) -> String {
        let m = max(0, Int((seconds / 60).rounded()))
        return m == 1 ? "1 min" : "\(m) min"
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    /// "14:58".
    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

    /// "2:47" for the "On the road" tile.
    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    // MARK: Whole recap

    static func recap(_ s: RecapSnapshot, originName: String? = nil, now: Date = Date()) -> Recap {
        let arrivals = arrivals(positions: s.positions, destination: s.destination)
        let duration = duration(start: s.createdAt, end: s.endedAt)
        let distance = routeDistance(s.route)
        let spread = finalSpread(positions: s.positions)
        let stops = s.events.filter { $0.category == .stopRequest }.count
        let reports = s.events.filter(isRoadReport).count
        let people = Set(s.memberNames.keys).count

        var subtitle = [originName.map { "\($0) to \(s.destinationName)" } ?? "To \(s.destinationName)"]
        subtitle.append(s.cars.count == 1 ? "1 car" : "\(s.cars.count) cars")
        if people > 0 { subtitle.append(people == 1 ? "1 person" : "\(people) people") }

        let arrivedNote: String
        if s.positions.isEmpty {
            arrivedNote = "Planned route"
        } else if !s.cars.isEmpty && arrivals.count >= s.cars.count {
            arrivedNote = s.cars.count == 1 ? "Arrived" : "All \(s.cars.count) cars arrived"
        } else {
            arrivedNote = "\(arrivals.count) of \(s.cars.count) arrived"
        }
        let timeNote = [s.createdAt, s.endedAt].allSatisfy { $0 != nil }
            ? "\(clock(s.createdAt!)) to \(clock(s.endedAt!))" : ""
        let spreadTile: RecapStat = spread.map {
            RecapStat(label: "Final spread", value: String(format: "%.1f", $0 / 1000), unit: "km", note: "Front to back at the end")
        } ?? RecapStat(label: "Stops", value: "\(stops)", unit: "", note: stops == 1 ? "1 stop requested" : "\(stops) stops requested")
        let stats = [
            RecapStat(label: "Distance", value: distance.map { "\(Int(($0 / 1000).rounded()))" } ?? "–", unit: "km", note: arrivedNote),
            RecapStat(label: "On the road", value: duration.map(hoursMinutes) ?? "–", unit: "hr", note: timeNote),
            spreadTile,
            RecapStat(label: "Road reports", value: "\(reports)", unit: "", note: spread == nil ? "Hazards and conditions" : (stops == 1 ? "1 stop" : "\(stops) stops")),
        ]

        var notes: [String] = []
        if s.positions.isEmpty {
            if let end = s.endedAt, now.timeIntervalSince(end) > retention {
                notes.append("Car positions are deleted 7 days after a trip, so arrivals and spread aren't shown.")
            } else {
                notes.append("No car positions were shared on this trip.")
            }
        }
        notes.append("ikut keeps only each car's last position, so the map shows where cars finished, not the path they drove.")

        return Recap(
            title: s.name, subtitle: subtitle.joined(separator: " · "), startedAt: s.createdAt, endedAt: s.endedAt,
            duration: duration, routeDistance: distance, carCount: s.cars.count, peopleCount: people,
            stopCount: stops, roadReportCount: reports, arrivals: arrivals, finalSpread: spread, stats: stats,
            awards: awards(s, arrivals: arrivals), timeline: timeline(s, arrivals: arrivals, originName: originName),
            notes: notes)
    }
}
