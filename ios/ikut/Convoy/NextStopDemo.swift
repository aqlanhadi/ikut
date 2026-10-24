#if DEBUG
import FirebaseFirestore
import SwiftUI

/// The convoy panel with the Next stop cell (`IKUT_SCREEN=road-next-stop`, RoadStops.dc.html): the demo
/// convoy, with R&R Tapah 18 km ahead of the viewer's car.
struct NextStopDemo: View {
    @State private var map: TripMapModel
    @State private var expanded = true

    /// `afterLeave`: the viewer's car is still joining, the lead car has already left the meeting point, so the cell
    /// reads the next stop ahead of where its road meets the main route, not the meet (D25 4d-2).
    init(afterLeave: Bool = false) {
        _map = State(initialValue: afterLeave ? Self.joiningAfterLeave() : Self.model())
    }

    static func joiningAfterLeave() -> TripMapModel {
        let map = MapDemo.model(joiner: .moving)
        let main = map.mainRoute
        let merge = map.myCar?.mergeOffset ?? 0
        var meet = PlannedStop(
            id: "m1", name: "Petronas Sungai Buloh", coordinate: GeoPoint(latitude: 4.0, longitude: 101.0),
            routeOffset: 0, kind: .meet, minutes: nil, order: 0)
        meet.leftAt = Date().addingTimeInterval(-600)
        meet.leftBy = "u-c1"
        let offset = merge + 18_000
        let at = main?.coordinate(atOffset: offset) ?? .init(latitude: 4.2, longitude: 101.25)
        let stop = PlannedStop(
            id: "s1", name: "R&R Tapah", coordinate: GeoPoint(latitude: at.latitude, longitude: at.longitude),
            routeOffset: offset, kind: .fuel, minutes: 20, order: 1)
        map.setStops([meet, stop])
        return map
    }

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
            ConvoyPanel(model: map, expanded: $expanded, canReport: true, onReport: {}, onStop: {}).previewCard()
        }
    }
}
#endif
