#if DEBUG
import CoreLocation
import SwiftUI

/// The lobby as a participant who is not on Aisha's start: the four states of D26's route card
/// (`IKUT_SCREEN=lobby-own-merges`, `lobby-own-main`, `lobby-own-never`, `lobby-own-noroute`).
@MainActor
enum OwnWayDemo {
    enum Scene { case merges, onMain, neverMerges, noRoute }

    static func lobby(_ scene: Scene) -> LobbyView {
        let main = RouteLine(LobbyStopsDemo.route)
        let planner = StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in })
        let model = LobbyModel.sample(started: false, seconds: 2 * 3600 + 40 * 60, stops: [], route: LobbyStopsDemo.route)
        planner.sync(trip: model.trip, stops: model.stops)
        func car(route: [CLLocationCoordinate2D]?, mergeOffset: Double?, state: CarState) -> Car {
            Car(id: "c2", name: "Wyna’s X70", color: "#D9480F", trackerUserId: "u2", isLead: false,
                route: route.map(Polyline.encode), mergeOffset: mergeOffset, state: state, number: 2)
        }
        let info = OwnWayInfo()
        switch scene {
        case .merges:
            // Shah Alam, joining the main route 35 km along (near Rawang), with the 500 m tail the tracker keeps.
            let shahAlam = CLLocationCoordinate2D(latitude: 3.0738, longitude: 101.5183)
            let route = [shahAlam, main.coordinate(atOffset: 35_000)!, main.coordinate(atOffset: 35_500)!]
            info.showForDemo(
                car: car(route: route, mergeOffset: 35_000, state: .joining), main: main, destinationName: "Ipoh",
                from: "Shah Alam", place: "Rawang", drive: .init(distance: 0, travelTime: 2 * 3600 + 10 * 60, roadName: "E1"))
        case .onMain:
            info.showForDemo(
                car: car(route: nil, mergeOffset: 400, state: .convoy), main: main, destinationName: "Ipoh",
                from: "Kuala Lumpur", place: "Kuala Lumpur", drive: .init(distance: 0, travelTime: 2 * 3600 + 40 * 60, roadName: "E1"))
        case .neverMerges:
            // Penang to Ipoh: the whole route is the car's own, ending off the main route's end.
            let penang = CLLocationCoordinate2D(latitude: 5.4141, longitude: 100.3288)
            let end = CLLocationCoordinate2D(latitude: 4.6005, longitude: 101.09)
            info.showForDemo(
                car: car(route: MapDemo.densify([penang, end]), mergeOffset: main.length, state: .joining), main: main,
                destinationName: "Ipoh", from: "George Town", place: nil, drive: .init(distance: 0, travelTime: 2 * 3600, roadName: "E1"))
        case .noRoute:
            info.showForDemo(
                car: car(route: nil, mergeOffset: nil, state: .joining), main: main, destinationName: "Ipoh",
                from: "Your location", place: nil, drive: .init(distance: 205_000, travelTime: 2 * 3600 + 40 * 60, roadName: "E1"))
        }
        return LobbyView(sample: model, planner: planner, organizer: false, ownWay: info)
    }
}
#endif
