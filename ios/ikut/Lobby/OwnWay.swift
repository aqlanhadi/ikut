import CoreLocation
import Foundation
import Observation

/// Where a car meets the convoy, as the lobby words it ("Your own way in", D26).
enum OwnWayJoin: Equatable {
    /// On the main route at its very start: leaves with the convoy.
    case startsWithConvoy
    /// On the main route part-way along, `offset` meters from its start (a car parked at a stop ahead).
    case onRoute(offset: Double)
    /// Drives its own route and joins the main route `offset` meters along.
    case merges(offset: Double)
    /// Own route never meets the main one before the destination.
    case meetsAtDestination
}

/// Pure decisions behind the participant's route card: no MapKit, no Firestore.
enum OwnWayLogic {
    /// A car on the main route this close to its start leaves with the convoy.
    static let startsWithin: CLLocationDistance = 2_000

    /// How the car meets the convoy and how far its own route runs before that; nil before its route is known
    /// (the tracker has no fix yet). Reads only the car doc: `CarRouteLogic` stored `route` (nil on the main route)
    /// and `mergeOffset`.
    static func join(car: Car?, main: RouteLine) -> (join: OwnWayJoin, ownToJoin: Double, own: RouteLine?)? {
        guard let car, !main.isEmpty else { return nil }
        guard let encoded = car.route, !encoded.isEmpty else {
            guard let offset = car.mergeOffset else { return nil }
            return (offset < startsWithin ? .startsWithConvoy : .onRoute(offset: offset), 0, nil)
        }
        let own = RouteLine(Polyline.decode(encoded))
        guard own.coordinates.count > 1 else { return nil }
        if let merge = main.mergeOffset(of: own, tolerance: CarRouteLogic.mergeTolerance) {
            return (.merges(offset: car.mergeOffset ?? merge.mainOffset), merge.otherOffset, own)
        }
        return (.meetsAtDestination, own.length, own)
    }

    /// The viewer's own start: the first point of the car's own route, else the phone's location; nil when neither
    /// is known (the card then says "Your location"). Never another member's start.
    static func start(car: Car?, phone: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        if let encoded = car?.route, let first = Polyline.decode(encoded).first { return first }
        return phone
    }

    /// "Joins the convoy near Rawang". Without the town yet, "Joins the convoy".
    static func joinLine(_ join: OwnWayJoin?, place: String?, destination: String) -> String? {
        switch join {
        case nil: return nil
        case .startsWithConvoy: return "Starts with the convoy"
        case .onRoute: return place.map { "On the route near \($0)" } ?? "On the route"
        case .merges: return place.map { "Joins the convoy near \($0)" } ?? "Joins the convoy"
        case .meetsAtDestination: return "Meets the convoy in \(destination)"
        }
    }

    /// Where the car joins the main route; nil when it doesn't (or isn't known).
    static func joinCoordinate(_ join: OwnWayJoin?, main: RouteLine) -> CLLocationCoordinate2D? {
        switch join {
        case .merges(let offset), .onRoute(let offset): main.coordinate(atOffset: offset)
        case .startsWithConvoy: main.coordinate(atOffset: 0)
        case .meetsAtDestination, nil: nil
        }
    }

    /// Own distance to the join point + the rest of the main route; a route that never merges is just its own length.
    static func distance(join: OwnWayJoin, ownToJoin: Double, mainLength: Double) -> Double {
        switch join {
        case .startsWithConvoy: mainLength
        case .onRoute(let offset): max(0, mainLength - offset)
        case .merges(let offset): ownToJoin + max(0, mainLength - offset)
        case .meetsAtDestination: ownToJoin
        }
    }
}

/// The participant's own trip, loaded for the lobby: town they start from, where they join, their distance and
/// drive time, and their own route for the map. One MKDirections request (start to destination) per car route.
@Observable @MainActor
final class OwnWayInfo {
    struct Drive: Equatable { var distance: Double; var travelTime: Double; var roadName: String }

    typealias DriveRequest = @MainActor (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> Drive
    typealias PlaceRequest = @MainActor (CLLocationCoordinate2D) async -> String?

    private(set) var join: OwnWayJoin?
    private(set) var fromName: String?
    private(set) var joinPlace: String?
    private(set) var drive: Drive?
    private(set) var distance: Double?
    private(set) var ownRoute: [CLLocationCoordinate2D] = []
    private(set) var joinCoordinate: CLLocationCoordinate2D?
    private(set) var destinationName = ""

    var joinLine: String? { OwnWayLogic.joinLine(join, place: joinPlace, destination: destinationName) }

    @ObservationIgnored private let driveRequest: DriveRequest
    @ObservationIgnored private let placeRequest: PlaceRequest
    @ObservationIgnored private var loadedKey: String?

    init(
        drive: @escaping DriveRequest = { from, to in
            let d = try await RouteBuilder.drive(from: from, to: to)
            return Drive(distance: d.distance, travelTime: d.travelTime, roadName: d.name)
        },
        place: @escaping PlaceRequest = { await RouteBuilder.placeName(at: $0) }
    ) {
        driveRequest = drive
        placeRequest = place
    }

    /// Works out the viewer's trip from their car doc; `phone` is asked only when the car has no route of its own.
    /// No-op for a car route it already loaded. A newer call wins over one still in flight.
    func load(
        main: RouteLine, destination: CLLocationCoordinate2D, destinationName: String, car: Car?,
        phone: @MainActor () async -> CLLocationCoordinate2D?
    ) async {
        let key = "\(car?.route ?? "-")|\(car?.mergeOffset.map { String($0) } ?? "-")|\(main.length)"
        guard key != loadedKey else { return }
        loadedKey = key
        self.destinationName = destinationName
        let found = OwnWayLogic.join(car: car, main: main)
        join = found?.join
        ownRoute = found?.own?.coordinates ?? []
        joinCoordinate = OwnWayLogic.joinCoordinate(found?.join, main: main)
        var start = OwnWayLogic.start(car: car, phone: found?.own == nil ? await phone() : nil)
        // A car on the main route with no fix on this phone: the route's own point at its offset stands in.
        if start == nil, let found, found.own == nil { start = joinCoordinate }
        guard loadedKey == key else { return }
        let joinAt = joinCoordinate
        async let from = town(at: start)
        async let place = town(at: joinAt)
        async let driven = driving(from: start, to: destination)
        let (fromTown, joinTown, drove) = await (from, place, driven)
        guard loadedKey == key else { return }
        fromName = fromTown ?? "Your location"
        joinPlace = joinTown
        drive = drove
        if let found {
            distance = OwnWayLogic.distance(join: found.join, ownToJoin: found.ownToJoin, mainLength: main.length)
        } else {
            distance = drove?.distance
        }
    }

    private func town(at coordinate: CLLocationCoordinate2D?) async -> String? {
        guard let coordinate else { return nil }
        return await placeRequest(coordinate)
    }

    private func driving(from start: CLLocationCoordinate2D?, to destination: CLLocationCoordinate2D) async -> Drive? {
        guard let start else { return nil }
        return try? await driveRequest(start, destination)
    }

    #if DEBUG
    /// Shows a settled trip as given, for launch states: nothing is requested.
    func showForDemo(
        car: Car?, main: RouteLine, destinationName: String, from: String, place: String?, drive: Drive?
    ) {
        let found = OwnWayLogic.join(car: car, main: main)
        join = found?.join
        ownRoute = found?.own?.coordinates ?? []
        joinCoordinate = OwnWayLogic.joinCoordinate(found?.join, main: main)
        self.destinationName = destinationName
        fromName = from
        joinPlace = place
        self.drive = drive
        distance = found.map { OwnWayLogic.distance(join: $0.join, ownToJoin: $0.ownToJoin, mainLength: main.length) } ?? drive?.distance
    }
    #endif
}
