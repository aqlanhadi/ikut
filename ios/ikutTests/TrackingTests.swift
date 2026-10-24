import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: - Fixtures

private func fix(_ lat: Double = 0, _ lon: Double = 0, speed: Double = 20, course: Double = 90) -> LocationFix {
    LocationFix(latitude: lat, longitude: lon, speed: speed, course: course, timestamp: Date())
}

private func position(_ lon: Double, speed: Double = 20) -> Position {
    Position.fixture(
        location: GeoPoint(latitude: 0, longitude: lon), speed: speed, routeOffset: lon * 1000, updatedAt: nil)
}

/// Main route along the equator from lon 0 to 0.1 (about 11 km).
private let mainRoute = RouteLine((0...10).map { CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.01) })
/// Starts north of the main route, runs diagonally down onto it at lon 0.02, then follows it.
private let carRoute = RouteLine([
    CLLocationCoordinate2D(latitude: 0.02, longitude: 0),
    CLLocationCoordinate2D(latitude: 0, longitude: 0.02),
    CLLocationCoordinate2D(latitude: 0, longitude: 0.05),
])

// MARK: - Builder

struct PositionBuilderTests {
    @Test func speedClampsNegativeToZero() {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        #expect(b.build(from: fix(speed: -1), battery: nil).speed == 0)
        #expect(b.build(from: fix(speed: 13.5), battery: nil).speed == 13.5)
    }

    @Test func headingFallsBackToLastValid() {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        #expect(b.build(from: fix(course: -1), battery: nil).heading == 0)
        #expect(b.build(from: fix(course: 123), battery: nil).heading == 123)
        #expect(b.build(from: fix(course: -1), battery: nil).heading == 123)
        #expect(b.build(from: fix(course: 360), battery: nil).heading == 0)
        #expect(b.build(from: fix(course: 359.9), battery: nil).heading < 360)
    }

    @Test func batteryMapping() {
        #expect(PositionBuilder.battery(-1) == nil)
        #expect(PositionBuilder.battery(0.5) == 0.5)
        #expect(PositionBuilder.battery(1) == 1)
    }

    @Test func noOwnRouteUsesMainRouteForBothOffsets() {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        let p = b.build(from: fix(0, 0.03), battery: 0.8)
        #expect(abs(p.routeOffset - 3_335.8) < 5)
        #expect(p.convoyOffset == p.routeOffset)
        #expect(p.battery == 0.8)
        #expect(p.updatedAt == nil)
    }

    @Test func convoyOffsetNilUntilMerged() throws {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: carRoute)
        let early = b.build(from: fix(0.01, 0.01), battery: nil)
        #expect(early.convoyOffset == nil)
        #expect(early.routeOffset > 1_000 && early.routeOffset < carRoute.length)
        #expect(!b.hasMerged)

        // Just before the merge point (111 m off the main route, before the join).
        let near = b.build(from: fix(0.001, 0.019), battery: nil)
        #expect(near.convoyOffset == nil)

        let merged = b.build(from: fix(0, 0.03), battery: nil)
        #expect(b.hasMerged)
        let diagonal = RouteLine.haversine(carRoute.coordinates[0], carRoute.coordinates[1])
        #expect(abs(merged.routeOffset - (diagonal + 1_111.9)) < 10)
        #expect(abs(try #require(merged.convoyOffset) - 3_335.8) < 5)
    }

    @Test func mergeIsSticky() throws {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: carRoute)
        _ = b.build(from: fix(0, 0.03), battery: nil)
        let later = b.build(from: fix(0, 0.04), battery: nil)
        #expect(later.convoyOffset != nil)
        #expect(abs(try #require(later.convoyOffset) - 4_447.7) < 5)
    }

    @Test func routeThatNeverJoinsNeverMerges() {
        let far = RouteLine([CLLocationCoordinate2D(latitude: 0.5, longitude: 0), CLLocationCoordinate2D(latitude: 0.5, longitude: 0.05)])
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: far)
        let p = b.build(from: fix(0.5, 0.04), battery: nil)
        #expect(p.convoyOffset == nil)
        #expect(p.routeOffset > 4_000)
    }

    @Test func offsetsAreNeverNegative() {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        let p = b.build(from: fix(0, -0.5), battery: nil)
        #expect(p.routeOffset == 0)
    }
}

// MARK: - Publisher

@MainActor
struct PositionPublisherTests {
    let clock = TestClock()
    let writer = FakeWriter()

    func makePublisher() -> PositionPublisher {
        PositionPublisher(tripId: "t", carId: "c", writer: writer, clock: clock)
    }

    @Test func firstFixIsWrittenImmediately() async {
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        #expect(writer.written.count == 1)
    }

    @Test func atMostOneWritePerFiveSeconds() async {
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        await clock.advance(by: 1)
        p.submit(position(2))
        await clock.advance(by: 1)
        p.submit(position(3))
        await clock.advance(by: 1)
        await settle()
        #expect(writer.written.count == 1)
        await clock.advance(by: 1.9)
        #expect(writer.written.count == 1)
        await clock.advance(by: 0.2)  // t = 5.1 since first write
        #expect(writer.written.count == 2)
        #expect(writer.written[1].location.longitude == 3)
    }

    @Test func movingCarRewritesNewestFixAtTenSeconds() async {
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        await clock.advance(by: 9.5)
        #expect(writer.written.count == 1)
        await clock.advance(by: 0.6)
        #expect(writer.written.count == 2)
        #expect(writer.written[1].location.longitude == 1)
        await clock.advance(by: 10)
        #expect(writer.written.count == 3)
        _ = p
    }

    @Test func stationaryCarSendsHeartbeatEveryThirtySeconds() async {
        let p = makePublisher()
        p.submit(position(1, speed: 0))
        await settle()
        await clock.advance(by: 29)
        #expect(writer.written.count == 1)
        await clock.advance(by: 1.5)
        #expect(writer.written.count == 2)
        await clock.advance(by: 30)
        #expect(writer.written.count == 3)
        _ = p
    }

    @Test func tenFixesDuringSlowWriteCoalesceIntoOneFollowUp() async {
        writer.slow = true
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        #expect(writer.written.count == 1)
        for i in 2...11 {
            await clock.advance(by: 1)  // 10 s total: past the min interval, write still in flight
            p.submit(position(Double(i)))
        }
        await settle()
        #expect(writer.written.count == 1)
        writer.slow = false
        await writer.completeAll()
        #expect(writer.written.count == 2)
        #expect(writer.written[1].location.longitude == 11)
        await clock.advance(by: 4)
        #expect(writer.written.count == 2)
    }

    @Test func slowWriteThenFollowUpWaitsForMinInterval() async {
        writer.slow = true
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        await clock.advance(by: 1)
        p.submit(position(2))
        writer.slow = false
        await writer.completeAll()
        #expect(writer.written.count == 1)  // only 1 s since the first write
        await clock.advance(by: 4.1)
        #expect(writer.written.count == 2)
        #expect(writer.written[1].location.longitude == 2)
    }

    @Test func stopDropsPendingAndCancelsTimers() async {
        let p = makePublisher()
        p.submit(position(1))
        await settle()
        p.submit(position(2))
        p.stop()
        await clock.advance(by: 60)
        #expect(writer.written.count == 1)
        p.submit(position(3))
        await settle()
        #expect(writer.written.count == 1)
    }
}

// MARK: - Service

@MainActor
struct TrackingServiceTests {
    @Test func stopStopsSourceImmediatelyAndIgnoresLateFixes() async throws {
        let source = FakeSource()
        let writer = FakeWriter()
        let clock = TestClock()
        let service = TrackingService(source: source, writer: writer, clock: clock, batteryLevel: { 0.5 })
        service.start(tripId: "t", carId: "c", mainRoute: mainRoute, carRoute: nil)
        #expect(service.isTracking)
        #expect(source.started == 1)

        let onFix = try #require(source.onFix)
        onFix(fix(0, 0.01))
        await settle()
        #expect(writer.written.count == 1)
        #expect(writer.written[0].battery == 0.5)

        service.stop()
        #expect(source.stopped == 1)
        #expect(!service.isTracking)
        onFix(fix(0, 0.02))
        await clock.advance(by: 60)
        #expect(writer.written.count == 1)
    }
}

// MARK: - Emulator

/// Runs against the local Auth and Firestore emulators; see TripServiceTests.
@Suite(.emulator, .serialized)
@MainActor
struct TrackingEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private func makePosition() -> Position {
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        return b.build(from: fix(0, 0.03, speed: -1, course: -1), battery: nil)
    }

    @Test func trackerWritesPositionAndReadsItBack() async throws {
        let t = try await EmulatorTrip.make(name: "Tracking")
        let writer = FirestorePositionWriter()
        var b = PositionBuilder(mainRoute: mainRoute, carRoute: nil)
        let p = b.build(from: fix(0, 0.03, speed: 12, course: 270), battery: 0.4)
        try await writer.write(p, tripId: t.tripId, carId: t.carId)
        // Overwrite works (setData, not create-only).
        try await writer.write(p, tripId: t.tripId, carId: t.carId)

        let read = try await Firestore.firestore()
            .document(FirestorePaths.position(tripId: t.tripId, carId: t.carId))
            .getDocument(as: Position.self)
        #expect(read.id == t.carId)
        #expect(read.location.longitude == 0.03)
        #expect(read.speed == 12)
        #expect(read.heading == 270)
        #expect(read.battery == 0.4)
        #expect(read.convoyOffset == read.routeOffset)
        #expect(read.updatedAt != nil)
    }

    @Test func invalidSpeedAndHeadingStillPassRules() async throws {
        let t = try await EmulatorTrip.make(name: "Tracking")
        try await FirestorePositionWriter().write(makePosition(), tripId: t.tripId, carId: t.carId)
    }

    @Test func nonTrackerWriteIsRejected() async throws {
        let t = try await EmulatorTrip.make(name: "Tracking")
        // A second signed-in user who is not the car's tracker (and not a member).
        try Auth.auth().signOut()
        try await AuthModel().signInAsGuest(name: "Other")
        #expect(Auth.auth().currentUser?.uid != t.uid)
        await #expect(throws: Error.self) {
            try await FirestorePositionWriter().write(makePosition(), tripId: t.tripId, carId: t.carId)
        }
    }
}
