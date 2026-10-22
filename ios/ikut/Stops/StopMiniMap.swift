import CoreLocation
import MapKit
import SwiftUI

/// What the stop card's small map frames: my car, the suggested place and the route between them.
enum StopMapFraming {
    /// A region that fits both points with some room around them (and never smaller than ~800 m).
    static func region(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let center = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        let minSpan = 0.008
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(abs(a.latitude - b.latitude) * 1.5, minSpan),
                longitudeDelta: max(abs(a.longitude - b.longitude) * 1.5, minSpan)))
    }

    /// The route between two offsets, sampled about every 500 m; empty when there is no route.
    static func routeBetween(_ route: RouteLine?, from: Double, to: Double) -> [CLLocationCoordinate2D] {
        guard let route, to > from else { return [] }
        var points: [CLLocationCoordinate2D] = []
        var offset = max(0, from)
        while offset < min(to, route.length) {
            if let point = route.coordinate(atOffset: offset) { points.append(point) }
            offset += 500
        }
        if let end = route.coordinate(atOffset: min(to, route.length)) { points.append(end) }
        return points
    }
}

/// The small, fixed map on the ask confirm screen: where I am and the suggested place, framed to
/// fit both, with the route line. Not interactive.
struct StopMiniMap: View {
    var me: CLLocationCoordinate2D
    var place: CLLocationCoordinate2D
    var symbol: String
    var route: [CLLocationCoordinate2D]

    var body: some View {
        Map(initialPosition: .region(StopMapFraming.region(me, place)), interactionModes: []) {
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(MapPalette.route, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            Annotation("Me", coordinate: me, anchor: .center) {
                Circle()
                    .fill(MapPalette.accent)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .shadow(radius: 2)
            }
            .annotationTitles(.hidden)
            Annotation("Stop", coordinate: place, anchor: .center) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.orange, in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .shadow(radius: 2)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityHidden(true)
        .accessibilityIdentifier("stop.minimap")
    }
}
