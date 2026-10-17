import FirebaseCore
import FirebaseFirestore
import Testing
@testable import ikut

struct ModelTests {
    private let encoder = Firestore.Encoder()
    private let point = GeoPoint(latitude: 3.139, longitude: 101.687)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// `@DocumentID` can only be decoded with a document reference, which needs a (never contacted) Firestore instance.
    private func decode<T: Decodable>(_ type: T.Type, from data: [String: Any]) throws -> T {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure(options: FirebaseOptions(googleAppID: "1:1:ios:1", gcmSenderID: "1"))
        }
        let ref = Firestore.firestore().document("trips/doc")
        let decoder = Firestore.Decoder()
        decoder.userInfo[CodingUserInfoKey(rawValue: "DocumentRefUserInfoKey")!] = ref
        return try decoder.decode(type, from: data)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try decode(T.self, from: try encoder.encode(value))
    }

    @Test func tripRoundTrips() throws {
        let trip = Trip(
            id: "doc", name: "Balik Kampung", code: "ABC234", organizerId: "u1", route: "_p~iF~ps|U",
            destination: Destination(name: "Penang", coordinate: point), status: .active,
            createdAt: date, lastActivityAt: date, endedAt: nil)
        #expect(try roundTrip(trip) == trip)
    }

    @Test func carRoundTrips() throws {
        let full = Car(id: "doc", name: "Car 1", color: "#FF0000", trackerUserId: "u1", isLead: true,
                       route: "abc", mergeOffset: 1200, state: .convoy)
        let sparse = Car(id: "doc", name: "Car 2", color: "#00FF00", trackerUserId: nil, isLead: false,
                         route: nil, mergeOffset: nil, state: .joining)
        #expect(try roundTrip(full) == full)
        #expect(try roundTrip(sparse) == sparse)
    }

    @Test func memberRoundTrips() throws {
        let member = Member(id: "doc", displayName: "Aqlan", carId: "c1", role: .organizer, pushToken: "tok")
        #expect(try roundTrip(member) == member)
        let bare = Member(id: "doc", displayName: "Sara", carId: "c1", role: .member, pushToken: nil)
        #expect(try roundTrip(bare) == bare)
    }

    @Test func positionRoundTrips() throws {
        let position = Position(id: "doc", location: point, speed: 27.5, heading: 90, routeOffset: 5000,
                                convoyOffset: nil, battery: 0.8, updatedAt: date)
        #expect(try roundTrip(position) == position)
    }

    @Test func eventRoundTrips() throws {
        var event = TripEvent(type: .debris, location: point, heading: 45, routeOffset: 300,
                              authorId: "u1", carId: "c1", createdAt: date, message: "Tyre on lane 2")
        event.id = "doc"
        #expect(try roundTrip(event) == event)
    }

    @Test func encodedFieldNamesMatchFirestoreLayout() throws {
        let event = TripEvent(type: .stopFuel, location: point, heading: 0, routeOffset: 0,
                              authorId: "u1", carId: "c1", createdAt: date)
        let data = try encoder.encode(event)
        #expect(data["type"] as? String == "stopFuel")
        #expect(data["category"] as? String == "stopRequest")
        #expect(data["routeOffset"] != nil)
        #expect(data["id"] == nil)
    }

    @Test func unknownEventTypeDecodesWithoutThrowing() throws {
        let data: [String: Any] = [
            "type": "meteorShower", "category": "hazard", "severity": "high",
            "location": point, "heading": 0.0, "routeOffset": 0.0,
            "authorId": "u1", "carId": "c1", "createdAt": Timestamp(date: date),
        ]
        let event = try decode(TripEvent.self, from: data)
        #expect(event.type == .other("meteorShower"))
        #expect(event.id == "doc")
        #expect(try roundTrip(event) == event)
        #expect(try encoder.encode(event)["type"] as? String == "meteorShower")
    }

    @Test func knownTypesRoundTripThroughRawValue() {
        let all: [EventType] = [
            .debris, .accident, .pothole, .animal, .stoppedVehicle, .roadworks, .heavyRain, .trafficJam,
            .stopRest, .stopFuel, .stopFood, .stopToilet, .pullingOver, .carTrouble, .runningLate, .message,
        ]
        for type in all { #expect(EventType(rawValue: type.rawValue) == type) }
    }

    @Test func typesMapToCategories() {
        #expect(EventType.accident.category == .hazard)
        #expect(EventType.heavyRain.category == .condition)
        #expect(EventType.stopToilet.category == .stopRequest)
        #expect(EventType.carTrouble.category == .status)
        #expect(EventType.message.category == .message)
        #expect(EventType.other("x").category == .message)
    }

    @Test func categorySeverityAndExpiry() {
        #expect(EventCategory.hazard.severity == .high)
        #expect(EventCategory.condition.severity == .medium)
        #expect(EventCategory.stopRequest.severity == .medium)
        #expect(EventCategory.status.severity == .high)
        #expect(EventCategory.message.severity == .low)

        #expect(EventCategory.hazard.defaultExpiry == TimeInterval(45 * 60))
        #expect(EventCategory.condition.defaultExpiry == TimeInterval(60 * 60))
        #expect(EventCategory.message.defaultExpiry == TimeInterval(30 * 60))
        #expect(EventCategory.stopRequest.defaultExpiry == nil)
        #expect(EventCategory.status.defaultExpiry == nil)
    }

    @Test func eventInitDerivesExpiry() {
        let hazard = TripEvent(type: .pothole, location: point, heading: 0, routeOffset: 0,
                               authorId: "u", carId: "c", createdAt: date)
        #expect(hazard.expiresAt == date.addingTimeInterval(45 * 60))
        let stop = TripEvent(type: .stopRest, location: point, heading: 0, routeOffset: 0,
                             authorId: "u", carId: "c", createdAt: date)
        #expect(stop.expiresAt == nil)
    }

    @Test func pathsAreBuilt() {
        #expect(FirestorePaths.cars(tripId: "t") == "trips/t/cars")
        #expect(FirestorePaths.position(tripId: "t", carId: "c") == "trips/t/positions/c")
        #expect(FirestorePaths.event(tripId: "t", eventId: "e") == "trips/t/events/e")
    }
}
