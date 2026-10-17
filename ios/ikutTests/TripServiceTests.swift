import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct TripServiceTests {
    private let destination = DestinationResult(
        name: "Kota Bharu", subtitle: "Kelantan",
        coordinate: .init(latitude: 6.1254, longitude: 102.2381))
    private let route = BuiltRoute(distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U")
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
    }

    @Test func durationFormatting() {
        #expect(RouteFormat.duration(8_700) == "2 hr 25 min")
        #expect(RouteFormat.duration(7_200) == "2 hr")
        #expect(RouteFormat.duration(2_700) == "45 min")
        #expect(RouteFormat.duration(5) == "1 min")
    }

    @Test func summaryIncludesRoadName() {
        #expect(RouteFormat.summary(route) == "205 km · 2 hr 25 min via E1")
        var unnamed = route
        unnamed.name = ""
        #expect(RouteFormat.summary(unnamed) == "205 km · 2 hr 25 min")
    }

    @Test func defaultTripName() {
        #expect(TripService.defaultTripName(for: "Aqlan") == "Aqlan's trip")
        #expect(TripService.defaultTripName(for: nil) == "My trip")
    }

    @Test func tripDocumentMatchesRules() {
        let trip = TripService.makeTrip(
            name: "Raya", code: "ABC234", organizerId: "uid1", destination: destination, route: route)
        #expect(trip.status == .active)
        #expect(trip.organizerId == "uid1")
        #expect(trip.route == route.polyline)
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
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct TripServiceEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func createTripWritesTripMemberAndCar() async throws {
        let auth = AuthModel()
        try await auth.signInAsGuest(name: "Aqlan")
        let uid = try #require(Auth.auth().currentUser?.uid)

        let destination = DestinationResult(
            name: "Kota Bharu", subtitle: "Kelantan",
            coordinate: .init(latitude: 6.1254, longitude: 102.2381))
        let route = BuiltRoute(distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U")

        let ids = try await TripService.createTrip(
            name: "Balik kampung", destination: destination, route: route,
            organizer: TripOrganizer(id: uid, displayName: "Aqlan"),
            carName: "Aqlan's Myvi", carColor: TripService.palette[0])

        let db = Firestore.firestore()
        let trip = try await db.document(FirestorePaths.trip(ids.tripId)).getDocument(as: Trip.self)
        #expect(trip.name == "Balik kampung")
        #expect(trip.organizerId == uid)
        #expect(trip.status == .active)
        #expect(trip.route == route.polyline)
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
