import MapKit
import SwiftUI
import Testing
@testable import ikut

/// D57: Home's camera is always a fixed region, follows a fix only when it shows where you are, and every move is
/// paced (a far pick or the way back flies, a near one glides).
struct HomeCameraTests {
    private let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
    /// Every drawn route, KL to Ipoh, Melaka and Tanah Rata, as the list fits them.
    private let allRoutes = CameraView(latitude: 3.4, longitude: 101.6, latitudeSpan: 3.0)
    /// One trip's route, KL to Johor Bahru.
    private let johorRoute = CameraView(latitude: 2.3, longitude: 102.7, latitudeSpan: 2.2)
    /// A stop on a route near KL.
    private let stop = CameraView(latitude: 3.3, longitude: 101.5, latitudeSpan: 0.15)

    @Test func launchWithNoLocationIsAFixedRegion() {
        let camera = HomeCamera.launch(cachedRoutes: nil)
        #expect(!camera.followsUserLocation)
        #expect(camera.region?.center.latitude == HomeCamera.fallback.center.latitude)
        #expect(camera.region?.span.latitudeDelta == HomeCamera.fallback.span.latitudeDelta)
        let cached = MKCoordinateRegion(center: kl, span: .init(latitudeDelta: 2, longitudeDelta: 2))
        #expect(HomeCamera.launch(cachedRoutes: cached).region?.span.latitudeDelta == 2)
        // The phone's last known spot (back from a trip, or a relaunch): the view around it at once.
        let known = HomeCamera.launch(cachedRoutes: nil, here: kl, bottomObscured: 0.3, topObscured: 0.1)
        #expect(!known.followsUserLocation)
        #expect(known.region?.span.latitudeDelta == HomeCamera.hereSpan)
        #expect(HomeCamera.launch(cachedRoutes: cached, here: kl).region?.span.latitudeDelta == 2)
    }

    @Test func theFirstFixSetsAFixedRegionAroundYouReachedInOnePacedZoom() {
        #expect(HomeCamera.isRealMove(from: nil, to: kl))
        let here = HomeCamera.around(kl, bottomObscured: 0.3, topObscured: 0.1)
        #expect(here.span.latitudeDelta == HomeCamera.hereSpan)
        // Your spot sits in the part the sheet leaves clear: above the region's middle, below its top.
        #expect(here.center.latitude < kl.latitude)
        #expect(kl.latitude < here.center.latitude + here.span.latitudeDelta / 2)
        // From the fallback (your spot is in it): one straight zoom in of about 1.2 s, not a 0.4 s snap.
        let legs = CameraPace.legs(from: CameraView(region: HomeCamera.fallback), to: CameraView(region: here), reduceMotion: false)
        #expect(legs.count == 1)
        #expect(legs[0].curve == .settle)
        #expect(legs[0].duration > 1)
    }

    @Test func onlyARealMoveRecentresTheViewAroundYou() {
        let near = CLLocationCoordinate2D(latitude: kl.latitude + 0.001, longitude: kl.longitude)  // about 110 m
        let far = CLLocationCoordinate2D(latitude: kl.latitude + 0.01, longitude: kl.longitude)    // about 1.1 km
        #expect(!HomeCamera.isRealMove(from: kl, to: near))
        #expect(HomeCamera.isRealMove(from: kl, to: far))
        #expect(HomeCamera.recentreMeters > 500 && HomeCamera.recentreMeters < 600)
    }

    @Test func aFixMovesTheCameraOnlyWhenItShowsWhereYouAre() {
        func follows(_ mode: HomeSheet.Mode, routes: Bool = false, place: Bool = false, panned: Bool = false) -> Bool {
            HomeCamera.followsFixes(mode: mode, hasRoutes: routes, hasPlace: place, positionedByUser: panned)
        }
        #expect(follows(.list))
        #expect(!follows(.list, routes: true))
        #expect(!follows(.list, panned: true))
        #expect(follows(.whereTo))
        #expect(!follows(.whereTo, place: true))
        #expect(!follows(.whereTo, routes: true))
        #expect(!follows(.newTrip))
        #expect(!follows(.leftTrip))
        #expect(!follows(.join))
    }

    @Test func whereToWithNoPlaceKeepsAFixedRegion() {
        let place = MKCoordinateRegion(center: .init(latitude: 4.6, longitude: 101.09), span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2))
        // No place and nothing known: the camera keeps the fixed region it has (no follow mode).
        #expect(HomeCamera.create(place: nil, here: nil, follows: true, bottomObscured: 0.5, topObscured: 0.1) == nil)
        // No place, routes on the map: stays on them.
        #expect(HomeCamera.create(place: nil, here: kl, follows: false, bottomObscured: 0.5, topObscured: 0.1) == nil)
        // No place, the camera on you: a fixed region around you above Where to?'s sheet.
        let around = HomeCamera.create(place: nil, here: kl, follows: true, bottomObscured: 0.5, topObscured: 0.1)
        #expect(around?.span.latitudeDelta == HomeCamera.hereSpan)
        #expect((around?.center.latitude ?? 99) < kl.latitude)
        // A place wins.
        #expect(HomeCamera.create(place: place, here: kl, follows: true, bottomObscured: 0.5, topObscured: 0.1)?.center.latitude == 4.6)
    }

    @Test func aFarPickOrTheWayBackFliesANearOneGlides() {
        // All routes to the Johor trip, a screen width over: paced, one glide.
        #expect(HomeCamera.step(animated: true, flyingTo: nil, seen: allRoutes, to: johorRoute) == .fly)
        // A stop on a route: 4+ halvings in, one paced zoom, well over the old 0.4 s.
        #expect(HomeCamera.step(animated: true, flyingTo: nil, seen: allRoutes, to: stop) == .fly)
        let toStop = CameraPace.legs(from: allRoutes, to: stop, reduceMotion: false)
        #expect(toStop.map(\.duration).reduce(0, +) > 1)
        // Back to trips from the stop, far down south: out, across, and in.
        let farStop = CameraView(latitude: 1.5, longitude: 103.7, latitudeSpan: 0.15)
        let back = CameraPace.legs(from: farStop, to: allRoutes, reduceMotion: false)
        #expect(back.count == 2)
        #expect(back[0].curve == .pullOut)
        // A near move (the next result on Where to?, about 10 km over): one short glide.
        let pin = CameraView(latitude: 4.6, longitude: 101.09, latitudeSpan: 0.2)
        let nextPin = CameraView(latitude: 4.65, longitude: 101.17, latitudeSpan: 0.2)
        #expect(HomeCamera.step(animated: true, flyingTo: nil, seen: pin, to: nextPin) == .fly)
        let glide = CameraPace.legs(from: pin, to: nextPin, reduceMotion: false)
        #expect(glide.count == 1)
        #expect(glide[0].curve == .glide)
        #expect(glide[0].duration < 1)
        // A settling refit that barely changes the view: the shortest glide.
        let settled = CameraView(latitude: johorRoute.latitude + 0.01, longitude: johorRoute.longitude, latitudeSpan: johorRoute.latitudeSpan)
        #expect(HomeCamera.step(animated: true, flyingTo: nil, seen: johorRoute, to: settled) == .nudge)
        // With Reduce Motion: one short ease, no pull-out.
        #expect(CameraPace.legs(from: farStop, to: allRoutes, reduceMotion: true).count == 1)
    }

    @Test func aPlacedRefitDuringAFlightWaitsForItToLand() {
        let settled = CameraView(latitude: johorRoute.latitude + 0.01, longitude: johorRoute.longitude, latitudeSpan: johorRoute.latitudeSpan)
        #expect(HomeCamera.step(animated: false, flyingTo: johorRoute, seen: allRoutes, to: settled) == .hold)
        #expect(HomeCamera.step(animated: false, flyingTo: johorRoute, seen: allRoutes, to: stop) == .place)
        #expect(HomeCamera.step(animated: false, flyingTo: nil, seen: allRoutes, to: settled) == .place)
        #expect(HomeCamera.step(animated: true, flyingTo: johorRoute, seen: allRoutes, to: settled) == .hold)
        #expect(HomeCamera.step(animated: true, flyingTo: nil, seen: nil, to: nil) == .place)
    }

    @Test func aPositionsViewIsItsRegionOrItsCamera() {
        let region = MKCoordinateRegion(center: kl, span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
        #expect(HomeCamera.view(of: .region(region)) == CameraView(region: region))
        let camera = HomeCamera.view(of: .camera(MapCamera(centerCoordinate: kl, distance: 2_220)))
        #expect(camera?.latitude == kl.latitude)
        #expect(abs((camera?.latitudeSpan ?? 0) - 0.02) < 1e-6)
        #expect(HomeCamera.view(of: .automatic) == nil)
        #expect(HomeCamera.view(of: .userLocation(fallback: .automatic)) == nil)
    }

    @Test func leftTripPaddingFollowsItsShortSheet() {
        let compact = HomeSheet.compactHeight
        let left = HomeSheet.legalInset(.leftTrip, compact: compact)
        // Legal rides just above the left trip's short sheet, not the list's 110 pt higher.
        #expect(left == HomeSheet.height(.leftTrip, compact: compact) + HomeSheet.detentExtra)
        #expect(left < HomeSheet.legalInset(.list, compact: compact))
        // Every other mode keeps the list's (Where to?, New trip and Join frame inside it, `createInsets`).
        for mode in [HomeSheet.Mode.list, .whereTo, .newTrip, .join] {
            #expect(HomeSheet.legalInset(mode, compact: compact) == HomeSheet.legalInset(compact: compact))
        }
        // The route is framed above the short sheet with no gap: the camera keeps nothing extra.
        let insets = TripsHomeView.obscured(mapHeight: 874, sheet: HomeSheet.height(.leftTrip, compact: compact), padding: left)
        #expect(insets.bottom == 0)
        // It scales with the text size as the sheet does.
        #expect(HomeSheet.legalInset(.leftTrip, compact: 390) == 390 * HomeSheet.leftTripFraction + HomeSheet.detentExtra)
    }

    /// Fresh install: the camera opened on the fallback, the first fix came in on Where to? and flew to you. Close
    /// goes back to you, not to the fallback saved before (fixes within 550 m would never move it again).
    @Test func closeOrBackReturnsToYouWhenTheListHasNoRoutes() {
        #expect(HomeCamera.back(hasRoutes: false, hereKnown: true, positionedByUser: false) == .here)
        // Routes on the list: the camera saved before (their fit).
        #expect(HomeCamera.back(hasRoutes: true, hereKnown: true, positionedByUser: false) == .saved)
        // Nothing known yet, or the person moved the map: where it was.
        #expect(HomeCamera.back(hasRoutes: false, hereKnown: false, positionedByUser: false) == .saved)
        #expect(HomeCamera.back(hasRoutes: false, hereKnown: true, positionedByUser: true) == .saved)
    }
}
