#if DEBUG
import CoreLocation
import FirebaseFirestore
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

    /// KL to Ipoh along the sample route, stops at 62, 121 and 168 km.
    static let stopsOnRoute: [PlannedStop] = [
        PlannedStop(id: "s1", name: "R&R Tapah", coordinate: GeoPoint(latitude: 4.2, longitude: 101.25), routeOffset: 62_000,
                    kind: .fuel, minutes: 20, order: 0),
        PlannedStop(id: "s2", name: "R&R Bidor", coordinate: GeoPoint(latitude: 4.1, longitude: 101.28), routeOffset: 121_000,
                    kind: .rest, minutes: 15, order: 1),
        PlannedStop(id: "s3", name: "Kopitiam Gopeng", coordinate: GeoPoint(latitude: 4.45, longitude: 101.12), routeOffset: 168_000,
                    kind: .food, order: 2),
    ]

    static func lobby(_ scene: Scene) -> LobbyView {
        let planner = StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in })
        func model(_ stops: [PlannedStop]) -> LobbyModel {
            let model = LobbyModel.sample(started: false, seconds: 2 * 3600 + 40 * 60, stops: stops)
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
            planner.showForDemo(items: items, turnBacks: ["s2": 6_000])
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: true)
        case .meetAndFailure:
            var items = [
                StopDraft(id: "m", name: "Petronas Sungai Buloh", coordinate: .init(latitude: 3.2, longitude: 101.58), kind: .meet,
                          meetAt: Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()), routeOffset: 0),
                StopDraft(id: "s1", name: "R&R Tapah", coordinate: .init(latitude: 4.2, longitude: 101.25), kind: .fuel, minutes: 20, routeOffset: 62_000),
                StopDraft(id: "s9", name: "Lunch, Ipoh Lama", coordinate: .init(latitude: 4.6, longitude: 101.08), kind: .food, minutes: 45),
            ]
            items[2].routeOffset = nil
            planner.showForDemo(items: items, status: .failed(.init(place: .stop("s9"), reason: .failed("offline"))))
            return LobbyView(sample: model([]), planner: planner, organizer: true)
        }
    }
}
#endif
