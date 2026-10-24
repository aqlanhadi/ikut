import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

struct EventTests {
    /// Roughly 1.1 km per 0.01 deg of longitude near the equator; a straight east-west route.
    private let coords = (0...10).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.01) }
    private var route: RouteLine { RouteLine(coords) }
    private let t0 = Fixtures.t0

    private func event(_ type: EventType, at date: Date? = nil, expires: Date?? = nil) -> TripEvent {
        var e = TripEvent(
            type: type, location: GeoPoint(latitude: 3, longitude: 101), heading: 0, routeOffset: 0,
            authorId: "u", carId: "c", createdAt: date ?? t0)
        if let expires { e.expiresAt = expires }
        return e
    }

    @Test func routeOffsetNearRoute() throws {
        let p = CLLocationCoordinate2D(latitude: 3.0001, longitude: 101.025)
        let offset = EventService.routeOffset(for: p, route: route, previousOffset: nil)
        let expected = RouteLine.haversine(coords[0], CLLocationCoordinate2D(latitude: 3, longitude: 101.025))
        #expect(abs(offset - expected) < 2)
    }

    @Test func routeOffsetUsesPreviousOffsetAsHint() {
        let p = CLLocationCoordinate2D(latitude: 3, longitude: 101.05)
        let offset = EventService.routeOffset(for: p, route: route, previousOffset: route.length / 2)
        #expect(abs(offset - route.length / 2) < 2)
        #expect(EventService.segmentIndex(in: route, atOffset: 0) == 0)
        #expect(EventService.segmentIndex(in: route, atOffset: route.length * 2) == route.segmentCount - 1)
        #expect(EventService.segmentIndex(in: route, atOffset: route.cumulative[4] + 1) == 4)
    }

    @Test func routeOffsetWithoutRouteFallsBack() {
        let p = CLLocationCoordinate2D(latitude: 3, longitude: 101)
        #expect(EventService.routeOffset(for: p, route: nil, previousOffset: 120) == 120)
        #expect(EventService.routeOffset(for: p, route: nil, previousOffset: nil) == 0)
        #expect(EventService.routeOffset(for: p, route: RouteLine([]), previousOffset: nil) == 0)
    }

    @Test func activeEventsFilters() {
        let expired = event(.debris, expires: t0.addingTimeInterval(-1))
        let live = event(.debris, expires: t0.addingTimeInterval(60))
        let forever = event(.stopFuel)
        let atBoundary = event(.pothole, expires: t0)
        var cleared = event(.accident)
        cleared.expiresAt = t0 // clear() sets expiresAt to now
        let result = EventService.activeEvents([expired, live, forever, atBoundary, cleared], now: t0)
        #expect(result.count == 2)
        #expect(result.contains(live))
        #expect(result.contains(forever))
    }

    @Test func activeEventsNewestFirst() {
        let old = event(.stopFuel, at: t0)
        let new = event(.stopFood, at: t0.addingTimeInterval(10))
        #expect(EventService.activeEvents([old, new], now: t0) == [new, old])
    }

    @Test func messageTrimming() {
        #expect(EventService.sanitizedMessage("  hi there \n") == "hi there")
        #expect(EventService.sanitizedMessage("   \n") == nil)
        #expect(EventService.sanitizedMessage(nil) == nil)
        let long = String(repeating: "a", count: 400)
        #expect(EventService.sanitizedMessage(long)?.count == 280)
        let emoji = String(repeating: "🚗", count: 400)
        #expect(EventService.sanitizedMessage(emoji)?.utf16.count == 280)
        #expect(EventService.sanitizedMessage(emoji)?.count == 140)
        #expect(EventService.sanitizedMessage("é" + emoji)?.utf16.count == 279)
    }

    @Test func makeEventDerivesFieldsAndNormalizesHeading() {
        let e = EventService.makeEvent(
            type: .debris, authorId: "u", carId: "c", location: coords[0], heading: -1,
            routeOffset: 10, message: "  x ", now: t0)
        #expect(e.category == .hazard)
        #expect(e.severity == .high)
        #expect(e.heading == 0)
        #expect(e.message == "x")
        #expect(e.expiresAt == t0.addingTimeInterval(45 * 60))
        #expect(e.createdAt == t0)
        #expect(EventService.makeEvent(
            type: .message, authorId: "u", carId: "c", location: coords[0], heading: 370,
            routeOffset: 0, message: nil, now: t0).heading == 10)
    }
}

/// Runs against the local Auth and Firestore emulators. Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct EventServiceEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private func load(_ tripId: String, _ eventId: String) async throws -> TripEvent {
        try await Firestore.firestore().document(FirestorePaths.event(tripId: tripId, eventId: eventId))
            .getDocument(as: TripEvent.self)
    }

    @Test func reportClearUndo() async throws {
        let t = try await EmulatorTrip.make(name: "Events")
        let coords = (0...10).map { CLLocationCoordinate2D(latitude: 3, longitude: 101 + Double($0) * 0.01) }
        let route = RouteLine(coords)

        let id = try await EventService.report(
            type: .debris, tripId: t.tripId, carId: t.carId, authorId: t.uid,
            location: CLLocationCoordinate2D(latitude: 3.0001, longitude: 101.05),
            heading: 90, route: route, previousOffset: nil)
        let e = try await load(t.tripId, id)
        #expect(e.category == .hazard)
        #expect(e.severity == .high)
        #expect(e.authorId == t.uid)
        #expect(e.carId == t.carId)
        #expect(abs(e.routeOffset - route.length / 2) < 5)
        let expiry = try #require(e.expiresAt)
        let created = try #require(e.createdAt)
        #expect(abs(expiry.timeIntervalSince(created) - 45 * 60) < 1)

        var iterator = EventService.listen(tripId: t.tripId).makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.map(\.id) == [id])

        try await EventService.clear(tripId: t.tripId, eventId: id)
        let cleared = try await load(t.tripId, id)
        #expect(try #require(cleared.expiresAt) <= Date().addingTimeInterval(1))
        let afterClear = await iterator.next()
        #expect(afterClear?.isEmpty == true)

        try await EventService.undo(tripId: t.tripId, eventId: id)
        let gone = try await Firestore.firestore()
            .document(FirestorePaths.event(tripId: t.tripId, eventId: id)).getDocument()
        #expect(!gone.exists)
    }

    @Test func ruleRejectionSurfacesAsError() async throws {
        let t = try await EmulatorTrip.make(name: "Events")
        let here = CLLocationCoordinate2D(latitude: 3, longitude: 101)
        await #expect(throws: (any Error).self) {
            try await EventService.report(
                type: .debris, tripId: t.tripId, carId: "not-my-car", authorId: t.uid, location: here,
                heading: 0, route: nil, previousOffset: nil)
        }
    }

    @Test func messageAndStopEventsPassRules() async throws {
        let t = try await EmulatorTrip.make(name: "Events")
        let here = CLLocationCoordinate2D(latitude: 3, longitude: 101)
        let long = "  " + String(repeating: "🚗", count: 400) + "  "
        let msgId = try await EventService.report(
            type: .message, tripId: t.tripId, carId: t.carId, authorId: t.uid, location: here,
            heading: -1, route: nil, previousOffset: 42, message: long)
        let msg = try await load(t.tripId, msgId)
        #expect(msg.message?.utf16.count == 280)
        #expect(msg.routeOffset == 42)
        #expect(msg.severity == .low)

        let stopId = try await EventService.report(
            type: .stopFuel, tripId: t.tripId, carId: t.carId, authorId: t.uid, location: here,
            heading: 0, route: nil, previousOffset: nil)
        let stop = try await load(t.tripId, stopId)
        // A stop request closes itself 30 minutes after it was asked, and the rules accept that.
        let asked = try #require(stop.createdAt)
        #expect(stop.expiresAt == asked.addingTimeInterval(30 * 60))
        // Clearing an event expires it now.
        try await EventService.clear(tripId: t.tripId, eventId: stopId)
        let cleared = try #require(try await load(t.tripId, stopId).expiresAt)
        #expect(cleared < asked.addingTimeInterval(30 * 60))
    }
}
