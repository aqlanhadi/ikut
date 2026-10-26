import CoreLocation
import FirebaseFirestore
import Testing
@testable import ikut

/// Which layers the lobby and the driving map ask the one shared map content for (D53).
struct TripMapContentTests {
    private let route: [CLLocationCoordinate2D] = [.init(latitude: 3.1, longitude: 101.6), .init(latitude: 4.6, longitude: 101.0)]
    private let pin = LobbyPin(id: "destination", kind: .destination, name: "Ipoh", latitude: 4.6, longitude: 101.0)
    private let join = LobbyPin(id: "join", kind: .join, name: "", latitude: 3.5, longitude: 101.5)
    private let overlay = RouteOverlay(id: "car2", colorHex: "#FF3B30", path: [MapCoordinate(latitude: 3.0, longitude: 101.5), MapCoordinate(latitude: 3.2, longitude: 101.6)],
                                       merge: MapCoordinate(latitude: 3.2, longitude: 101.6))
    private let car = MapMarker(id: "c1", number: 1, name: "Aqlan", colorHex: "#0A7CFF", coordinate: MapCoordinate(latitude: 3.2, longitude: 101.6),
                                heading: 0, isStale: false, ageText: nil, isLead: true, isJoining: false, isMine: true)
    private var hazard: HazardMarker {
        var event = TripEvent(type: .debris, location: GeoPoint(latitude: 3.3, longitude: 101.6), heading: 90, routeOffset: 100,
                              authorId: "u", carId: "c1", createdAt: Date())
        event.id = "h1"
        return HazardMarker(event: event, mainOffset: nil, now: Date())
    }

    @Test func organiserLobbyAsksForYouTheRouteAndPins() {
        let input = TripMapInput.lobby(route: route, pins: [pin], ownRoute: [], ownColorHex: "#0A7CFF")
        #expect(input.layers == [.user, .route, .pins])
    }

    @Test func participantLobbyAddsTheirOwnWayAndJoinPoint() {
        let input = TripMapInput.lobby(route: route, pins: [pin, join], ownRoute: route, ownColorHex: "#FF3B30")
        #expect(input.layers == [.user, .route, .ownRoute, .pins])
        #expect(input.pins.filter { $0.kind == .join }.count == 1)
    }

    @Test func theLobbyNeverGetsOtherCarsRoutesStartsOrMarkers() {
        let input = TripMapInput.lobby(route: route, pins: [pin, join], ownRoute: route, ownColorHex: "#FF3B30")
        #expect(input.overlays.isEmpty)
        #expect(input.cars.isEmpty)
        #expect(input.hazards.isEmpty)
        #expect(input.layers.isDisjoint(with: [.overlays, .cars, .hazards]))
    }

    @Test func theDrivingMapAsksForRouteOtherCarsHazardsAndCarsButNoPins() {
        let input = TripMapInput.driving(route: route, overlays: [overlay], hazards: [hazard], cars: [car])
        #expect(input.layers == [.route, .overlays, .hazards, .cars])
    }

    @Test func aTripWithNothingYetAsksForNothing() {
        #expect(TripMapInput.driving(route: [], overlays: [], hazards: [], cars: []).layers.isEmpty)
        #expect(TripMapInput.lobby(route: [], pins: [], ownRoute: [], ownColorHex: "#0A7CFF").layers == [.user])
    }

    @Test func theChosenCandidateIsDrawnLast() {
        let picked = LobbyPin(id: "a", kind: .candidate(number: 1, selected: true, taken: false), name: "A", latitude: 3, longitude: 101)
        let other = LobbyPin(id: "b", kind: .candidate(number: 2, selected: false, taken: false), name: "B", latitude: 3.1, longitude: 101)
        let input = TripMapInput.lobby(route: route, pins: [picked, other, pin], ownRoute: [], ownColorHex: "#0A7CFF")
        #expect(input.orderedPins.last?.id == "a")
    }
}
