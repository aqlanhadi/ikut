#if DEBUG
import FirebaseFirestore
import SwiftUI

/// The "who is here" card on its own (`IKUT_SCREEN=road-arrival`, `road-arrival-all`, `road-arrival-meet`,
/// RoadStops.dc.html), over the demo convoy. The clock is fixed, so the cars never go stale while it is looked at.
struct StopArrivalDemo: View {
    enum Scene { case someHere, allHere, meeting }

    var scene: Scene
    @State private var map: TripMapModel
    @State private var now = Date()
    private let stopId: String

    init(_ scene: Scene) {
        self.scene = scene
        let built = Self.build(scene)
        _map = State(initialValue: built.model)
        stopId = built.stopId
    }

    static func build(_ scene: Scene) -> (model: TripMapModel, stopId: String) {
        let now = Date()
        let model = MapDemo.model(now: now)
        let main = RouteLine(MapDemo.densify(MapDemo.mainWaypoints))
        let bidor = main.project(MapDemo.joiningWaypoints.last ?? .init(latitude: 4.1, longitude: 101.29))?.offset ?? 0
        let stopOffset = scene == .meeting ? bidor : (main.project(.init(latitude: 4.2, longitude: 101.26))?.offset ?? 0)
        let at = main.coordinate(atOffset: stopOffset) ?? main.coordinates[0]

        func fix(_ offset: Double, joining: Bool, speed: Double = 25) -> Position {
            let c = main.coordinate(atOffset: offset) ?? at
            return Position(
                id: nil, location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed, heading: 0,
                routeOffset: offset, convoyOffset: joining ? nil : offset, battery: 0.8, updatedAt: now.addingTimeInterval(-4))
        }
        var cars = model.convoy.convoy.map(\.car) + model.convoy.joining.map(\.car)
        cars.sort { ($0.number ?? 99) < ($1.number ?? 99) }
        var positions: [String: Position] = [:]
        switch scene {
        case .someHere:
            positions = ["c1": fix(stopOffset, joining: false), "c2": fix(stopOffset - 80, joining: false),
                         "c4": fix(stopOffset - 4_000, joining: false), "c3": fix(stopOffset - 12_000, joining: true)]
        case .allHere:
            positions = ["c1": fix(stopOffset, joining: false), "c2": fix(stopOffset - 80, joining: false),
                         "c4": fix(stopOffset + 60, joining: false), "c3": fix(stopOffset - 30, joining: true)]
        case .meeting:
            // Everyone joins: the organizer is at the meeting point, the others are still on their way in.
            for i in cars.indices where cars[i].id != "c1" { cars[i].state = .joining }
            positions = ["c1": fix(stopOffset, joining: true), "c2": fix(stopOffset - 3_000, joining: true),
                         "c4": fix(stopOffset - 9_000, joining: true), "c3": fix(stopOffset - 12_000, joining: true)]
        }
        var stop = PlannedStop(
            id: "s1", name: scene == .meeting ? "Petronas Tapah Road" : "R&R Tapah",
            coordinate: GeoPoint(latitude: at.latitude, longitude: at.longitude), routeOffset: stopOffset,
            kind: scene == .meeting ? .meet : .fuel, minutes: scene == .meeting ? nil : 20,
            meetAt: scene == .meeting ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now) : nil, order: 0)
        stop.id = "s1"
        model.setStops([stop])
        model.setCars(cars)
        model.apply(trip: nil, myCar: cars.first, myCarId: "c1", positions: positions, isTracker: true)
        return (model, "s1")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            StopArrivalCard(model: map, stopId: stopId, frozenNow: now, onClose: {})
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.s)
        }
    }
}
#endif
