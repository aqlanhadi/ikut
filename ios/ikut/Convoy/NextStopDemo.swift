#if DEBUG
import FirebaseFirestore
import SwiftUI

/// The convoy panel with the Next stop cell (`IKUT_SCREEN=road-next-stop`, RoadStops.dc.html): the demo
/// convoy, with R&R Tapah 18 km ahead of the viewer's car.
struct NextStopDemo: View {
    @State private var map = Self.model()
    @State private var expanded = true

    static func model() -> TripMapModel {
        let map = MapDemo.model()
        let offset = (map.convoy.convoy.first(where: { $0.id == map.myCarId })?.convoyOffset ?? 0) + 18_000
        let at = map.mainRoute?.coordinate(atOffset: offset) ?? .init(latitude: 4.2, longitude: 101.25)
        var stop = PlannedStop(
                id: nil, name: "R&R Tapah", coordinate: GeoPoint(latitude: at.latitude, longitude: at.longitude),
                routeOffset: offset, kind: .fuel, minutes: 20, order: 0)
        stop.id = "s1"
        map.setStops([stop])
        return map
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            ConvoyPanel(model: map, expanded: $expanded, canReport: true, onReport: {}, onStop: {})
        }
    }
}
#endif
