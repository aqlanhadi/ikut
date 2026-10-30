import FirebaseAuth
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing
@testable import ikut

struct TripServiceTests {
    private let organizer = TripOrganizer(id: "uid1", displayName: "Aqlan")

    @Test func alphabetExcludesAmbiguousCharacters() {
        for c in "OIL01" { #expect(!TripService.codeAlphabet.contains(c)) }
        #expect(Set(TripService.codeAlphabet).count == TripService.codeAlphabet.count)
        #expect(TripService.codeAlphabet.count == 31)
    }

    @Test func aRateLimitedCreateSaysHowLongToWait() {
        let m = TripService.createFailureMessage
        #expect(m(.resourceExhausted, 240) == "You’ve made a lot of trips lately. Wait 4 minutes and try again.")
        #expect(m(.resourceExhausted, 20) == "You’ve made a lot of trips lately. Wait a minute and try again.")
        #expect(m(.resourceExhausted, 3 * 3600) == "You’ve made a lot of trips lately. Wait 3 hours and try again.")
        #expect(m(.resourceExhausted, 13 * 3600) == "You’ve made a lot of trips today. Try again tomorrow.")
        #expect(m(.resourceExhausted, nil) == "You’ve made a lot of trips lately. Try again in a little while.")
    }

    @Test func aNewCodeFailureUsesPlainWordsAndSaysHowLongToWait() {
        let m = TripService.newCodeFailureMessage
        #expect(m(.resourceExhausted, 240) == "You’ve made a lot of new codes lately. Wait 4 minutes and try again.")
        #expect(m(.resourceExhausted, 13 * 3600) == "You’ve made a lot of new codes today. Try again tomorrow.")
        #expect(m(.unavailable, nil) == "Can’t reach the server. Check your signal and try again.")
        #expect(m(.failedPrecondition, nil) == "This trip has ended, so it can’t have a new code.")
        #expect(m(.permissionDenied, nil) == "Couldn’t make a new code just now. Please try again.")
    }

    @Test func otherCreateFailuresUsePlainWords() {
        let m = TripService.createFailureMessage
        #expect(m(.unavailable, nil) == "Can’t reach the server. Check your signal and try again.")
        #expect(m(.unauthenticated, nil) == "You’re signed out. Close ikut and open it again, then make your trip.")
        #expect(m(.unavailable, nil) != m(.internal, nil))
        #expect(m(.invalidArgument, nil) == "Use a shorter name, then try again.")
        // `aborted` is the server's "no free code": plain words, and not the no-signal message.
        #expect(m(.aborted, nil) == "Couldn’t set up your trip just now. Please try again.")
        #expect(TripService.callTimeout >= 20 && TripService.callTimeout <= 25)
        for code in [FunctionsErrorCode.internal, .aborted, .notFound] {
            let text = m(code, nil)
            #expect(text == "Couldn’t set up your trip just now. Please try again.")
            #expect(!text.localizedCaseInsensitiveContains("error") && !text.localizedCaseInsensitiveContains("failed"))
        }
    }

    @Test func aCallableErrorWithDetailsBecomesTheWaitMessage() {
        let limited = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.resourceExhausted.rawValue, userInfo: [
            FunctionsErrorDetailsKey: ["reason": "too-many-trips", "retryAfterSeconds": 600],
            NSLocalizedDescriptionKey: "Too many new trips. Wait 10 minutes and try again.",
        ])
        #expect(TripService.createFailure(limited).localizedDescription
            == "You’ve made a lot of trips lately. Wait 10 minutes and try again.")
        // Details of another limit are not read as a wait.
        let other = NSError(domain: FunctionsErrorDomain, code: FunctionsErrorCode.resourceExhausted.rawValue, userInfo: [
            FunctionsErrorDetailsKey: ["reason": "too-many-guesses", "retryAfterSeconds": 600],
        ])
        #expect(TripService.createFailure(other).localizedDescription
            == "You’ve made a lot of trips lately. Try again in a little while.")
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(TripService.createFailure(offline).localizedDescription == "Can’t reach the server. Check your signal and try again.")
    }

    @Test func theCreatePayloadCarriesTheTripAndNothingAboutACode() throws {
        let payload = TripService.createPayload(
            name: "Raya", destination: Fixtures.kotaBharu, route: Fixtures.longRoute, organizerName: "Aqlan", carId: "car1")
        #expect(Set(payload.keys) == ["name", "destination", "route", "routeSeconds", "organizerName", "carId"])
        #expect(payload["route"] as? String == Fixtures.longRoute.polyline)
        let place = try #require(payload["destination"] as? [String: Any])
        #expect(place["name"] as? String == "Kota Bharu")
        #expect(place["latitude"] as? Double == 6.1254)
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

    @Test func aLongPlaceNameCannotMakeTheDefaultNameTooLong() {
        let long = String(repeating: "Taman Perindustrian ", count: 20)
        let name = TripService.defaultTripName(destination: long)
        #expect(name.count == TripService.nameMaxLength)
        #expect(name.hasPrefix("Trip to Taman") && name.hasSuffix("…"))
        let fits = String(repeating: "x", count: TripService.nameMaxLength - 8)
        #expect(TripService.defaultTripName(destination: fits) == "Trip to " + fits)
    }

    @Test func tripNameLimit() {
        #expect(TripService.nameProblem(String(repeating: "a", count: 60)) == nil)
        #expect(TripService.nameProblem(String(repeating: "a", count: 61)) == "Use 1 to 60 characters.")

    }

    @Test func carDocumentMatchesRules() {
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

    /// D104: the organiser's removal is one batch (member delete and the `removed` record); the rules refuse the delete
    /// without the record, and no client can read the record. Needs this branch's rules (`tools/with-rules.mjs`).
    @Test func theOrganiserRemovesAMemberOnlyWithTheRemovalRecord() async throws {
        let trip = try await EmulatorTrip.make(name: "Remove")
        nonisolated(unsafe) let organiser = try #require(Auth.auth().currentUser)
        let code = try await trip.code()
        // Signed out first: signing in anonymously while signed in would hand back the organiser again.
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joiner = try #require(Auth.auth().currentUser?.uid)
        try #require(joiner != trip.uid)
        try await LiveJoinAPI().join(code: code, displayName: "Wyna", car: .new(name: "X70", color: TripService.palette[1]), tracker: false)
        try await Auth.auth().updateCurrentUser(organiser)
        try #require(Auth.auth().currentUser?.uid == trip.uid)
        // Firestore picks the new user up from the token, so make sure it has the organiser's.
        _ = try await organiser.getIDToken(forcingRefresh: true)

        let db = Firestore.firestore()
        let member = db.document(FirestorePaths.member(tripId: trip.tripId, userId: joiner))
        await #expect(throws: (any Error).self) { try await member.delete() }
        #expect(try await member.getDocument(source: .server).exists)

        try await TripService.removeMember(tripId: trip.tripId, userId: joiner, by: trip.uid)
        #expect(try await !member.getDocument().exists)
        await #expect(throws: (any Error).self) {
            _ = try await db.document(FirestorePaths.removed(tripId: trip.tripId, userId: joiner)).getDocument()
        }
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

    @Test func createTripThroughTheServerWritesTripMemberAndCar() async throws {
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
        #expect(trip.routeSeconds == Fixtures.longRoute.travelTime)

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
