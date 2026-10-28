import CoreLocation
import FirebaseFirestore
import Foundation
import SwiftUI
import Testing
@testable import ikut

/// D70: where the driving map draws my car (and aims the follow camera) on each of the phone's own fixes, and how
/// long the glide there takes (`FollowGlide`).
struct FollowGlideTests {
    typealias Fix = FollowGlide.Fix

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// On the E1 near Tapah, heading north at 100 km/h (27.8 m/s).
    private let start = MapCoordinate(latitude: 4.2000, longitude: 101.2600)
    /// About 28 m north of `start`.
    private var next: MapCoordinate { MapCoordinate(latitude: 4.2000 + 27.8 / 111_195, longitude: 101.2600) }

    private func meters(_ a: MapCoordinate, _ b: MapCoordinate) -> Double {
        RouteLine.haversine(a.clCoordinate, b.clCoordinate)
    }

    @Test func theFirstFixPlacesTheCarWithoutAGlide() {
        let aim = FollowGlide.aim(previous: nil, latest: Fix(coordinate: start, course: 0, speed: 27.8, at: t0), now: t0)
        #expect(aim.coordinate == start)
        #expect(aim.duration == 0)
        #expect(aim.heading == 0)
    }

    @Test func eachFixGlidesOverMostOfTheIntervalSoTheMapNeverStandsStill() {
        let aim = FollowGlide.aim(
            previous: Fix(coordinate: start, course: 0, speed: 27.8, at: t0),
            latest: Fix(coordinate: next, course: 0, speed: 27.8, at: t0 + 1), now: t0 + 1)
        // A second between fixes: a 0.9 s linear glide, ending a moment before the next fix (`share`).
        #expect(abs(aim.duration - 0.9) < 1e-9)
        #expect(aim.coordinate == next)
        // A car position every 5 s (no own fix): the glide spreads over those 5 s.
        let slow = FollowGlide.aim(
            previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: next, at: t0 + 5), now: t0 + 5.3)
        #expect(abs(slow.duration - 4.5) < 1e-9)
    }

    @Test func aFixAfterAGapOrFarAwayIsPlacedNotGlided() {
        // Out of a tunnel, 20 s later: no 20 s glide behind the car.
        let gap = FollowGlide.aim(
            previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: next, at: t0 + 20), now: t0 + 20)
        #expect(gap.duration == 0)
        // Two fixes 3 km apart a second apart (a wrong fix, a relaunch): a jump, which the camera paces itself.
        let far = MapCoordinate(latitude: 4.227, longitude: 101.26)
        let jump = FollowGlide.aim(
            previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: far, at: t0 + 1), now: t0 + 1)
        #expect(jump.duration == 0)
    }

    @Test func twoFixesWithTheSameTimeGlideOverTheUsualSecond() {
        let aim = FollowGlide.aim(
            previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: next, at: t0), now: t0)
        #expect(abs(aim.duration - FollowGlide.firstInterval * FollowGlide.share) < 1e-9)
    }

    @Test func aLateFixIsCarriedOnAlongItsCourseButNoFurtherThanOneInterval() {
        let previous = Fix(coordinate: start, course: 0, speed: 27.8, at: t0)
        let latest = Fix(coordinate: next, course: 0, speed: 27.8, at: t0 + 1)
        // Read 0.4 s after it was taken: carried 0.4 s on, about 11 m north.
        let late = FollowGlide.aim(previous: previous, latest: latest, now: t0 + 1.4)
        #expect(abs(meters(next, late.coordinate) - 11.1) < 0.5)
        #expect(late.coordinate.latitude > next.latitude)
        // Read 30 s late: never more than one interval (1 s, 28 m) ahead of the fix.
        let stale = FollowGlide.aim(previous: previous, latest: latest, now: t0 + 31)
        #expect(meters(next, stale.coordinate) <= 27.8 + 0.5)
        // A clock that reads before the fix: nothing carried.
        let early = FollowGlide.aim(previous: previous, latest: latest, now: t0 + 0.5)
        #expect(early.coordinate == next)
        // `maxLead` 0 (another car's position, timed by the server's clock): never carried.
        let other = FollowGlide.aim(previous: previous, latest: latest, now: t0 + 1.4, maxLead: 0)
        #expect(other.coordinate == next)
    }

    @Test func aStoppedCarOrAnUnknownCourseIsNeverCarriedOn() {
        let previous = Fix(coordinate: start, at: t0)
        let parked = FollowGlide.aim(
            previous: previous, latest: Fix(coordinate: start, course: 0, speed: 0.2, at: t0 + 1), now: t0 + 1.8)
        #expect(parked.coordinate == start)
        let noCourse = FollowGlide.aim(
            previous: previous, latest: Fix(coordinate: next, course: -1, speed: 27.8, at: t0 + 1), now: t0 + 1.8)
        #expect(noCourse.coordinate == next)
    }

    @Test func theHeadingIsTheCourseOrElseTheWayTheCarMoved() {
        let moved = FollowGlide.aim(previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: next, at: t0 + 1), now: t0 + 1)
        #expect(abs((moved.heading ?? -1) - 0) < 0.5)
        let course = FollowGlide.aim(
            previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: next, course: 10, speed: 27.8, at: t0 + 1), now: t0 + 1)
        #expect(course.heading == 10)
        let stillStanding = FollowGlide.aim(previous: Fix(coordinate: start, at: t0), latest: Fix(coordinate: start, at: t0 + 1), now: t0 + 1)
        #expect(stillStanding.heading == nil)
    }

    @Test func theGlideIsLinearWithoutReduceMotionAndAStepWithIt() {
        #expect(Motion.follow(interval: 0.9, reduceMotion: false) == .linear(duration: 0.9))
        #expect(Motion.follow(interval: 0.9, reduceMotion: true) == nil)
        #expect(Motion.follow(interval: 0, reduceMotion: false) == nil)
    }

    @Test func aFollowOrFitStepGlidesLinearlyAndAChangeOfModeKeepsTheCameraGlide() {
        let a = CameraTarget.follow(center: start, distance: 2_500)
        let b = CameraTarget.follow(center: next, distance: 2_500)
        let fit = CameraTarget.fit(GeoRegion(center: start, latitudeSpan: 0.1, longitudeSpan: 0.1))
        #expect(CameraInsetMove.isStep(from: a, to: b))
        #expect(CameraInsetMove.isStep(from: fit, to: fit))
        #expect(!CameraInsetMove.isStep(from: a, to: fit))
        #expect(!CameraInsetMove.isStep(from: nil, to: a))
        #expect(CameraInsetMove.animation(.none, reduceMotion: false, step: 0.9) == .linear(duration: 0.9))
        #expect(CameraInsetMove.animation(.none, reduceMotion: true, step: 0.9) == nil)
        #expect(CameraInsetMove.animation(.none, reduceMotion: false, step: 0) == nil)
        #expect(CameraInsetMove.animation(.none, reduceMotion: false, step: nil) == DrivingGlance.cameraAnimation(reduceMotion: false))
        // A sheet or banner change keeps its own motion, step or not.
        #expect(CameraInsetMove.animation(.sheet, reduceMotion: false, step: 0.9) == Motion.sheet(reduceMotion: false))
    }
}

/// D70: the driving map's model feeds my car and the camera from the phone's own fixes, the tracker too.
@MainActor
struct FollowGlideModelTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let tapah = MapCoordinate(latitude: 4.2000, longitude: 101.2600)
    private let bidor = MapCoordinate(latitude: 4.1000, longitude: 101.2900)

    private func position(_ c: MapCoordinate, at: Date) -> Position {
        Position(id: nil, location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: 27.8, heading: 0,
                 routeOffset: 0, convoyOffset: 0, battery: 0.8, updatedAt: at)
    }

    private func model(isTracker: Bool, carAt: MapCoordinate) -> TripMapModel {
        let model = TripMapModel(session: nil)
        let car = Car(id: "c1", name: "Aqlan’s Myvi", color: "#2563EB", trackerUserId: "u1", isLead: true, route: nil,
                      mergeOffset: nil, state: .convoy, number: 1)
        model.setCars([car])
        model.apply(trip: nil, myCar: car, myCarId: "c1", positions: ["c1": position(carAt, at: t0)], isTracker: isTracker)
        return model
    }

    @Test func theTrackerFollowsItsOwnFixesNotTheFiveSecondWrite() throws {
        let model = model(isTracker: true, carAt: tapah)
        #expect(model.myCoordinate == tapah)
        model.receive(DeviceFix(coordinate: bidor, course: -1, at: t0 + 1), now: t0 + 1)
        #expect(model.myCoordinate == bidor)
        guard case .follow(let center, _)? = model.cameraTarget else { Issue.record("not following"); return }
        #expect(center == bidor)
        // My car's marker is drawn where the camera aims.
        let mine = try #require(model.markers.first { $0.isMine })
        #expect(mine.coordinate == bidor)
    }

    @Test func aPassengersOwnCarMarkerStaysOnTheCarsPosition() throws {
        let model = model(isTracker: false, carAt: tapah)
        model.receive(DeviceFix(coordinate: bidor, course: -1, at: t0 + 1), now: t0 + 1)
        #expect(model.myCoordinate == bidor)
        let mine = try #require(model.markers.first { $0.isMine })
        #expect(mine.coordinate == tapah)
    }

    @Test func eachFixSetsTheGlideTimeForMyCarAndTheCamera() {
        let model = model(isTracker: true, carAt: tapah)
        model.receive(DeviceFix(coordinate: tapah, course: -1, at: t0 + 1), now: t0 + 1)
        #expect(model.glideTime(for: "c1") == 0)
        model.receive(DeviceFix(coordinate: tapah, course: -1, at: t0 + 2), now: t0 + 2)
        #expect(abs(model.glideTime(for: "c1") - 0.9) < 1e-9)
        #expect(abs((model.lastGlide ?? 0) - 0.9) < 1e-9)
    }

    @Test func anotherCarGlidesOverTheTimeBetweenItsWrites() {
        let model = model(isTracker: true, carAt: tapah)
        let car2 = Car(id: "c2", name: "Wyna’s X70", color: "#D9480F", trackerUserId: "u2", isLead: false, route: nil,
                       mergeOffset: nil, state: .convoy, number: 2)
        model.setCars(model.cars + [car2])
        let mine = position(tapah, at: t0)
        model.apply(trip: nil, myCar: model.myCar, myCarId: "c1",
                    positions: ["c1": mine, "c2": position(bidor, at: t0)], isTracker: true)
        #expect(model.glideTime(for: "c2") == 0)
        let on = MapCoordinate(latitude: bidor.latitude + 0.001, longitude: bidor.longitude)
        model.apply(trip: nil, myCar: model.myCar, myCarId: "c1",
                    positions: ["c1": mine, "c2": position(on, at: t0 + 5)], isTracker: true)
        #expect(abs(model.glideTime(for: "c2") - 4.5) < 1e-9)
    }
}
