import CoreLocation
import FirebaseFunctions
import Foundation

/// A car as a non-member sees it before joining (from the `previewTrip` callable).
struct PreviewCar: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var color: String
    var hasTracker: Bool
    /// Badge number; nil for cars created before numbering.
    var number: Int? = nil
}

/// A planned stop as a non-member sees it: name, kind and planned length, nothing else.
struct PreviewStop: Sendable, Equatable {
    var name: String
    var kind: PlannedStopKind
    var minutes: Int? = nil

    /// "R&R Tapah · fuel · 20 min", or "R&R Tapah · fuel" without a length. A meeting point reads
    /// "· meeting point": "meet" alone reads like a verb to someone with only the code (owner, #204).
    var line: String {
        var parts = [name, kind == .meet ? "meeting point" : StopFormat.kind(kind).lowercased()]
        if let minutes { parts.append(StopFormat.length(minutes: minutes)) }
        return parts.joined(separator: " · ")
    }
}

/// Where the trip ends: the only coordinate `previewTrip` gives someone who has only the code.
struct PreviewCoordinate: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// What `previewTrip` returns: no member ids or other personal data.
struct TripPreview: Sendable, Equatable {
    var tripId: String
    var name: String
    var destinationName: String
    /// Only used to ask MapKit for the drive from here; nil from an older server.
    var destinationCoordinate: PreviewCoordinate? = nil
    var cars: [PreviewCar]
    /// In the organizer's order, skipped ones already left out; empty on trips without stops (and older servers).
    var stops: [PreviewStop] = []
}

enum JoinCarChoice: Sendable, Equatable {
    case existing(id: String)
    case new(name: String, color: String)
}

/// What `joinTrip` returns.
struct JoinResult: Sendable, Equatable {
    var tripId: String
    var carId: String
    var trackerTaken: Bool
}

/// A failure with a message that is safe to show as is.
struct JoinError: Error, Equatable, LocalizedError, Sendable {
    var message: String
    var errorDescription: String? { message }
}

/// The two callables behind the join flow. Tests substitute a fake.
protocol JoinAPI: Sendable {
    func preview(code: String) async throws -> TripPreview
    func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult
}

enum JoinService {
    /// Uppercases, drops spaces, dashes and anything outside the code alphabet, and caps the length.
    static func normalizeCode(_ raw: String) -> String {
        let allowed = Set(TripService.codeAlphabet)
        return String(raw.uppercased().filter { allowed.contains($0) }.prefix(TripService.codeLength))
    }

    static func isCompleteCode(_ code: String) -> Bool { code.count == TripService.codeLength }

    /// A palette color no existing car uses; if all are taken, cycles by car count.
    static func chooseColor(existing cars: [PreviewCar]) -> String {
        let used = Set(cars.map { $0.color.uppercased() })
        if let free = TripService.palette.first(where: { !used.contains($0.uppercased()) }) { return free }
        return TripService.palette[cars.count % TripService.palette.count]
    }

    /// Friendly text for a callable failure. `code` is nil for errors outside the Functions domain.
    static func message(code: FunctionsErrorCode?, serverMessage: String) -> String {
        switch code {
        case .notFound:
            return "No active trip has that code. Check it with the organizer, or the trip may have ended."
        case .resourceExhausted:
            return serverMessage.localizedCaseInsensitiveContains("cars")
                ? "This trip already has the most cars it can hold. Join one of the existing cars."
                : "This trip is full."
        case .invalidArgument:
            return serverMessage.localizedCaseInsensitiveContains("not part of this trip")
                ? "That car is no longer part of this trip. Pick another."
                : "Trip codes are 6 letters or numbers. Check the code and try again."
        case .failedPrecondition:
            return "That code is shared by more than one trip. Ask the organizer for a new trip."
        case .unauthenticated, .permissionDenied:
            return "You're signed out. Restart ikut and try again."
        case .unavailable, .deadlineExceeded:
            return "Can't reach the server. Check your connection and try again."
        default:
            return "Something went wrong. Please try again."
        }
    }

    static func map(_ error: Error) -> JoinError {
        if let error = error as? JoinError { return error }
        let ns = error as NSError
        if ns.domain == FunctionsErrorDomain {
            return JoinError(
                message: message(
                    code: FunctionsErrorCode(rawValue: ns.code),
                    serverMessage: ns.localizedDescription))
        }
        if ns.domain == NSURLErrorDomain {
            return JoinError(message: message(code: .unavailable, serverMessage: ""))
        }
        return JoinError(message: message(code: nil, serverMessage: ""))
    }

    /// `joinTrip` request payload.
    static func joinPayload(
        code: String, displayName: String, car: JoinCarChoice, tracker: Bool
    ) -> [String: Any] {
        let carPayload: [String: Any]
        switch car {
        case .existing(let id): carPayload = ["existingCarId": id]
        case .new(let name, let color): carPayload = ["newCar": ["name": name, "color": color]]
        }
        return ["code": code, "displayName": displayName, "car": carPayload, "tracker": tracker]
    }

    static func parsePreview(_ data: Any) throws -> TripPreview {
        guard let root = data as? [String: Any],
            let tripId = root["tripId"] as? String,
            let name = root["name"] as? String,
            let destination = root["destinationName"] as? String,
            let rawCars = root["cars"] as? [[String: Any]]
        else { throw JoinError(message: "Unexpected response from the server.") }
        let cars = try rawCars.map { raw -> PreviewCar in
            guard let id = raw["id"] as? String, let name = raw["name"] as? String,
                let color = raw["color"] as? String
            else { throw JoinError(message: "Unexpected response from the server.") }
            return PreviewCar(
                id: id, name: name, color: color, hasTracker: raw["hasTracker"] as? Bool ?? false,
                number: (raw["number"] as? NSNumber)?.intValue)
        }
        // A stop the app can't read is left out rather than hiding the whole ticket.
        let stops = (root["stops"] as? [[String: Any]] ?? []).compactMap { raw -> PreviewStop? in
            guard let name = raw["name"] as? String, let kindRaw = raw["kind"] as? String,
                let kind = PlannedStopKind(rawValue: kindRaw)
            else { return nil }
            return PreviewStop(name: name, kind: kind, minutes: (raw["minutes"] as? NSNumber)?.intValue)
        }
        let coordinate = (root["destinationCoordinate"] as? [String: Any]).flatMap { raw -> PreviewCoordinate? in
            guard let lat = (raw["latitude"] as? NSNumber)?.doubleValue, let lng = (raw["longitude"] as? NSNumber)?.doubleValue,
                abs(lat) <= 90, abs(lng) <= 180
            else { return nil }
            return PreviewCoordinate(latitude: lat, longitude: lng)
        }
        return TripPreview(
            tripId: tripId, name: name, destinationName: destination, destinationCoordinate: coordinate, cars: cars, stops: stops)
    }

    static func parseJoinResult(_ data: Any) throws -> JoinResult {
        guard let root = data as? [String: Any],
            let tripId = root["tripId"] as? String,
            let carId = root["carId"] as? String
        else { throw JoinError(message: "Unexpected response from the server.") }
        return JoinResult(tripId: tripId, carId: carId, trackerTaken: root["trackerTaken"] as? Bool ?? false)
    }
}

/// Talks to the deployed (or emulated) callables.
struct LiveJoinAPI: JoinAPI {
    func preview(code: String) async throws -> TripPreview {
        do {
            let result = try await Backend.functions.httpsCallable("previewTrip").call(["code": code])
            return try JoinService.parsePreview(result.data)
        } catch {
            throw JoinService.map(error)
        }
    }

    func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
        do {
            let payload = JoinService.joinPayload(code: code, displayName: displayName, car: car, tracker: tracker)
            let result = try await Backend.functions.httpsCallable("joinTrip").call(payload)
            return try JoinService.parseJoinResult(result.data)
        } catch {
            throw JoinService.map(error)
        }
    }
}
