import CoreLocation
import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

// MARK: - Fixtures

private let t0 = Fixtures.t0

private func car(
    _ id: String, name: String = "Aqlan’s Myvi", number: Int? = 1, lead: Bool = false,
    state: CarState = .convoy, route: String? = nil, color: String = "#2563EB"
) -> Car {
    Car(id: id, name: name, color: color, trackerUserId: nil, isLead: lead, route: route,
        mergeOffset: nil, state: state, number: number)
}

private func position(
    lat: Double = 4.2, lon: Double = 101.26, heading: Double = 45, offset: Double? = 1000,
    ownOffset: Double = 1000, age: TimeInterval = 5
) -> Position {
    Position(
        id: nil, location: GeoPoint(latitude: lat, longitude: lon), speed: 25, heading: heading,
        routeOffset: ownOffset, convoyOffset: offset, battery: nil, updatedAt: t0.addingTimeInterval(-age))
}

private func snapshot(cars: [Car], positions: [String: Position], main: RouteLine? = nil) -> ConvoySnapshot {
    ConvoyOrdering.order(cars: cars, positions: positions, now: t0, mainRoute: main)
}

/// A straight route due north along longitude 100, about 11 km long.
private let mainRoute = RouteLine([
    CLLocationCoordinate2D(latitude: 0, longitude: 100), CLLocationCoordinate2D(latitude: 0.1, longitude: 100),
])

/// Comes in from the west and meets the main route at its last point.
private let ownCoordinates = [
    CLLocationCoordinate2D(latitude: 0.04, longitude: 99.95), CLLocationCoordinate2D(latitude: 0.04, longitude: 99.99),
    CLLocationCoordinate2D(latitude: 0.04, longitude: 100.0),
]

// MARK: - Markers

struct MapMarkerTests {
    @Test func markerPerCarWithColorNumberAndHeading() {
        let cars = [car("a", number: 1, lead: true), car("b", name: "Wyna’s X70", number: 2, color: "#D9480F")]
        let snap = snapshot(
            cars: cars, positions: ["a": position(heading: 90, offset: 2000), "b": position(heading: 200, offset: 500)])
        let markers = MapMarkerBuilder.markers(from: snap, myCarId: "b")
        #expect(markers.map(\.id) == ["a", "b"])
        #expect(markers[0].number == 1)
        #expect(markers[0].heading == 90)
        #expect(markers[0].isLead)
        #expect(!markers[0].isMine)
        #expect(markers[1].colorHex == "#D9480F")
        #expect(markers[1].isMine)
        #expect(!markers[1].isLead)
        // My own car reads "Me" rather than its name.
        #expect(markers[1].label == "Me")
    }

    @Test func staleCarIsFlaggedWithAge() {
        let snap = snapshot(
            cars: [car("a", name: "Daniel’s City", number: 4)], positions: ["a": position(age: 125)])
        let m = MapMarkerBuilder.markers(from: snap, myCarId: nil)[0]
        #expect(m.isStale)
        #expect(m.ageText == "2 min ago")
        #expect(m.label == "Daniel · 2 min ago")
    }

    @Test func pausedCarSaysPausedInsteadOfAge() {
        var paused = car("a", name: "Daniel’s City", number: 4)
        paused.pausedAt = t0.addingTimeInterval(-300)
        let snap = snapshot(cars: [paused], positions: ["a": position(age: 125)])
        let m = MapMarkerBuilder.markers(from: snap, myCarId: nil, now: t0)[0]
        #expect(m.isPaused)
        #expect(m.label == "Daniel · Paused")
        // An old pause has expired; the age is shown again.
        paused.pausedAt = t0.addingTimeInterval(-TripSessionLogic.pauseExpiry - 1)
        let expired = MapMarkerBuilder.markers(
            from: snapshot(cars: [paused], positions: ["a": position(age: 125)]), myCarId: nil, now: t0)[0]
        #expect(!expired.isPaused)
        #expect(expired.label == "Daniel · 2 min ago")
    }

    @Test func freshCarIsNotStale() {
        let snap = snapshot(cars: [car("a")], positions: ["a": position(age: 59)])
        let m = MapMarkerBuilder.markers(from: snap, myCarId: nil)[0]
        #expect(!m.isStale)
        #expect(m.ageText == nil)
    }

    @Test func joiningCarWithPositionGetsAMarker() {
        let own = Polyline.encode(ownCoordinates)
        let joining = car("j", name: "Hafiz’s Hilux", number: 3, state: .joining, route: own)
        let snap = snapshot(
            cars: [car("a"), joining],
            positions: ["a": position(), "j": position(lat: 0.04, lon: 99.97, offset: nil)], main: mainRoute)
        let markers = MapMarkerBuilder.markers(from: snap, myCarId: nil)
        #expect(markers.map(\.id) == ["a", "j"])
        #expect(markers[1].isJoining)
        #expect(markers[1].label == "Hafiz · joining")
    }

    @Test func joiningCarWithoutPositionHasNoMarker() {
        let snap = snapshot(cars: [car("j", state: .joining)], positions: [:])
        #expect(MapMarkerBuilder.markers(from: snap, myCarId: nil).isEmpty)
    }

    @Test func headingValidation() {
        #expect(MapMarkerBuilder.validHeading(-1) == nil)
        #expect(MapMarkerBuilder.validHeading(.nan) == nil)
        #expect(MapMarkerBuilder.validHeading(0) == 0)
        #expect(MapMarkerBuilder.validHeading(360) == 0)
        #expect(MapMarkerBuilder.validHeading(359.5) == 359.5)
    }

    @Test func rotationIsRelativeToTheMapHeading() {
        #expect(MapMarkerBuilder.rotation(heading: 90, cameraHeading: 0) == 90)
        #expect(MapMarkerBuilder.rotation(heading: 90, cameraHeading: 90) == 0)
        #expect(MapMarkerBuilder.rotation(heading: 10, cameraHeading: 350) == 20)
        #expect(MapMarkerBuilder.rotation(heading: 350, cameraHeading: 10) == 340)
    }

    @Test func shortNames() {
        #expect(MapMarkerBuilder.shortName("Wyna’s X70") == "Wyna")
        #expect(MapMarkerBuilder.shortName("Aqlan's car") == "Aqlan")
        #expect(MapMarkerBuilder.shortName("Red Myvi") == "Red Myvi")
        #expect(MapMarkerBuilder.shortName("’s odd") == "’s odd")
    }

    @Test func separationWarningText() {
        let cars = [car("a", number: 1), car("b", name: "Daniel’s City", number: 2), car("c", name: "Sam’s Vios", number: 3)]
        var snap = snapshot(
            cars: Array(cars.prefix(2)), positions: ["a": position(offset: 10_000), "b": position(offset: 3_900)])
        #expect(SeparationWarning.text(snap.separatedGaps) == "Daniel is 6.1 km behind the car ahead.")
        snap = snapshot(
            cars: cars, positions: ["a": position(offset: 20_000), "b": position(offset: 12_000), "c": position(offset: 1_000)])
        #expect(SeparationWarning.text(snap.separatedGaps) == "2 cars have fallen behind.")
        snap = snapshot(cars: Array(cars.prefix(2)), positions: ["a": position(offset: 2_000), "b": position(offset: 1_000)])
        #expect(SeparationWarning.text(snap.separatedGaps) == nil)
    }
}

// MARK: - Camera

struct MapCameraTests {
    private let tapah = MapCoordinate(latitude: 4.2, longitude: 101.26)
    private let bidor = MapCoordinate(latitude: 4.1, longitude: 101.29)
    private let none = MapCameraLogic.Padding(top: 0, bottom: 0, side: 0)

    @Test func fitRegionCoversEveryPoint() throws {
        let region = try #require(MapCameraLogic.fitRegion([tapah, bidor], padding: none))
        #expect(abs(region.center.latitude - 4.15) < 1e-9)
        #expect(abs(region.center.longitude - 101.275) < 1e-9)
        #expect(abs(region.latitudeSpan - 0.1) < 1e-9)
        #expect(abs(region.longitudeSpan - 0.03) < 1e-9 || region.longitudeSpan == MapCameraLogic.minimumSpan)
        // Longitude spread is 0.03, over the 0.01 floor.
        #expect(abs(region.longitudeSpan - 0.03) < 1e-9)
    }

    @Test func paddingAddsRoomAndShiftsTheCenterSouthForThePanel() throws {
        let padding = MapCameraLogic.Padding(top: 0.2, bottom: 0.8, side: 0.25)
        let region = try #require(MapCameraLogic.fitRegion([tapah, bidor], padding: padding))
        #expect(abs(region.latitudeSpan - 0.2) < 1e-9)
        #expect(abs(region.longitudeSpan - 0.045) < 1e-9)
        // Cars sit in the upper part of the rectangle: its center is south of theirs.
        #expect(region.center.latitude < 4.15)
        let north = region.center.latitude + region.latitudeSpan / 2
        let south = region.center.latitude - region.latitudeSpan / 2
        #expect(abs(north - 4.22) < 1e-9)
        #expect(abs(south - 4.02) < 1e-9)
    }

    @Test func singleCarGetsTheMinimumSpan() throws {
        let region = try #require(MapCameraLogic.fitRegion([tapah], padding: none))
        #expect(abs(region.latitudeSpan - MapCameraLogic.minimumSpan) < 1e-12)
        #expect(abs(region.longitudeSpan - MapCameraLogic.minimumSpan) < 1e-12)
        #expect(abs(region.center.latitude - tapah.latitude) < 1e-12)
        #expect(region.center.longitude == tapah.longitude)
    }

    @Test func fitRegionOfNothingIsNil() {
        #expect(MapCameraLogic.fitRegion([]) == nil)
    }

    @Test func freeModeLeavesTheCameraAlone() {
        #expect(MapCameraLogic.target(mode: .free, me: tapah, fresh: [tapah], all: [tapah], fallback: []) == nil)
    }

    @Test func followCentersOnMe() throws {
        // Exactly on me: the map's safe-area padding puts that center in the middle of the visible part.
        let target = try #require(MapCameraLogic.target(mode: .follow, me: tapah, fresh: [bidor], all: [bidor], fallback: []))
        #expect(target == .follow(center: tapah, distance: MapCameraLogic.followDistance))
    }

    @Test func defaultFitPaddingIsEvenAroundTheCars() throws {
        let region = try #require(MapCameraLogic.fitRegion([tapah, bidor]))
        #expect(abs(region.center.latitude - 4.15) < 1e-9)
        #expect(abs(region.center.longitude - 101.275) < 1e-9)
    }

    @Test func obscuredInsetsPassThroughWhenTheMapHasRoom() {
        let insets = MapObscuredInsets.insets(mapHeight: 800, top: 60, bottom: 380)
        #expect(insets.top == 60)
        #expect(insets.bottom == 380)
    }

    @Test func obscuredInsetsShrinkToLeaveAVisibleStrip() {
        let insets = MapObscuredInsets.insets(mapHeight: 800, top: 140, bottom: 700)
        #expect(abs(800 - insets.top - insets.bottom - MapObscuredInsets.minimumVisible) < 1e-9)
        // In proportion: the bottom keeps five times the top.
        #expect(abs(insets.bottom / insets.top - 5) < 1e-9)
    }

    @Test func obscuredInsetsAreZeroBeforeLayout() {
        let insets = MapObscuredInsets.insets(mapHeight: 0, top: 60, bottom: 380)
        #expect(insets.top == 0 && insets.bottom == 0)
        let negative = MapObscuredInsets.insets(mapHeight: 800, top: -4, bottom: 300)
        #expect(negative.top == 0 && negative.bottom == 300)
    }

    @Test func followWithoutALocationFitsTheConvoy() throws {
        let target = try #require(MapCameraLogic.target(mode: .follow, me: nil, fresh: [tapah, bidor], all: [], fallback: []))
        guard case .fit = target else {
            Issue.record("expected fit")
            return
        }
    }

    @Test func fitUsesFreshCarsOnly() throws {
        let far = MapCoordinate(latitude: 3.0, longitude: 101.0)
        let target = try #require(MapCameraLogic.target(
            mode: .fit, me: nil, fresh: [tapah, bidor], all: [tapah, bidor, far], fallback: [], padding: none))
        guard case .fit(let region) = target else {
            Issue.record("expected fit")
            return
        }
        #expect(abs(region.latitudeSpan - 0.1) < 1e-9)
    }

    @Test func fitFallsBackToAllCarsThenTheRoute() throws {
        func center(_ target: CameraTarget?) -> MapCoordinate? {
            if case .fit(let region)? = target { region.center } else { nil }
        }
        let allStale = MapCameraLogic.target(
            mode: .fit, me: nil, fresh: [], all: [tapah], fallback: [bidor], padding: none)
        #expect(try #require(center(allStale)).longitude == tapah.longitude)
        let route = MapCameraLogic.target(mode: .fit, me: nil, fresh: [], all: [], fallback: [bidor], padding: none)
        #expect(try #require(center(route)).longitude == bidor.longitude)
        #expect(MapCameraLogic.target(mode: .fit, me: nil, fresh: [], all: [], fallback: []) == nil)
    }

    @Test func aGestureAlwaysMeansFreePan() {
        #expect(MapCameraLogic.mode(afterUserGestureFrom: .follow) == .free)
        #expect(MapCameraLogic.mode(afterUserGestureFrom: .fit) == .free)
        #expect(MapCameraLogic.mode(afterUserGestureFrom: .free) == .free)
        #expect(MapCameraLogic.mode(afterUserGestureFrom: .hazard(id: "h")) == .free)
    }

    @Test func hazardModeFramesMeAndTheHazard() throws {
        let target = try #require(MapCameraLogic.target(
            mode: .hazard(id: "h"), me: tapah, fresh: [bidor], all: [bidor], fallback: [], focus: bidor))
        #expect(target == MapCameraLogic.fitRegion([bidor, tapah], padding: .focus).map(CameraTarget.fit))
    }

    @Test func hazardModeFollowsMeOnceTheHazardIsGone() {
        let target = MapCameraLogic.target(mode: .hazard(id: "h"), me: tapah, fresh: [], all: [], fallback: [], focus: nil)
        #expect(target == .follow(center: tapah, distance: MapCameraLogic.followDistance))
    }

    @Test func trackerFollowsItsCarOthersFollowTheirPhone() {
        #expect(MapCameraLogic.myCoordinate(isTracker: true, carPosition: tapah, device: bidor) == tapah)
        #expect(MapCameraLogic.myCoordinate(isTracker: false, carPosition: tapah, device: bidor) == bidor)
        #expect(MapCameraLogic.myCoordinate(isTracker: false, carPosition: tapah, device: nil) == tapah)
        #expect(MapCameraLogic.myCoordinate(isTracker: true, carPosition: nil, device: bidor) == bidor)
        #expect(MapCameraLogic.myCoordinate(isTracker: false, carPosition: nil, device: nil) == nil)
    }
}

// MARK: - Route overlays

struct MapOverlayTests {
    private let ownPolyline = Polyline.encode(ownCoordinates)

    @Test func joiningRouteIsCutAtTheMergePoint() throws {
        // The own route runs 0.01 degrees (about 1.1 km) past the merge on purpose.
        let longer = ownCoordinates + [CLLocationCoordinate2D(latitude: 0.0401, longitude: 100.0)]
        let overlays = RouteOverlays.overlays(
            cars: [car("j", state: .joining, route: Polyline.encode(longer))], mainRoute: mainRoute)
        let overlay = try #require(overlays.first)
        let merge = try #require(overlay.merge)
        #expect(abs(merge.longitude - 100.0) < 0.001)
        #expect(abs(merge.latitude - 0.04) < 0.001)
        // Drawn from the start up to the merge, not beyond it.
        #expect(overlay.path.first == MapCoordinate(latitude: 0.04, longitude: 99.95))
        #expect(overlay.path.last == merge)
        #expect(overlay.path.count >= 3)
    }

    @Test func routeThatMeetsAtItsEndKeepsEverythingUpToThePoint() throws {
        let overlay = try #require(RouteOverlays.overlays(
            cars: [car("j", state: .joining, route: ownPolyline, color: "#0F766E")], mainRoute: mainRoute).first)
        #expect(overlay.id == "j")
        #expect(overlay.colorHex == "#0F766E")
        let own = RouteLine(Polyline.decode(ownPolyline))
        let merge = try #require(mainRoute.mergeOffset(of: own))
        let expected = try #require(own.coordinate(atOffset: merge.otherOffset))
        #expect(abs(overlay.path.last!.latitude - expected.latitude) < 1e-4)
        #expect(abs(overlay.path.last!.longitude - expected.longitude) < 1e-4)
    }

    @Test func onlyJoiningCarsWithARouteAreDrawn() {
        let cars = [
            car("a", state: .convoy, route: ownPolyline),
            car("b", state: .joining, route: nil),
            car("c", state: .joining, route: "not a route\u{1}"),
            car("d", state: .joining, route: ownPolyline),
        ]
        let overlays = RouteOverlays.overlays(cars: cars, mainRoute: mainRoute)
        #expect(overlays.map(\.id) == ["d"])
    }

    @Test func routeThatNeverJoinsIsDrawnWhole() throws {
        let away = [
            CLLocationCoordinate2D(latitude: 0.05, longitude: 99.5), CLLocationCoordinate2D(latitude: 0.05, longitude: 99.6),
        ]
        let overlay = try #require(RouteOverlays.overlays(
            cars: [car("j", state: .joining, route: Polyline.encode(away))], mainRoute: mainRoute).first)
        #expect(overlay.merge == nil)
        #expect(overlay.path.count == 2)
    }

    @Test func withoutAMainRouteTheOwnRouteIsDrawnWhole() throws {
        let overlay = try #require(RouteOverlays.overlays(
            cars: [car("j", state: .joining, route: ownPolyline)], mainRoute: nil).first)
        #expect(overlay.path.count == 3)
        #expect(overlay.merge == nil)
    }

    @Test func mergedCarsLoseTheirOverlay() {
        let overlays = RouteOverlays.overlays(
            cars: [car("j", state: .joining, route: ownPolyline)], mainRoute: mainRoute)
        #expect(RouteOverlays.visible(overlays, convoyIds: []).count == 1)
        #expect(RouteOverlays.visible(overlays, convoyIds: ["j"]).isEmpty)
    }

    @Test func prefixEndsExactlyAtTheOffset() {
        let line = RouteLine(ownCoordinates)
        let half = line.prefix(toOffset: line.cumulative[1] / 2)
        #expect(half.count == 2)
        #expect(abs(half[1].longitude - 99.97) < 1e-6)
        #expect(line.prefix(toOffset: line.length).count == 3)
        #expect(line.prefix(toOffset: -5).count == 1)
        #expect(line.prefix(toOffset: 1e9).last?.longitude == 100.0)
    }
}

// MARK: - Report snapshot

struct MapReportSnapshotTests {
    private let device = DeviceFix(coordinate: MapCoordinate(latitude: 1, longitude: 2), course: 77)

    @Test func trackerUsesItsCarPositionAndTheMainRoute() throws {
        let snap = try #require(MapReportSnapshot.make(
            isTracker: true, carPosition: position(lat: 4.2, lon: 101.26, heading: 45, offset: 1234),
            device: device, carState: .convoy, mainRoute: mainRoute, ownRoute: nil, now: t0))
        #expect(snap.coordinate.latitude == 4.2)
        #expect(snap.heading == 45)
        #expect(snap.previousOffset == 1234)
        #expect(snap.route?.length == mainRoute.length)
    }

    @Test func joiningCarReportsOnItsOwnRoute() throws {
        let own = RouteLine(ownCoordinates)
        let snap = try #require(MapReportSnapshot.make(
            isTracker: true, carPosition: position(offset: nil, ownOffset: 800), device: nil,
            carState: .joining, mainRoute: mainRoute, ownRoute: own, now: t0))
        #expect(snap.route?.length == own.length)
        #expect(snap.previousOffset == 800)
    }

    @Test func joiningCarWithoutAnOwnRouteFallsBackToTheMainRoute() throws {
        let snap = try #require(MapReportSnapshot.make(
            isTracker: true, carPosition: position(offset: 55), device: nil,
            carState: .joining, mainRoute: mainRoute, ownRoute: nil, now: t0))
        #expect(snap.route?.length == mainRoute.length)
        #expect(snap.previousOffset == 55)
    }

    @Test func nonTrackerUsesThePhone() throws {
        let snap = try #require(MapReportSnapshot.make(
            isTracker: false, carPosition: position(), device: device, carState: .convoy,
            mainRoute: mainRoute, ownRoute: nil, now: t0))
        #expect(snap.coordinate.latitude == 1)
        #expect(snap.heading == 77)
        #expect(snap.previousOffset == nil)
    }

    @Test func fallsBackToTheOtherSourceAndThenToNothing() {
        // Non-tracker without a phone fix uses the car's position.
        #expect(MapReportSnapshot.make(
            isTracker: false, carPosition: position(lat: 9), device: nil, carState: .convoy,
            mainRoute: nil, ownRoute: nil, now: t0)?.coordinate.latitude == 9)
        // Tracker with no position yet uses the phone.
        #expect(MapReportSnapshot.make(
            isTracker: true, carPosition: nil, device: device, carState: .convoy,
            mainRoute: nil, ownRoute: nil, now: t0)?.coordinate.latitude == 1)
        #expect(MapReportSnapshot.make(
            isTracker: true, carPosition: nil, device: nil, carState: .convoy,
            mainRoute: nil, ownRoute: nil, now: t0) == nil)
    }
}

// MARK: - Model

@MainActor
struct TripMapModelTests {
    private func trip() -> Trip {
        .fixture(
            route: Polyline.encode(mainRoute.coordinates),
            destination: Destination(name: "Ipoh", coordinate: GeoPoint(latitude: 0.1, longitude: 100)))
    }

    private func fixedModel() -> TripMapModel {
        TripMapModel(session: nil, convoy: ConvoyModel(clock: { t0 }))
    }

    @Test func feedsMarkersOverlaysAndCamera() {
        let model = fixedModel()
        let own = Polyline.encode(ownCoordinates)
        let cars = [car("a", lead: true), car("j", name: "Hafiz’s Hilux", number: 2, state: .joining, route: own)]
        let positions = [
            "a": position(lat: 0.05, lon: 100, offset: 5500, age: 5),
            "j": position(lat: 0.04, lon: 99.97, offset: nil, ownOffset: 3000, age: 5),
        ]
        model.apply(trip: trip(), myCar: cars[0], myCarId: "a", positions: positions, isTracker: true)
        model.setCars(cars)
        #expect(model.markers.map(\.id) == ["a", "j"])
        #expect(model.overlays.map(\.id) == ["j"])
        #expect(model.tripCode == "K7M 2QX")
        #expect(model.convoy.title == "1 in Convoy")
        #expect(model.mainRouteCoordinates.count == 2)
        guard case .follow(let center, _)? = model.cameraTarget else {
            Issue.record("expected follow target")
            return
        }
        #expect(abs(center.longitude - 100) < 1e-9)
        model.mode = .fit
        guard case .fit? = model.cameraTarget else {
            Issue.record("expected fit target")
            return
        }
        model.mode = .free
        #expect(model.cameraTarget == nil)
    }

    @Test func stopCarFixesLeaveOutStaleCars() {
        let model = fixedModel()
        let cars = [car("a", lead: true), car("b", name: "Wyna’s X70", number: 2)]
        model.apply(
            trip: trip(), myCar: cars[0], myCarId: "a",
            positions: ["a": position(offset: 5500, age: 5), "b": position(offset: 4000, age: 120)], isTracker: true)
        model.setCars(cars)
        #expect(Set(model.stopCarFixes(now: t0).keys) == ["a"])
    }

    @Test func oldDeviceFixDoesNotGiveASpeed() {
        let model = fixedModel()
        model.device = DeviceFix(coordinate: MapCoordinate(latitude: 0, longitude: 100), course: 0, speed: 25, at: t0.addingTimeInterval(-30))
        #expect(model.phoneSpeed(now: t0) == nil)
        model.device = DeviceFix(coordinate: MapCoordinate(latitude: 0, longitude: 100), course: 0, speed: 25, at: t0.addingTimeInterval(-3))
        #expect(model.phoneSpeed(now: t0) == 25)
    }

    @Test func mergedCarDropsItsOverlay() {
        let model = fixedModel()
        let own = Polyline.encode(ownCoordinates)
        let cars = [car("j", state: .joining, route: own)]
        model.apply(trip: trip(), myCar: nil, myCarId: nil, positions: [:], isTracker: false)
        model.setCars(cars)
        #expect(model.overlays.map(\.id) == ["j"])
        // Its position now has a convoy offset: it is in the convoy list and the route goes.
        model.apply(
            trip: trip(), myCar: nil, myCarId: nil,
            positions: ["j": position(offset: 3000)], isTracker: false)
        #expect(model.overlays.isEmpty)
        #expect(model.markers.first?.isJoining == false)
    }

    @Test func reportContextNeedsASession() {
        let model = fixedModel()
        #expect(model.reportContext(authorId: "u") == nil)
        #expect(model.reportSnapshot() == nil)
    }

    @Test func codeFormatting() {
        #expect(TripMapModel.formatCode("K7M2QX") == "K7M 2QX")
        #expect(TripMapModel.formatCode("AB") == "AB")
    }
}

/// Runs against the local emulators; see TripServiceTests.
@Suite(.emulator, .serialized)
@MainActor
struct TripMapEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    @Test func twoCarsWithPositionsShowUpAsTwoMarkers() async throws {
        let ids = try await EmulatorTrip.make(name: "Map", route: Fixtures.longRoute)
        let uid = ids.uid

        let db = Firestore.firestore()
        let second = Car(
            id: nil, name: "Wyna's car", color: "#D9480F", trackerUserId: uid, isLead: false, route: nil,
            mergeOffset: nil, state: .convoy, number: 2)
        let secondRef = db.collection(FirestorePaths.cars(tripId: ids.tripId)).document()
        try secondRef.setData(from: second)

        let session = TripSession(tripId: ids.tripId, userId: uid, tracker: FakeTrackingController())
        session.start()
        let model = TripMapModel(session: session)
        model.start()
        defer {
            model.stop()
            session.stop()
        }

        var builder = PositionBuilder(mainRoute: RouteLine(Polyline.decode("_p~iF~ps|U_ulLnnqC")), carRoute: nil)
        let writer = FirestorePositionWriter()
        let first = builder.build(
            from: LocationFix(latitude: 38.5, longitude: -120.2, speed: 20, course: 90, timestamp: Date()), battery: nil)
        let other = builder.build(
            from: LocationFix(latitude: 40.7, longitude: -120.95, speed: 22, course: 90, timestamp: Date()), battery: nil)
        try await writer.write(first, tripId: ids.tripId, carId: ids.carId)
        try await writer.write(other, tripId: ids.tripId, carId: secondRef.documentID)

        await waitUntil(.seconds(10)) {
            model.sync()
            return model.markers.count == 2
        }
        #expect(model.markers.count == 2)
        #expect(Set(model.markers.map(\.id)) == [ids.carId, secondRef.documentID])
        #expect(Set(model.markers.compactMap(\.number)) == [1, 2])
        #expect(model.markers.first(where: { $0.id == ids.carId })?.heading == 90)
    }
}

// MARK: - Chip placement and stop host

struct MapChipPlacementTests {
    @Test func chipStaysOnTheRightWhenItFits() {
        #expect(MapChipPlacement.side(markerX: 100, chipWidth: 80, containerWidth: 430) == .trailing)
        #expect(MapChipPlacement.side(markerX: nil, chipWidth: 80, containerWidth: 430) == .trailing)
        #expect(MapChipPlacement.side(markerX: 300, chipWidth: 80, containerWidth: 0) == .trailing)
    }

    @Test func chipFlipsLeftNearTheRightEdge() {
        // The stale chip "Daniel · 2 min ago" (~140 pt) beside a marker at x = 330 on a 430 pt screen.
        #expect(MapChipPlacement.side(markerX: 330, chipWidth: 140, containerWidth: 430) == .leading)
    }

    @Test func chipKeepsClearOfTheModeControl() {
        // Would fit before the screen edge but not before the control's column.
        #expect(MapChipPlacement.side(markerX: 260, chipWidth: 80, containerWidth: 430) == .leading)
        #expect(MapChipPlacement.side(markerX: 230, chipWidth: 80, containerWidth: 430) == .trailing)
    }

    @Test func chipStaysRightWhenNeitherSideFitsAndLeftIsWorse() {
        #expect(MapChipPlacement.side(markerX: 40, chipWidth: 500, containerWidth: 430) == .trailing)
    }
}

@MainActor
struct MapStopContextTests {
    @Test func buildsContextFromModelAndConvoy() throws {
        let model = MapDemo.model()
        let context = try #require(model.stopContext(tripId: "t1", userId: "u-c1", isOrganizer: true))
        #expect(context.tripId == "t1")
        #expect(context.userId == "u-c1")
        #expect(context.carId == "c1")
        #expect(context.isOrganizer)
        #expect(context.mainRoute != nil)
        // The front car is Aqlan's, so suggestions start ahead of it.
        #expect(context.frontOffset() == model.convoy.convoy.first?.convoyOffset)
        #expect((context.frontOffset() ?? 0) > 0)
        #expect(context.snapshot() != nil)
    }

    @Test func noContextUntilMyCarIsKnown() {
        let model = TripMapModel(session: nil)
        #expect(model.stopContext(tripId: "t", userId: "u", isOrganizer: false) == nil)
    }
}

#if DEBUG
import SwiftUI
import UIKit

/// Hosts the demo map in a window and waits, so the simulator can be screenshotted from outside:
/// `TEST_RUNNER_IKUT_MAP_DEMO_HOLD=40 xcodebuild ... test -only-testing:ikutTests/MapDemoScreenshot`
/// then `xcrun simctl io <device> screenshot map.png`. Skipped unless the variable is set.
@MainActor
struct MapDemoScreenshot {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IKUT_MAP_DEMO_HOLD"] != nil))
    func holdDemoMapOnScreen() async throws {
        let seconds = Double(ProcessInfo.processInfo.environment["IKUT_MAP_DEMO_HOLD"] ?? "") ?? 30
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: MapDemo.view())
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(seconds))
    }
}
#endif
