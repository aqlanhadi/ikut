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

    /// What the lobby's bottom bar offers (D39): only the organizer starts the trip; a participant waits in the
    /// lobby, with no way to the map, until `startedAt` is set; then everyone gets Show map.
    enum BottomBar: Equatable {
        case startTrip
        case showMap
        /// A participant before the start; `organizerName` is nil while the members haven't loaded.
        case waiting(organizerName: String?)

        var label: String {
            switch self {
            case .startTrip: "Start trip"
            case .showMap: "Show map"
            case .waiting(let name): "Waiting for \(name ?? "the organiser") to start the trip"
            }
        }
    }

    /// A trip that has ended has nobody left to wait for: everyone gets the map button (it leads on to the recap).
    static func bottomBar(isOrganizer: Bool, started: Bool, ended: Bool = false, organizerName: String?) -> BottomBar {
        if started || ended { return .showMap }
        return isOrganizer ? .startTrip : .waiting(organizerName: organizerName)
    }

    /// The organizer's display name from the loaded members (their member id is their user id); nil if not loaded or blank.
    static func organizerName(trip: Trip?, members: [Member]) -> String? {
        guard let trip, let name = members.first(where: { $0.id == trip.organizerId })?.displayName
            .trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return name
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

extension LobbyLogic {
    /// "K7M2QX" shown as "K7M 2QX".
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// "You (organiser, sharing location) · Siti", "Wyna (sharing location) · 3 others", "Daniel · no one sharing yet".
    static func peopleLine(members: [Member], trackerUserId: String?, currentUserId: String?) -> String {
        guard !members.isEmpty else { return "No one yet" }
        let ordered = members.filter { $0.id == currentUserId } + members.filter { $0.id != currentUserId }
        func label(_ m: Member) -> String {
            var roles: [String] = []
            if m.role == .organizer { roles.append("organiser") }
            if let id = m.id, id == trackerUserId { roles.append("sharing location") }
            let name = m.id == currentUserId ? "You" : m.displayName
            return roles.isEmpty ? name : "\(name) (\(roles.joined(separator: ", ")))"
        }
        var parts: [String]
        if ordered.count <= 2 {
            parts = ordered.map(label)
        } else {
            parts = ordered.prefix(1).map(label)
            parts.append("\(ordered.count - 1) others")
        }
        if trackerUserId == nil { parts.append("no one sharing yet") }
        return parts.joined(separator: " · ")
    }
}
