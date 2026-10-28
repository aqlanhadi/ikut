import CoreLocation
import FirebaseFirestore
import Foundation
import Observation

/// The lobby's view of the trip: the trip, cars, members and stops, read from the trip's session (its one reader,
/// so the lobby rows and the convoy can't disagree). A sample lobby holds its own data instead.
@Observable @MainActor
final class LobbyModel {
    let tripId: String
    /// The trip's session; nil in a sample lobby.
    @ObservationIgnored private let session: TripSession?
    private var sampleTrip: Trip?
    private var sampleCars: [Car] = []
    private var sampleMembers: [Member] = []
    private var sampleStops: [PlannedStop] = []

    var trip: Trip? { session?.trip ?? sampleTrip }
    var cars: [Car] { session?.cars ?? sampleCars }
    var members: [Member] { session?.members ?? sampleMembers }
    /// The planned stops, in driving order.
    var stops: [PlannedStop] { session?.stops ?? sampleStops }
    var errorMessage: String? { session?.errorMessage }

    var groupedCars: [LobbyCar] { LobbyLogic.group(cars: cars, members: members) }

    init(session: TripSession) {
        tripId = session.tripId
        self.session = session
    }

    #if DEBUG
    /// A lobby on sample data, for previews: no session, nothing is read.
    init(sampleTrip trip: Trip, cars: [Car], members: [Member], stops: [PlannedStop] = []) {
        tripId = trip.id ?? "sample"
        session = nil
        sampleTrip = trip
        sampleCars = cars
        sampleMembers = members
        sampleStops = stops
    }

    /// KL to Ipoh with four cars, Hafiz's still waiting for a tracker; `started` puts it on the road.
    static func sample(started: Bool, now: Date = Date(), seconds: Double? = nil, stops: [PlannedStop] = [], route: [CLLocationCoordinate2D]? = nil) -> LobbyModel {
        func car(_ id: String, _ name: String, _ color: String, _ number: Int, tracker: String?, lead: Bool = false) -> Car {
            Car(id: id, name: name, color: color, trackerUserId: tracker, isLead: lead, route: nil, mergeOffset: nil,
                state: .convoy, number: number)
        }
        func member(_ id: String, _ name: String, _ carId: String, organizer: Bool = false) -> Member {
            Member(id: id, displayName: name, carId: carId, role: organizer ? .organizer : .member)
        }
        let trip = Trip(
            id: "sample", name: "Balik kampung raya", code: "K7M2QX", organizerId: "u1",
            route: Polyline.encode(route ?? MapDemo.densify(MapDemo.mainWaypoints)),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 4.6, longitude: 101.09)),
            routeSeconds: seconds,
            status: .active, createdAt: now.addingTimeInterval(-900), lastActivityAt: now,
            startedAt: started ? now.addingTimeInterval(-600) : nil, endedAt: nil)
        return LobbyModel(
            sampleTrip: trip,
            cars: [
                car("c1", "Aqlan’s Myvi", "#2563EB", 1, tracker: "u1", lead: true),
                car("c2", "Wyna’s X70", "#D9480F", 2, tracker: "u2"),
                car("c3", "Hafiz’s Hilux", "#0F766E", 3, tracker: started ? "u3" : nil),
                car("c4", "Daniel’s City", "#7C3AED", 4, tracker: "u4"),
            ],
            members: [
                member("u1", "Aqlan", "c1", organizer: true), member("u5", "Faiz", "c1"),
                member("u2", "Wyna", "c2"), member("u3", "Hafiz", "c3"),
                member("u4", "Daniel", "c4"), member("u6", "Siti", "c4"), member("u7", "Aisha", "c4"),
            ],
            stops: stops)
    }
    #endif
}
