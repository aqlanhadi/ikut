import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct TripServiceTests {
    private let organizer = TripOrganizer(id: "uid1", displayName: "Aqlan")

    @Test func codeHasSixCharsFromAlphabet() {
        for _ in 0..<500 {
            let code = TripService.generateCode()
            #expect(code.count == 6)
            #expect(code.allSatisfy { TripService.codeAlphabet.contains($0) })
            #expect(code.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil)
        }
    }

    @Test func alphabetExcludesAmbiguousCharacters() {
        for c in "OIL01" { #expect(!TripService.codeAlphabet.contains(c)) }
        #expect(Set(TripService.codeAlphabet).count == TripService.codeAlphabet.count)
        #expect(TripService.codeAlphabet.count == 31)
    }

    @Test func codesAreRoughlyUnique() {
        let codes = Set((0..<10_000).map { _ in TripService.generateCode() })
        #expect(codes.count > 9_990)
    }

    @Test func distanceFormatting() {
        #expect(RouteFormat.distance(205_400) == "205 km")
        #expect(RouteFormat.distance(205_600) == "206 km")
        #expect(RouteFormat.distance(400) == "0 km")
        #expect(RouteFormat.kilometres(205_600) == 206)
    }

    @Test func defaultTripName() {
        #expect(TripService.defaultTripName(for: "Aqlan") == "Aqlan's trip")
        #expect(TripService.defaultTripName(for: nil) == "My trip")
        #expect(TripService.defaultTripName(destination: "Ipoh") == "Trip to Ipoh")
    }

    @Test func tripDocumentMatchesRules() {
        let trip = TripService.makeTrip(
            name: "Raya", code: "ABC234", organizerId: "uid1", destination: Fixtures.kotaBharu, route: Fixtures.longRoute)
        #expect(trip.status == .active)
        #expect(trip.organizerId == "uid1")
        #expect(trip.route == Fixtures.longRoute.polyline)
        #expect(trip.createdAt == nil)
        #expect(trip.endedAt == nil)
        #expect(trip.destination.name == "Kota Bharu")
        #expect(trip.destination.coordinate.latitude == 6.1254)
    }

    @Test func memberAndCarDocumentsMatchRules() {
        let member = TripService.makeOrganizerMember(organizer: organizer, carId: "car1")
        #expect(member.role == .organizer)
        #expect(member.carId == "car1")
        #expect(member.displayName == "Aqlan")

        let car = TripService.makeOrganizerCar(
            organizer: organizer, name: TripService.carName(for: "Aqlan"), color: TripService.palette[0])
        #expect(car.name == "Aqlan's car")
        #expect(car.isLead)
        #expect(car.state == .convoy)
        #expect(car.trackerUserId == "uid1")
        #expect(car.route == nil)
    }
}

/// Runs against the local Auth and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct TripServiceEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func savingStopsWritesTheRouteAndTheStopsTogetherAndRemovesTheOnesLeftOut() async throws {
        let trip = try await EmulatorTrip.make(name: "Stops", route: Fixtures.longRoute)
        let db = Firestore.firestore()
        func stop(_ id: String, _ name: String, _ order: Int, offset: Double, kind: PlannedStopKind = .fuel, minutes: Int? = 20) -> PlannedStop {
            PlannedStop.fixture(id, name: name, offset: offset, kind: kind, minutes: minutes, order: order)
        }
        let route = BuiltRoute(distance: 205_000, travelTime: 9_600, name: "E1", polyline: Fixtures.longRoute.polyline)
        try await TripService.saveStops(tripId: trip.tripId, plan: StopPlanSave(
            route: route, stops: [stop("a", "R&R Tapah", 0, offset: 62_000), stop("b", "Kopitiam", 1, offset: 120_000, kind: .food, minutes: nil)],
            removedIds: []))

        let saved = try await db.document(FirestorePaths.trip(trip.tripId)).getDocument(as: Trip.self)
        #expect(saved.routeSeconds == 9_600)
        #expect(saved.stopCount == 2)
        let docs = try await db.collection(FirestorePaths.stops(tripId: trip.tripId)).order(by: "order").getDocuments()
        let stops = docs.documents.compactMap { try? $0.data(as: PlannedStop.self) }
        #expect(stops.map(\.name) == ["R&R Tapah", "Kopitiam"])
        #expect(stops[0].routeOffset == 62_000 && stops[0].minutes == 20 && stops[1].minutes == nil)

        // Remove the first, put a meeting point first: one batch.
        let meet = PlannedStop.fixture(
            "m", name: "Petronas Sungai Buloh", offset: 0, coordinate: GeoPoint(latitude: 3.2, longitude: 101.58),
            kind: .meet, minutes: nil, meetAt: Date().addingTimeInterval(3_600))
        try await TripService.saveStops(tripId: trip.tripId, plan: StopPlanSave(
            route: route, stops: [meet, stop("b", "Kopitiam", 1, offset: 120_000, kind: .food, minutes: nil)], removedIds: ["a"]))
        let after = try await db.collection(FirestorePaths.stops(tripId: trip.tripId)).order(by: "order").getDocuments()
        let names = after.documents.compactMap { try? $0.data(as: PlannedStop.self) }
        #expect(names.map(\.name) == ["Petronas Sungai Buloh", "Kopitiam"])
        #expect(names[0].kind == .meet && names[0].meetAt != nil)

        // Changing the destination keeps the stops and rewrites their offsets with the route.
        try await TripService.changeDestination(
            tripId: trip.tripId, to: Fixtures.ipoh, route: route,
            stops: [meet, stop("b", "Kopitiam", 1, offset: 130_000, kind: .food, minutes: nil)])
        let moved = try await db.document(FirestorePaths.stop(tripId: trip.tripId, stopId: "b")).getDocument(as: PlannedStop.self)
        #expect(moved.routeOffset == 130_000)
    }

    @Test func createTripWritesTripMemberAndCar() async throws {
        let auth = AuthModel()
        try await auth.signInAsGuest(name: "Aqlan")
        let uid = try #require(Auth.auth().currentUser?.uid)


        let ids = try await TripService.createTrip(
            name: "Balik kampung", destination: Fixtures.kotaBharu, route: Fixtures.longRoute,
            organizer: TripOrganizer(id: uid, displayName: "Aqlan"),
            carName: "Aqlan's Myvi", carColor: TripService.palette[0])

        let db = Firestore.firestore()
        let trip = try await db.document(FirestorePaths.trip(ids.tripId)).getDocument(as: Trip.self)
        #expect(trip.name == "Balik kampung")
        #expect(trip.organizerId == uid)
        #expect(trip.status == .active)
        #expect(trip.route == Fixtures.longRoute.polyline)
        #expect(trip.code.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil)
        #expect(trip.createdAt != nil)

        let member = try await db.document(FirestorePaths.member(tripId: ids.tripId, userId: uid))
            .getDocument(as: Member.self)
        #expect(member.role == .organizer)
        #expect(member.carId == ids.carId)

        let car = try await db.document(FirestorePaths.car(tripId: ids.tripId, carId: ids.carId))
            .getDocument(as: Car.self)
        #expect(car.name == "Aqlan's Myvi")
        #expect(car.isLead)
        #expect(car.trackerUserId == uid)
        #expect(car.state == .convoy)
    }
}
