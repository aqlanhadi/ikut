import CoreLocation
import MapKit
import Foundation
import SwiftUI
import Testing
@testable import ikut

/// D118: a fitted route sits centred in the strip the sheet and the status bar leave, with the same margin either side.
/// The map is modelled as MapKit frames it: the screen's width by the screen's height less the one bottom padding, from
/// the screen's top edge, zoomed until both spans of the region fit (the larger scale of the two never exceeded).
struct RouteFitTests {
    /// Where `coordinate` lands in the framed map for `region`, in points from its top left.
    private func point(_ coordinate: CLLocationCoordinate2D, in region: MKCoordinateRegion, width: Double, height: Double) -> CGPoint {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let scale = min(width / abs(se.x - nw.x), height / abs(se.y - nw.y))
        let centre = MKMapPoint(region.center), p = MKMapPoint(coordinate)
        return CGPoint(x: width / 2 + (p.x - centre.x) * scale, y: height / 2 + (p.y - centre.y) * scale)
    }

    private struct Fixture {
        var name: String
        var lat: ClosedRange<Double>
        var lng: ClosedRange<Double>
    }

    private let fixtures = [
        Fixture(name: "long thin", lat: 3.0...3.1, lng: 101.0...103.5),
        Fixture(name: "tall", lat: 1.5...6.0, lng: 101.0...101.4),
        Fixture(name: "short", lat: 3.0...3.2, lng: 101.0...101.15),
        Fixture(name: "diagonal", lat: 2.0...4.6, lng: 100.9...103.0),
    ]

    private func route(_ f: Fixture) -> PastTripRoute {
        PastTripRoute(id: "r", name: "", destinationName: "", destinationLatitude: f.lat.upperBound,
                      destinationLongitude: f.lng.upperBound,
                      points: [[f.lat.lowerBound, f.lng.lowerBound], [f.lat.upperBound, f.lng.upperBound],
                               [f.lat.lowerBound, f.lng.upperBound], [f.lat.upperBound, f.lng.lowerBound]])
    }

    /// The lobby's own fractions (status bar, button band and flag room at the top, the medium sheet below) at a text
    /// size and screen, and the strip they leave in points.
    private func lobbyCase(scale: CGFloat, screen: CGFloat, width: CGFloat) -> (top: Double, bottom: Double, aspect: Double, framedHeight: Double) {
        let padding = LobbySheet.mapPadding(scaledMedium: LobbySheet.compactHeight * scale, screenHeight: screen)
        let safeTop: CGFloat = screen > 800 ? 62 : 20
        let cover = SheetStops.mid(scale: scale, screenHeight: screen)
        return (LobbyMapLogic.topFraction(mapHeight: screen, safeTop: safeTop, bottomPadding: padding),
                LobbyMapLogic.bottomFraction(mapHeight: screen, safeTop: safeTop, cover: cover + LobbyMapLogic.startRoom, bottomPadding: padding),
                MapFit.aspect(width: width, height: screen, padding: padding), Double(screen - padding))
    }

    @Test(arguments: [CGFloat(1), 1.3, 1.6, 2.0], [(CGFloat(874), CGFloat(402)), (CGFloat(667), CGFloat(375))])
    func lobbyFitIsCentredInTheStrip(scale: CGFloat, screen: (CGFloat, CGFloat)) throws {
        let c = lobbyCase(scale: scale, screen: screen.0, width: screen.1)
        for f in fixtures {
            let r = route(f)
            let region = try #require(PastTripsMapLogic.region(fitting: [r], bottomObscured: c.bottom, topObscured: c.top, aspect: c.aspect))
            let w = Double(screen.1), h = c.framedHeight
            let pts = r.coordinates.map { point($0, in: region, width: w, height: h) }
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            let stripTop = c.top * h, stripBottom = h * (1 - c.bottom)
            let id = "\(f.name) scale \(scale) screen \(screen.0)"
            // Equal margins either side, within 1 pt of the strip's own centre.
            #expect(abs((minX) - (w - maxX)) < 1.0, "left/right \(id): \(minX) \(w - maxX)")
            #expect(abs((minY - stripTop) - (stripBottom - maxY)) < 1.0, "top/bottom \(id): \(minY - stripTop) \(stripBottom - maxY)")
            // Inside the strip, never outside it.
            #expect(minY >= stripTop - 0.5 && maxY <= stripBottom + 0.5 && minX >= -0.5 && maxX <= w + 0.5, "inside \(id)")
            // The binding axis keeps a small margin: 5% of its length plus a point for the 1.1 padding.
            let stripH = stripBottom - stripTop
            let spanY = maxY - minY, spanX = maxX - minX
            let fillsHeight = spanY >= stripH * 0.9 - 1, fillsWidth = spanX >= w * 0.9 - 1
            #expect(fillsHeight || fillsWidth, "fills one axis \(id): \(spanY)/\(stripH) \(spanX)/\(w)")
        }
    }

    /// A route with a flag drawn above its destination: the room above it is the lobby's flag room, kept clear of the
    /// status bar and the corner button.
    @Test func destinationFlagStaysBelowTheButtonBand() throws {
        let c = lobbyCase(scale: 1, screen: 874, width: 402)
        let f = fixtures[1]
        let region = try #require(PastTripsMapLogic.region(fitting: [route(f)], bottomObscured: c.bottom, topObscured: c.top, aspect: c.aspect))
        let top = point(.init(latitude: f.lat.upperBound, longitude: f.lng.upperBound), in: region, width: 402, height: c.framedHeight)
        #expect(top.y - LobbyMapLogic.flagRoom >= 62 + LobbyMapLogic.buttonBand - 0.5)
    }

    /// A wide route binds on longitude: centring by the latitude the view really shows keeps it in the middle, where
    /// the requested latitude alone put it off by most of the strip's slack.
    @Test func wideRouteIsCentredByTheLatitudeTheViewShows() throws {
        let c = lobbyCase(scale: 1, screen: 874, width: 402)
        let f = fixtures[0]
        // A strip well below the middle (a tall top cover), so the vertical shift is large.
        let top = 0.45, bottom = 0.05
        let wrong = try #require(PastTripsMapLogic.region(fitting: [route(f)], bottomObscured: bottom, topObscured: top, aspect: 100))
        let right = try #require(PastTripsMapLogic.region(fitting: [route(f)], bottomObscured: bottom, topObscured: top, aspect: c.aspect))
        func offset(_ region: MKCoordinateRegion) -> Double {
            let p = point(.init(latitude: 3.05, longitude: 102.25), in: region, width: 402, height: c.framedHeight)
            return abs(Double(p.y) - c.framedHeight * (top + 1 - bottom) / 2)
        }
        #expect(offset(right) < 1)
        #expect(offset(wrong) > 10)
    }

    @Test func focusCentresTheSpotInTheStrip() {
        let c = lobbyCase(scale: 1, screen: 874, width: 402)
        let spot = CLLocationCoordinate2D(latitude: 3.1, longitude: 101.7)
        let region = PickedTripLogic.focus(on: spot, span: 0.15, bottomObscured: c.bottom, topObscured: c.top, aspect: c.aspect)
        let p = point(spot, in: region, width: 402, height: c.framedHeight)
        #expect(abs(Double(p.y) - c.framedHeight * (c.top + 1 - c.bottom) / 2) < 1)
        #expect(abs(Double(p.x) - 201) < 1)
    }

    /// The corner buttons read one inset.
    @Test func cornerButtonsShareOneInset() {
        #expect(CornerButton.edge == 16)
        #expect(CornerButton.top == Spacing.s)
        #expect(LobbyMapLogic.buttonBand == CornerButton.top + 56 + Spacing.xs)
    }

    /// D118: a refit held for a flight in the air is what the camera is aimed at from then on, so a later fit equal to the
    /// flight's own is a real move back, not "already aimed": the stale held region no longer lands last.
    @MainActor @Test func aHeldRefitIsTheAimSoALaterFitIsNotDropped() {
        let stage = TripScreenModel()
        func position(_ lat: Double) -> MapCameraPosition {
            .region(MKCoordinateRegion(center: .init(latitude: lat, longitude: 101.4), span: .init(latitudeDelta: 5, longitudeDelta: 3)))
        }
        let flying = position(3.65)
        stage.fly(to: flying, view: CameraView(latitude: 3.65, longitude: 101.4, latitudeSpan: 5), reduceMotion: false)
        #expect(stage.flight.isFlying)
        stage.hold(nudgeTo: position(4.07), reduceMotion: false)
        #expect(stage.aimed == position(4.07))
        #expect(stage.aimed != flying)
        stage.hold(nudgeTo: flying, reduceMotion: false)
        #expect(stage.aimed == flying)
        stage.flight.cancel()
    }
}
