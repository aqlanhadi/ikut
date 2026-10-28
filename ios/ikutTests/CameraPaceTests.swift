import MapKit
import SwiftUI
import Testing
@testable import ikut

/// D57: every camera move on the one map is paced by how far it travels and how much it zooms.
struct CameraPaceTests {
    /// Peninsular Malaysia, about as the app's fallback shows it.
    private let country = CameraView(latitude: 4.2, longitude: 102.0, latitudeSpan: 8)
    /// A street in KL, about a 2.5 km follow camera.
    private let street = CameraView(latitude: 3.139, longitude: 101.687, latitudeSpan: 0.022)
    /// The KL-Ipoh route, as the lobby fits it.
    private let route = CameraView(latitude: 4.1, longitude: 101.3, latitudeSpan: 1.6)
    /// Johor Bahru, far south of the route.
    private let johor = CameraView(latitude: 1.49, longitude: 103.74, latitudeSpan: 0.022)

    @Test func durationGrowsWithDistanceAndZoom() {
        let near = CameraView(latitude: street.latitude + 0.002, longitude: street.longitude, latitudeSpan: street.latitudeSpan)
        let farther = CameraView(latitude: street.latitude + 0.02, longitude: street.longitude, latitudeSpan: street.latitudeSpan)
        #expect(CameraPace.duration(from: street, to: near) < CameraPace.duration(from: street, to: farther))
        let zoomed = CameraView(latitude: street.latitude, longitude: street.longitude, latitudeSpan: 0.2)
        let zoomedMore = CameraView(latitude: street.latitude, longitude: street.longitude, latitudeSpan: 1.0)
        #expect(CameraPace.duration(from: street, to: zoomed) < CameraPace.duration(from: street, to: zoomedMore))
    }

    @Test func durationStaysWithinTheBounds() {
        let same = CameraPace.duration(from: street, to: street)
        #expect(same == CameraPace.minimum)
        #expect(CameraPace.duration(from: country, to: street) == CameraPace.maximum)
        let world = CameraView(latitude: 0, longitude: 0, latitudeSpan: 160)
        #expect(CameraPace.duration(from: world, to: johor) == CameraPace.maximum)
    }

    @Test func travelIsInScreenWidthsAtTheWiderSpan() {
        // Half a degree east at the equator, in a view 1° tall: about 0.5 / (1 × aspect) widths.
        let a = CameraView(latitude: 0, longitude: 0, latitudeSpan: 1)
        let b = CameraView(latitude: 0, longitude: 0.5, latitudeSpan: 0.1)
        #expect(abs(CameraPace.travel(from: a, to: b) - 0.5 / CameraPace.aspect) < 1e-9)
        #expect(abs(CameraPace.zoom(from: a, to: b) - log2(10)) < 1e-9)
        #expect(CameraPace.travel(from: a, to: b) == CameraPace.travel(from: b, to: a))
    }

    @Test func aLongHopPullsOutTravelsAndSettles() {
        let legs = CameraPace.legs(from: route, to: johor, reduceMotion: false)
        #expect(legs.count == 2)
        #expect(legs.map(\.curve) == [.pullOut, .settle])
        let peak = legs[0].to
        // The peak is wider than either end and has both in view.
        #expect(peak.latitudeSpan > route.latitudeSpan)
        #expect(abs(peak.latitude - route.latitude) < peak.latitudeSpan / 2)
        #expect(abs(peak.latitude - johor.latitude) < peak.latitudeSpan / 2)
        #expect(legs[1].to == johor)
        #expect(legs.allSatisfy { $0.duration >= CameraPace.minimum && $0.duration <= CameraPace.maximum })
        #expect(CameraPace.isLong(from: route, to: johor))
    }

    @Test func aZoomOutToAViewThatHasYouInItIsOneLeg() {
        // Your car to the whole route: the car is inside the route's view, so it zooms straight out.
        let car = CameraView(latitude: 4.2, longitude: 101.26, latitudeSpan: 0.022)
        #expect(CameraPace.nests(car, route))
        #expect(CameraPace.legs(from: car, to: route, reduceMotion: false).map(\.curve) == [.settle])
        #expect(!CameraPace.nests(route, johor))
    }

    @Test func countryToStreetInViewZoomsStraightIn() {
        // Your street is already in the country view: no pull-out first, one slow zoom in.
        let legs = CameraPace.legs(from: country, to: street, reduceMotion: false)
        #expect(legs.count == 1)
        #expect(legs[0].curve == .settle)
        #expect(legs[0].duration == CameraPace.maximum)
    }

    @Test func aShortHopGlides() {
        let next = CameraView(latitude: street.latitude + 0.01, longitude: street.longitude + 0.01, latitudeSpan: 0.03)
        let legs = CameraPace.legs(from: street, to: next, reduceMotion: false)
        #expect(legs == [CameraPace.Leg(to: next, duration: CameraPace.duration(from: street, to: next), curve: .glide)])
        #expect(!CameraPace.isLong(from: street, to: next))
    }

    @Test func reduceMotionIsOneShortCalmMove() {
        for (from, to) in [(route, johor), (country, street), (street, street)] {
            let legs = CameraPace.legs(from: from, to: to, reduceMotion: true)
            #expect(legs == [CameraPace.Leg(to: to, duration: CameraPace.reduced, curve: .reduced)])
        }
        #expect(CameraPace.reduced < CameraPace.minimum)
        #expect(CameraPace.animation(CameraPace.Leg(to: street, duration: CameraPace.reduced, curve: .reduced))
                == .easeInOut(duration: CameraPace.reduced))
    }

    @Test func anUnknownStartGlidesAtTheShortestPace() {
        #expect(CameraPace.legs(from: nil, to: street, reduceMotion: false)
                == [CameraPace.Leg(to: street, duration: CameraPace.minimum, curve: .glide)])
    }

    @Test func smallAdjustmentsAreFollowSizedOnly() {
        // A 140 m follow step at 2.5 km is small; the convoy fit to your car is not.
        let step = CameraView(latitude: street.latitude + 0.00126, longitude: street.longitude, latitudeSpan: street.latitudeSpan)
        #expect(CameraPace.isSmallAdjustment(from: street, to: step))
        #expect(!CameraPace.isSmallAdjustment(from: route, to: street))
        #expect(!CameraPace.isSmallAdjustment(from: street, to: johor))
    }

    /// What arrives mid-flight on the driving map: the lobby-to-driving entry is in the air to your car.
    @Test func midFlightAFollowStepOrARecentreWaitsAndAHazardTakesOver() {
        let landing = street
        // A follow step: 140 m on at 100 km/h.
        let step = CameraView(latitude: landing.latitude + 0.00126, longitude: landing.longitude, latitudeSpan: landing.latitudeSpan)
        #expect(CameraPace.decide(flyingTo: landing, seen: route, to: step) == .hold)
        // The sheet folding: the aim moves a quarter of the view's height.
        let recentre = CameraView(latitude: landing.latitude + landing.latitudeSpan / 4, longitude: landing.longitude,
                                  latitudeSpan: landing.latitudeSpan)
        #expect(CameraPace.decide(flyingTo: landing, seen: route, to: recentre) == .hold)
        // The hazard approach: you and the debris 300 m ahead, framed tighter.
        let hazard = CameraView(latitude: landing.latitude + 0.0014, longitude: landing.longitude, latitudeSpan: 0.01)
        #expect(CameraPace.decide(flyingTo: landing, seen: route, to: hazard) == .fly)
        // At rest: the follow step keeps the short glide, the hazard is paced.
        #expect(CameraPace.decide(flyingTo: nil, seen: landing, to: step) == .nudge)
        #expect(CameraPace.decide(flyingTo: nil, seen: landing, to: hazard) == .fly)
        #expect(CameraPace.decide(flyingTo: nil, seen: nil, to: step) == .fly)
    }

    /// Review fix 5: the follow height re-aimed once the map's scale is read is held unless it's a whole halving off.
    @Test func theFirstScaleReadingDoesNotRestartTheEntryFlight() {
        let estimated = street
        let measured = CameraView(latitude: street.latitude + 0.002, longitude: street.longitude, latitudeSpan: street.latitudeSpan * 1.6)
        #expect(CameraPace.decide(flyingTo: estimated, seen: route, to: measured) == .fly)
        #expect(CameraPace.decide(flyingTo: estimated, seen: route, to: measured, reaim: true) == .hold)
        let wayOff = CameraView(latitude: street.latitude, longitude: street.longitude, latitudeSpan: street.latitudeSpan * 2.5)
        #expect(CameraPace.decide(flyingTo: estimated, seen: route, to: wayOff, reaim: true) == .fly)
    }

    @Test func aHeldRefitEasesWithReduceMotion() {
        #expect(CameraPace.nudgeAnimation(reduceMotion: true) == .easeInOut(duration: CameraPace.reduced))
        #expect(CameraPace.nudgeAnimation(reduceMotion: false) == .smooth(duration: CameraPace.minimum))
    }

    @Test func viewsComeFromRegionsAndCameras() {
        let region = MKCoordinateRegion(center: .init(latitude: 3, longitude: 101), span: .init(latitudeDelta: 0.5, longitudeDelta: 0.4))
        #expect(CameraView(region: region) == CameraView(latitude: 3, longitude: 101, latitudeSpan: 0.5))
        #expect(CameraView(region: CameraView(region: region).region) == CameraView(region: region))
    }
}

/// The flight runner: legs one after another, a new move taking over the one in flight.
@MainActor
struct CameraFlightTests {
    private let route = CameraView(latitude: 4.1, longitude: 101.3, latitudeSpan: 1.6)
    private let johor = CameraView(latitude: 1.49, longitude: 103.74, latitudeSpan: 0.022)
    private let ipoh = CameraView(latitude: 4.6, longitude: 101.09, latitudeSpan: 0.022)

    private final class Recorder {
        var set: [MapCameraPosition] = []
        var userMoved = false
    }

    /// Legs last a hundredth of their real time.
    private func flight() -> CameraFlight { CameraFlight(timeScale: 0.01) }

    @Test func aLongHopRunsBothLegs() async {
        let flight = flight()
        let rec = Recorder()
        let target = MapCameraPosition.region(johor.region)
        flight.fly(to: target, view: johor, from: route, reduceMotion: false) { rec.set.append($0) }
        // The first leg starts at once, in the caller's transaction.
        #expect(rec.set.count == 1)
        #expect(flight.isFlying)
        await waitUntil { !flight.isFlying }
        #expect(rec.set.count == 2)
        #expect(rec.set.last == target)
    }

    @Test func aNewMoveTakesOverTheOneInFlight() async {
        let flight = flight()
        let rec = Recorder()
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false) { rec.set.append($0) }
        // Mid pull-out, the person asks for Ipoh: the Johor leg never runs.
        #expect(CameraPace.decide(flyingTo: flight.destination, seen: route, to: ipoh) == .fly)
        flight.fly(to: .region(ipoh.region), view: ipoh, from: route, reduceMotion: false) { rec.set.append($0) }
        await waitUntil { !flight.isFlying }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rec.set.contains(.region(johor.region)))
        #expect(rec.set.last == .region(ipoh.region))
    }

    @Test func aSmallAdjustmentWaitsForTheFlightToLand() async {
        let flight = flight()
        let rec = Recorder()
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false) { rec.set.append($0) }
        let nudged = CameraView(latitude: johor.latitude + 0.001, longitude: johor.longitude, latitudeSpan: johor.latitudeSpan)
        #expect(CameraPace.decide(flyingTo: flight.destination, seen: route, to: nudged) == .hold)
        flight.hold { rec.set.append(.region(nudged.region)) }
        await waitUntil { !flight.isFlying }
        #expect(rec.set.suffix(2) == [.region(johor.region), .region(nudged.region)])
    }

    @Test func aGestureOrAPlacementStopsTheFlight() async {
        let flight = flight()
        let rec = Recorder()
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false,
                   continues: { !rec.userMoved }) { rec.set.append($0) }
        rec.userMoved = true
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rec.set.count == 1)
        #expect(!flight.isFlying)

        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false) { rec.set.append($0) }
        flight.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rec.set.count == 2)
        #expect(!flight.isFlying)
    }

    @Test func nothingIsInFlightToTakeOver() {
        #expect(flight().destination == nil)
        #expect(CameraPace.decide(flyingTo: flight().destination, seen: nil, to: ipoh) == .fly)
    }

    /// D67: a banner that arrives while a one-leg flight is in the air moves where it lands; no second move follows.
    @Test func aCoverChangeMidFlightRetargetsTheLastLegAndDoesNotMoveAgainAfterLanding() async {
        let flight = flight()
        let rec = Recorder()
        let near = CameraView(latitude: johor.latitude + 0.01, longitude: johor.longitude, latitudeSpan: johor.latitudeSpan)
        flight.fly(to: .region(near.region), view: near, from: johor, reduceMotion: false) { rec.set.append($0) }
        #expect(rec.set.count == 1)
        let nudged = CameraView(latitude: near.latitude + 0.001, longitude: near.longitude, latitudeSpan: near.latitudeSpan)
        #expect(flight.retarget(to: .region(nudged.region), view: nudged))
        #expect(flight.destination == nudged)
        // The last leg in the air is set again, aimed at the new place.
        #expect(rec.set == [.region(near.region), .region(nudged.region)])
        await waitUntil { !flight.isFlying }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rec.set.count == 2)
    }

    @Test func aCoverChangeDuringThePullOutAimsTheSettleLegAtTheNewPlace() async {
        let flight = flight()
        let rec = Recorder()
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false) { rec.set.append($0) }
        let nudged = CameraView(latitude: johor.latitude + 0.001, longitude: johor.longitude, latitudeSpan: johor.latitudeSpan)
        #expect(flight.retarget(to: .region(nudged.region), view: nudged))
        #expect(rec.set.count == 1)
        await waitUntil { !flight.isFlying }
        #expect(rec.set.count == 2)
        #expect(rec.set.last == .region(nudged.region))
    }

    @Test func nothingToRetargetWhenNothingFliesOrThePersonTookTheMap() {
        let flight = flight()
        #expect(!flight.retarget(to: .region(johor.region), view: johor))
        var userMoved = false
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false,
                   continues: { !userMoved }) { _ in }
        userMoved = true
        #expect(!flight.retarget(to: .region(johor.region), view: johor))
    }

    /// Review fix 1: a pan mid-flight ends it at once, so a Follow tap or a hazard after the pan runs, never held and
    /// dropped at the landing.
    @Test func aMoveAskedForAfterAPanRuns() async {
        let flight = flight()
        let rec = Recorder()
        flight.fly(to: .region(johor.region), view: johor, from: route, reduceMotion: false,
                   continues: { !rec.userMoved }) { rec.set.append($0) }
        #expect(flight.isFlying)
        rec.userMoved = true
        #expect(!flight.isFlying)
        // Follow, near the flight's landing: with the flight over it is paced from where the person left the map.
        let follow = CameraView(latitude: johor.latitude + 0.001, longitude: johor.longitude, latitudeSpan: johor.latitudeSpan)
        #expect(CameraPace.decide(flyingTo: flight.destination, seen: route, to: follow) == .fly)
        // And anything held runs now rather than at a landing that never comes.
        flight.hold { rec.set.append(.region(follow.region)) }
        #expect(rec.set.last == .region(follow.region))
    }
}
