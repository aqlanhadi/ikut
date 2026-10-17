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
}
