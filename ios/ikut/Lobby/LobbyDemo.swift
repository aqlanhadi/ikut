#if DEBUG
import CoreLocation
import FirebaseFirestore
import MapKit
import Foundation
import SwiftUI

/// Straight roads at 25 m/s between any two points: stands in for MapKit in previews, screenshots and UI tests.
struct DemoRoads: LegRouting {
    /// Latitudes with no road to them, for the "couldn't find a road" state.
    var noRoadTo: Set<Double> = []

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        if noRoadTo.contains(to.latitude) { throw RouteError.noRoute }
        let length = RouteLine.haversine(from, to)
        let count = max(1, Int((length / 500).rounded(.up)))
        let points = (0...count).map { i -> CLLocationCoordinate2D in
            let t = Double(i) / Double(count)
            return CLLocationCoordinate2D(
                latitude: from.latitude + (to.latitude - from.latitude) * t,
                longitude: from.longitude + (to.longitude - from.longitude) * t)
        }
        return RouteLeg(coordinates: points, distance: length, travelTime: length / 25, name: "E1")
    }
}

/// The lobby with planned stops, in the states of LobbyStops.dc.html.
@MainActor
enum LobbyStopsDemo {
    enum Scene: String {
        case organizer, organizerEmpty, member, meetAndFailure, turnBack
    }

    /// KL to Ipoh, about 190 km.
    static let route: [CLLocationCoordinate2D] = MapDemo.densify([
        .init(latitude: 3.139, longitude: 101.687), .init(latitude: 3.43, longitude: 101.52), .init(latitude: 3.73, longitude: 101.35),
        .init(latitude: 4.0, longitude: 101.28), .init(latitude: 4.2, longitude: 101.25), .init(latitude: 4.45, longitude: 101.12),
        .init(latitude: 4.5975, longitude: 101.09),
    ])

    static func stop(_ id: String, _ name: String, _ lat: Double, _ lng: Double, _ kind: PlannedStopKind, _ minutes: Int?, _ order: Int) -> PlannedStop {
        let offset = RouteLine(route).project(.init(latitude: lat, longitude: lng))?.offset ?? 0
        return PlannedStop(id: id, name: name, coordinate: GeoPoint(latitude: lat, longitude: lng), routeOffset: offset, kind: kind, minutes: minutes, order: order)
    }

    static let stopsOnRoute: [PlannedStop] = [
        stop("s1", "R&R Tapah", 4.2, 101.25, .fuel, 20, 0),
        stop("s2", "R&R Bidor", 3.95, 101.29, .rest, 15, 1),
        stop("s3", "Kopitiam Gopeng", 4.45, 101.12, .food, nil, 2),
    ].sorted { $0.routeOffset < $1.routeOffset }.enumerated().map { var s = $1; s.order = $0; return s }

    static func lobby(_ scene: Scene) -> LobbyView {
        let planner = StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in })
        func model(_ stops: [PlannedStop]) -> LobbyModel {
            let model = LobbyModel.sample(started: false, seconds: 2 * 3600 + 40 * 60, stops: stops, route: route)
            planner.sync(trip: model.trip, stops: model.stops)
            return model
        }
        switch scene {
        case .organizer:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: true)
        case .organizerEmpty:
            return LobbyView(sample: model([]), planner: planner, organizer: true)
        case .member:
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: false)
        case .turnBack:
            let items = stopsOnRoute.map(StopDraft.init)
            planner.showForDemo(items: items, turnBacks: ["s1": 6_000])
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: true)
        case .meetAndFailure:
            var items = [
                StopDraft(id: "m", name: "Petronas Sungai Buloh", coordinate: .init(latitude: 3.2, longitude: 101.58), kind: .meet,
                          meetAt: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()), routeOffset: 0),
                StopDraft(id: "s1", name: "R&R Tapah", coordinate: .init(latitude: 4.2, longitude: 101.25), kind: .fuel, minutes: 20, routeOffset: 100_000),
                StopDraft(id: "s9", name: "Lunch, Ipoh Lama", coordinate: .init(latitude: 4.6, longitude: 101.08), kind: .food, minutes: 45),
            ]
            items[2].routeOffset = nil
            planner.showForDemo(items: items, status: .failed(.init(place: .stop("s9"), reason: .failed("offline"))))
            return LobbyView(sample: model([]), planner: planner, organizer: true)
        }
    }
}

/// Screens for screenshots and UI tests, opened by launching with `IKUT_SCREEN=<name>` (debug builds only).
@MainActor
enum DemoScreens {
    static func view(_ name: String) -> AnyView? {
        func nav<V: View>(_ view: V) -> AnyView {
            AnyView(NavigationStack { view }.environment(LocationPermission()).environment(AuthModel()))
        }
        func sheet(query: String, picked: DestinationResult?, kind: PlannedStopKind, minutes: Int?, canMeet: Bool, meet: Bool = false) -> AnyView {
            let model = CreateTripModel()
            model.along = AlongRoute(
                coordinates: LobbyStopsDemo.route, seconds: 2 * 3600 + 40 * 60)
            let results = [
                DestinationResult(name: "R&R Tapah (northbound)", subtitle: "Perak", coordinate: .init(latitude: 4.2, longitude: 101.25), category: MKPointOfInterestCategory.restroom.rawValue),
                DestinationResult(name: "Tapah", subtitle: "Perak", coordinate: .init(latitude: 4.19, longitude: 101.26)),
                DestinationResult(name: "Petronas Tapah Road", subtitle: "Perak", coordinate: .init(latitude: 4.17, longitude: 101.3), category: MKPointOfInterestCategory.gasStation.rawValue),
            ]
            model.showForDemo(query: query, results: results, origin: .init(latitude: 3.139, longitude: 101.687), originName: "Kuala Lumpur")
            return AnyView(AddStopSheet(demoModel: model, picked: picked, kind: kind, minutes: minutes, canMeet: canMeet,
                                        meetClock: meet ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) : nil)
                .environment(LocationPermission()))
        }
        switch name {
        case "lobby-organizer": return nav(LobbyStopsDemo.lobby(.organizer))
        case "lobby-empty": return nav(LobbyStopsDemo.lobby(.organizerEmpty))
        case "lobby-member": return nav(LobbyStopsDemo.lobby(.member))
        case "lobby-turnback": return nav(LobbyStopsDemo.lobby(.turnBack))
        case "lobby-meet-failure": return nav(LobbyStopsDemo.lobby(.meetAndFailure))
        case "join-stops": return nav(JoinDemo.ticket(withStops: true))
        case "join-no-stops": return nav(JoinDemo.ticket(withStops: false))
        case "road-header-moving": return AnyView(PanelHeaderDemo(.moving))
        case "road-header-parked": return AnyView(PanelHeaderDemo(.parked))
        case "road-header-never": return AnyView(PanelHeaderDemo(.never))
        case "road-header-convoy": return AnyView(PanelHeaderDemo(nil))
        case "road-next-stop": return AnyView(NextStopDemo())
        case "join-with-location": return nav(JoinDemo.ticket(withStops: true, drive: TicketDrive(distance: 185_000, travelTime: 2 * 3600 + 10 * 60)))
        case "join-without-location": return nav(JoinDemo.ticket(withStops: true))
        case "lobby-own-merges": return nav(OwnWayDemo.lobby(.merges))
        case "lobby-own-main": return nav(OwnWayDemo.lobby(.onMain))
        case "lobby-own-never": return nav(OwnWayDemo.lobby(.neverMerges))
        case "lobby-own-noroute": return nav(OwnWayDemo.lobby(.noRoute))
        case "road-arrival": return AnyView(StopArrivalDemo(.someHere))
        case "road-arrival-all": return AnyView(StopArrivalDemo(.allHere))
        case "road-arrival-meet": return AnyView(StopArrivalDemo(.meeting))
        case "road-leave": return AnyView(StopArrivalDemo(.leave))
        case "road-leave-confirm": return AnyView(StopArrivalDemo(.leaveConfirm))
        case "road-leave-other": return AnyView(StopArrivalDemo(.leaveOther))
        case "road-leave-meet": return AnyView(StopArrivalDemo(.leaveMeeting))
        case "add-search":
            return sheet(query: "Tapah", picked: nil, kind: .fuel, minutes: nil, canMeet: false)
        case "add-details":
            let place = DestinationResult(name: "R&R Tapah (northbound)", subtitle: "Perak", coordinate: .init(latitude: 4.2, longitude: 101.25), category: MKPointOfInterestCategory.restroom.rawValue)
            return sheet(query: "", picked: place, kind: .fuel, minutes: 20, canMeet: false)
        case "add-meet":
            let place = DestinationResult(name: "Petronas Sungai Buloh", subtitle: "Selangor", coordinate: .init(latitude: 3.2, longitude: 101.58), category: MKPointOfInterestCategory.gasStation.rawValue)
            return sheet(query: "", picked: place, kind: .meet, minutes: nil, canMeet: true, meet: true)
        case "stop-approach": return AnyView(StopApproachDemo.view())
        case "stop-approach-food": return AnyView(StopApproachDemo.view(food: true))
        default: return nil
        }
    }
}
#endif
