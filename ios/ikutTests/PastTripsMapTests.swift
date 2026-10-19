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
