import CoreLocation
import MapKit
import Foundation
import Testing
@testable import ikut

/// D120: the recap map's overview sits centred in the strip between its header and its step card, with the same margin
/// either side. Modelled as MapKit frames it: the screen's width by the card's top (the card is the map's bottom
/// padding), zoomed until both spans of the region fit.
@MainActor
struct RecapFitTests {
    private func point(_ c: CLLocationCoordinate2D, in region: MKCoordinateRegion, width: Double, height: Double) -> CGPoint {
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude + region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude - region.span.longitudeDelta / 2))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: region.center.latitude - region.span.latitudeDelta / 2,
                                                   longitude: region.center.longitude + region.span.longitudeDelta / 2))
        let scale = min(width / abs(se.x - nw.x), height / abs(se.y - nw.y))
        let centre = MKMapPoint(region.center), p = MKMapPoint(c)
        return CGPoint(x: width / 2 + (p.x - centre.x) * scale, y: height / 2 + (p.y - centre.y) * scale)
    }

    private let fixtures: [(String, ClosedRange<Double>, ClosedRange<Double>)] = [
        ("long thin", 3.0...3.1, 101.0...103.5), ("tall", 1.5...6.0, 101.0...101.4),
        ("short", 3.0...3.2, 101.0...101.15), ("diagonal", 2.0...4.6, 100.9...103.0),
    ]

    private func snapshot(lat: ClosedRange<Double>, lng: ClosedRange<Double>) -> RecapSnapshot {
        var s = RecapSnapshot.demo()
        s.route = Polyline.encode([.init(latitude: lat.lowerBound, longitude: lng.lowerBound), .init(latitude: lat.upperBound, longitude: lng.upperBound),
                                   .init(latitude: lat.lowerBound, longitude: lng.upperBound), .init(latitude: lat.upperBound, longitude: lng.lowerBound)])
        s.destinationLatitude = lat.upperBound; s.destinationLongitude = lng.upperBound
        s.positions = []
        return s
    }

    /// (width, screen height, header bottom, card top) at four text sizes (the first and last measured on an iPhone 17 at the
    /// default and the largest accessibility size): the card and the header grow with the text.
    private let cases: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (402, 874, 116, 643), (402, 874, 140, 560), (402, 874, 170, 470), (402, 874, 199, 387),
        (375, 667, 80, 490), (375, 667, 100, 430), (375, 667, 125, 380), (375, 667, 150, 330),
    ]

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func overviewIsCentredInTheStrip(_ i: Int) throws {
        let (w, _, header, card) = cases[i]
        for (name, lat, lng) in fixtures {
            let snap = snapshot(lat: lat, lng: lng)
            let region = try #require(RecapFit.region(snapshot: snap, headerBottom: header, cardTop: card, width: w))
            let pts = Polyline.decode(snap.route).map { point($0, in: region, width: Double(w), height: Double(card)) }
            let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!, minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
            let stripTop = Double(header + RecapFit.headerGap + RecapFit.pinRoom), stripBottom = Double(card)
            let id = "\(name) case \(i)"
            #expect(abs(minX - (Double(w) - maxX)) < 1, "left/right \(id): \(minX) \(Double(w) - maxX)")
            #expect(abs((minY - stripTop) - (stripBottom - maxY)) < 1, "top/bottom \(id): \(minY - stripTop) \(stripBottom - maxY)")
            #expect(minY >= stripTop - 0.5 && maxY <= stripBottom + 0.5 && minX >= -0.5 && maxX <= Double(w) + 0.5, "inside \(id)")
        }
    }

    @Test func nothingToFitBeforeTheHeaderAndCardAreMeasured() {
        let snap = RecapSnapshot.demo()
        #expect(RecapFit.region(snapshot: snap, headerBottom: 0, cardTop: 600, width: 402) == nil)
        #expect(RecapFit.region(snapshot: snap, headerBottom: 100, cardTop: 0, width: 402) == nil)
        #expect(RecapFit.region(snapshot: snap, headerBottom: 100, cardTop: 600, width: 0) == nil)
    }
}
