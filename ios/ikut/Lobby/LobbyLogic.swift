import Foundation

/// One car and the members riding in it, ready to display.
struct LobbyCar: Equatable, Identifiable {
    var car: Car
    var members: [Member]

    var id: String { car.id ?? car.name }
    var hasTracker: Bool { car.trackerUserId != nil }
}

enum LobbyLogic {
    /// Lead car first, then by name (case-insensitive); each car carries its members sorted by name.
    /// Members whose car doesn't exist (yet) are left out.
    static func group(cars: [Car], members: [Member]) -> [LobbyCar] {
        let byCar = Dictionary(grouping: members, by: \.carId)
        return sortedCars(cars).map { car in
            LobbyCar(car: car, members: sortedMembers(byCar[car.id ?? ""] ?? []))
        }
    }

    static func sortedCars(_ cars: [Car]) -> [Car] {
        cars.sorted { a, b in
            if a.isLead != b.isLead { return a.isLead }
            return nameOrder(a.name, b.name)
        }
    }

    static func sortedMembers(_ members: [Member]) -> [Member] {
        members.sorted { nameOrder($0.displayName, $1.displayName) }
    }

    private static func nameOrder(_ a: String, _ b: String) -> Bool {
        let result = a.localizedCaseInsensitiveCompare(b)
        return result == .orderedSame ? a < b : result == .orderedAscending
    }

    /// Deep link encoded in the QR code and the share text.
    static func joinURL(code: String) -> String { "ikut://join/\(code)" }

    static func shareText(code: String) -> String {
        "Join my convoy on ikut: code \(code) \(joinURL(code: code))"
    }

    /// The trip is underway: someone already tapped Start Trip (`startedAt`). A car already in the
    /// convoy doesn't count: an organizer parked on the route is in it before anyone starts the trip.
    /// Never true once the trip has ended.
    static func isStarted(trip: Trip?) -> Bool {
        guard let trip, trip.status == .active else { return false }
        return trip.startedAt != nil
    }

    /// Change destination is the organizer's until the trip ends; once it has started, the route is rebuilt from
    /// where the organizer is through the stops still ahead (D25 4d, #189).
    static func canChangeDestination(canEdit: Bool) -> Bool { canEdit }

    /// "On the road since 9:35 PM"; nil when the start time wasn't recorded.
    static func onTheRoadLine(startedAt: Date?, locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        guard let startedAt else { return nil }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return "On the road since \(startedAt.formatted(style))"
    }
}
