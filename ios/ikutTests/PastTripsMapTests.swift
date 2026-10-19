import CoreLocation
import Foundation
import Testing
@testable import ikut

struct PastTripsMapTests {
    private func route(_ id: String, _ coords: [(Double, Double)], dest: (Double, Double)) -> PastTripRoute {
        PastTripRoute(id: id, name: id, destinationName: "D", destinationLatitude: dest.0, destinationLongitude: dest.1,
                      points: coords.map { [$0.0, $0.1] })
    }

    @Test func noRoutesHasNoRegion() {
        #expect(PastTripsMapLogic.region(fitting: []) == nil)
    }

    @Test func regionCoversEveryRouteAndDestination() throws {
        let a = route("a", [(3.1, 101.6), (3.5, 101.4)], dest: (4.6, 101.1))
        let b = route("b", [(2.9, 101.7)], dest: (1.5, 103.7))
        let r = try #require(PastTripsMapLogic.region(fitting: [a, b]))
        for c in a.coordinates + b.coordinates + [a.destination, b.destination] {
            #expect(abs(c.latitude - r.center.latitude) <= r.span.latitudeDelta / 2)
            #expect(abs(c.longitude - r.center.longitude) <= r.span.longitudeDelta / 2)
        }
        // Padded beyond the bare bounding box (1.5...4.6, 101.1...103.7).
        #expect(r.span.latitudeDelta > 3.1)
        #expect(r.span.longitudeDelta > 2.6)
    }

    @Test func singlePointGetsMinimumSpan() throws {
        let r = try #require(PastTripsMapLogic.region(fitting: [route("a", [], dest: (3, 101))], minSpan: 0.05))
        #expect(r.span.latitudeDelta == 0.05)
        #expect(r.span.longitudeDelta == 0.05)
        #expect(r.center.latitude == 3)
    }

    @Test func sheetPushesContentIntoVisibleTop() throws {
        let a = route("a", [(3, 101)], dest: (4, 102))
        let r = try #require(PastTripsMapLogic.region(fitting: [a], padding: 1, bottomObscured: 0.5))
        // Visible half is the top: it spans the 1° of content exactly.
        #expect(abs(r.span.latitudeDelta - 2) < 1e-9)
        let visibleBottom = r.center.latitude
        let top = r.center.latitude + r.span.latitudeDelta / 2
        #expect(abs(visibleBottom - 3) < 1e-9)
        #expect(abs(top - 4) < 1e-9)
    }

    /// Tapah → Ipoh, as on Home: the routes and flags must sit centred in the visible band between
    /// the status bar and the sheet, and the region must stay close to the routes' own size.
    @Test func fitKeepsRoutesInVisibleAreaAboveSheet() throws {
        let a = route("a", [(4.0, 101.0), (4.3, 101.1)], dest: (4.6, 101.2))
        let b = route("b", [(4.05, 101.05)], dest: (4.5, 101.15))
        let minLat = 4.0, maxLat = 4.6
        // Every height the map can report, including 0 before its first layout.
        for height: CGFloat in [0, 1, 300, 672, 778, 874] {
            let insets = TripsHomeView.obscured(mapHeight: height)
            #expect(insets.bottom > 0 && insets.bottom < 0.5, "height \(height)")
            #expect(insets.top > 0 && insets.top < 0.2, "height \(height)")
            let r = try #require(PastTripsMapLogic.region(fitting: [a, b], bottomObscured: insets.bottom,
                                                          topObscured: insets.top))
            let mapTop = r.center.latitude + r.span.latitudeDelta / 2
            let visibleTop = mapTop - r.span.latitudeDelta * insets.top
            let visibleBottom = mapTop - r.span.latitudeDelta * (1 - insets.bottom)
            #expect(visibleBottom < minLat && visibleTop > maxLat, "height \(height)")
            // Centred in the visible band.
            #expect(abs((visibleBottom + visibleTop) / 2 - (minLat + maxLat) / 2) < 1e-9)
            // The centre moves south only by the sheet's share, never out of the routes' latitudes.
            #expect(r.center.latitude >= minLat && r.center.latitude <= maxLat, "height \(height)")
            // Modest margin: within 2.5x the routes' span (1.1 padding / ~50% visible band) once
            // settled; 672 is a brief first layout with a smaller band.
            let limit = height == 672 ? 3.0 : 2.5
            #expect(r.span.latitudeDelta <= limit * (maxLat - minLat), "height \(height)")
            #expect(r.span.longitudeDelta <= 2 * 0.2)
        }
    }

    @Test func obscuredIsClampedSoTheFitNeverBalloons() throws {
        let a = route("a", [(4.0, 101.0)], dest: (4.6, 101.2))
        let r = try #require(PastTripsMapLogic.region(fitting: [a], padding: 1, bottomObscured: 300, topObscured: 1))
        #expect(r.span.latitudeDelta <= 0.6 / 0.3 + 1e-9)
    }

    @Test func thinKeepsEndsAndCaps() {
        let coords = (0..<1000).map { CLLocationCoordinate2D(latitude: Double($0) / 1000, longitude: 101) }
        let thin = PastTripsMapLogic.thin(coords, maxPoints: 50)
        #expect(thin.count == 50)
        #expect(thin.first?.latitude == coords.first?.latitude)
        #expect(thin.last?.latitude == coords.last?.latitude)
        #expect(PastTripsMapLogic.thin(Array(coords.prefix(10)), maxPoints: 50).count == 10)
    }

    @Test func drawsOnlyEndedTripsNewestFirstCapped() {
        let now = Date()
        let entries = (0..<20).map {
            PastTrips.Entry(id: "t\($0)", name: "T", destination: "D", endedAt: $0 == 0 ? nil : now, seenAt: now)
        }
        let drawn = PastTripsMapLogic.tripsToDraw(entries, limit: 5)
        #expect(drawn.map(\.id) == ["t1", "t2", "t3", "t4", "t5"])
    }

    @Test func routeDecodesEncodedPolyline() {
        let line = [CLLocationCoordinate2D(latitude: 3.1, longitude: 101.6), .init(latitude: 4.6, longitude: 101.1)]
        let r = PastTripsMapLogic.route(id: "x", name: "N", destinationName: "Ipoh", destination: line[1],
                                        encodedRoute: Polyline.encode(line))
        #expect(r.coordinates.count == 2)
        #expect(abs(r.start!.latitude - 3.1) < 1e-5)
        #expect(r.destinationName == "Ipoh")
    }
}
