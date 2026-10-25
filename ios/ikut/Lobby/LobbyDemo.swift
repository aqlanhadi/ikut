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
        case organizer, organizerEmpty, member, meetAndFailure, turnBack, suggestAdded
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
        case .suggestAdded:
            // After Add in Suggest stops: the R&R is an ordinary 20 min Rest in the list (SuggestStops.dc.html d).
            let tapah = [stop("s1", "R&R Tapah (northbound)", 4.2, 101.25, .rest, 20, 0)]
            planner.showForDemo(items: tapah.map(StopDraft.init))
            return LobbyView(sample: model(tapah), planner: planner, organizer: true)
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

/// The Suggest stops sheet on KL to Ipoh (SuggestStops.dc.html): one R&R on our side of the route.
@MainActor
enum SuggestStopsDemo {
    static func sheet(seconds: Double = 2 * 3600 + 25 * 60, moved: Int = 0) -> some View {
        let line = RouteLine(LobbyStopsDemo.route)
        let at = CLLocationCoordinate2D(latitude: 4.2, longitude: 101.25)
        let offset = line.project(at)?.offset ?? 0
        let tapah = PlaceAlong(
            id: "demo/tapah", kind: .services, name: "R&R Tapah (northbound)", coordinate: at, ring: nil,
            facilities: [.fuel, .food, .toilets], brands: [], offset: offset, distance: 40, side: .left,
            carriageway: .ours, ours: true, entrance: at, slipEntrance: false, routeOffset: offset)
        let model = SuggestStopsModel(line: line, routeSeconds: seconds, existing: [], sites: [], fuel: [], candidates: [tapah])
        for _ in 0..<abs(moved) { model.step(moved > 0 ? 1 : -1) }
        let summary = "KL to Ipoh · \(RouteFormat.distance(line.length)) · \(ConvoyFormat.duration(seconds))"
        return SuggestStopsSheet(model: model, summary: summary, canAdd: { true }, onAdd: { _ in })
    }
}

/// A reverse geocoder with one fixed answer, for the demo screens.
struct DemoGeocoder: ReverseGeocoding {
    var answer: GeocodedName?
    init(_ answer: GeocodedName?) { self.answer = answer }
    func lookup(_ coordinate: CLLocationCoordinate2D) async -> GeocodedName? { answer }
}

/// Screens for screenshots and UI tests, opened by launching with `IKUT_SCREEN=<name>` (debug builds only).
@MainActor
enum DemoScreens {
    static func view(_ name: String) -> AnyView? {
        func nav<V: View>(_ view: V) -> AnyView {
            AnyView(NavigationStack { view }.environment(LocationPermission()).environment(AuthModel()))
        }
        func home(_ state: String) -> AnyView {
            AnyView(HomePickedDemo.view(state).environment(AuthModel()))
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
        let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
        func search(_ model: CreateTripModel) -> AnyView { nav(CreateTripView(model: model) { _ in }) }
        func petrol(_ name: String, _ area: String, _ lat: Double, _ lon: Double) -> DestinationResult {
            DestinationResult(name: name, subtitle: area, coordinate: .init(latitude: lat, longitude: lon), category: MKPointOfInterestCategory.gasStation.rawValue)
        }
        switch name {
        case "search-typing":
            let model = CreateTripModel()
            model.showSuggestionsForDemo(
                query: "petr",
                suggestions: [
                    SearchSuggestion(title: "Petronas Sungai Buloh", subtitle: "Jalan Sungai Buloh, Selangor", highlights: [NSRange(location: 0, length: 4)]),
                    SearchSuggestion(title: "Petaling Jaya", subtitle: "Selangor, Malaysia", highlights: [NSRange(location: 0, length: 3)]),
                    SearchSuggestion(title: "petrol station", subtitle: "Search Nearby", highlights: [NSRange(location: 0, length: 4)]),
                    SearchSuggestion(title: "Petrosains", subtitle: "Suria KLCC, Kuala Lumpur", highlights: [NSRange(location: 0, length: 4)]),
                ], origin: kl, originName: "Kuala Lumpur")
            return search(model)
        case "search-results":
            let model = CreateTripModel()
            model.showForDemo(
                query: "petrol station",
                results: [
                    petrol("Petronas Jalan Ampang", "Jalan Ampang, Kuala Lumpur", 3.16, 101.72),
                    petrol("Shell Sungai Besi", "Sungai Besi, Kuala Lumpur", 3.07, 101.71),
                    petrol("Petron Cheras", "Cheras, Selangor", 3.09, 101.75),
                    petrol("BHP Kajang", "Kajang, Selangor", 2.99, 101.79),
                    petrol("Caltex Shah Alam", "Shah Alam, Selangor", 3.07, 101.52),
                    petrol("Petronas Genting Sempah R&R", "Karak Highway, Pahang", 3.37, 101.77),
                ], origin: kl, originName: "Kuala Lumpur")
            return search(model)
        case "search-dropped-pin":
            let model = CreateTripModel()
            model.showPinForDemo(
                query: "3.139, 101.687", found: GeocodedName(name: nil, locality: "Tapah"), origin: kl, originName: "Kuala Lumpur")
            return search(model)
        case "map-pick":
            return AnyView(MapPickView(origin: kl, geocoder: DemoGeocoder(GeocodedName(name: nil, locality: "Kuala Lumpur"))) { _ in })
        case "map-pick-stop":
            let route = AlongRoute(coordinates: LobbyStopsDemo.route, seconds: 2 * 3600 + 40 * 60)
            return AnyView(MapPickView(
                origin: kl, along: route, start: .init(latitude: 4.2, longitude: 101.25),
                geocoder: DemoGeocoder(GeocodedName(name: nil, locality: "Tapah"))) { _ in })
        case "search-empty":
            let model = CreateTripModel()
            model.showForDemo(query: "zxqv", results: [], origin: kl, originName: "Kuala Lumpur")
            return search(model)
        case "search-stop-results":
            let model = CreateTripModel()
            model.along = AlongRoute(coordinates: LobbyStopsDemo.route, seconds: 2 * 3600 + 40 * 60)
            model.showForDemo(
                query: "petrol station",
                results: [
                    petrol("Petronas Sungai Buloh", "Selangor", 3.2, 101.58),
                    petrol("Petronas Tapah Road", "Perak", 4.17, 101.3),
                    petrol("Shell Taiping", "Perak", 4.85, 100.74),
                    petrol("Petronas Genting Highlands", "Pahang", 3.42, 101.79),
                ], origin: kl, originName: "Kuala Lumpur")
            return AnyView(AddStopSheet(demoModel: model, picked: nil, kind: .fuel, minutes: nil, canMeet: false)
                .environment(LocationPermission()))
        case "lobby-organizer": return nav(LobbyStopsDemo.lobby(.organizer))
        case "lobby-empty": return nav(LobbyStopsDemo.lobby(.organizerEmpty))
        case "lobby-suggest-added": return nav(LobbyStopsDemo.lobby(.suggestAdded))
        // The Suggest stops sheet: the button is on lobby-empty; then the suggestion, the stepper moved, a short trip,
        // and the largest text.
        case "suggest-stops": return AnyView(SuggestStopsDemo.sheet())
        case "suggest-stops-moved": return AnyView(SuggestStopsDemo.sheet(moved: 1))
        case "suggest-stops-short": return AnyView(SuggestStopsDemo.sheet(seconds: 50 * 60))
        case "suggest-stops-large": return AnyView(SuggestStopsDemo.sheet().dynamicTypeSize(.accessibility5))
        // lobby-member and lobby-waiting: a participant before the organiser starts (the waiting line, D39).
        case "lobby-member": return nav(LobbyStopsDemo.lobby(.member))
        case "lobby-waiting": return nav(LobbyStopsDemo.lobby(.member))
        case "lobby-turnback": return nav(LobbyStopsDemo.lobby(.turnBack))
        case "lobby-meet-failure": return nav(LobbyStopsDemo.lobby(.meetAndFailure))
        case "join-stops": return nav(JoinDemo.ticket(withStops: true))
        case "join-no-stops": return nav(JoinDemo.ticket(withStops: false))
        case "road-markers": return AnyView(MapMarkersDemo())
        case "road-header-moving": return AnyView(PanelHeaderDemo(.moving))
        case "road-header-parked": return AnyView(PanelHeaderDemo(.parked))
        case "road-header-never": return AnyView(PanelHeaderDemo(.never))
        case "road-header-convoy": return AnyView(PanelHeaderDemo(nil))
        case "road-panel-short": return AnyView(MapDemo.view())
        case "road-panel-you-online": return AnyView(MapDemo.view(expanded: true))
        case "road-panel-you-offline": return AnyView(MapDemo.view(expanded: true, online: false))
        case "road-panel-tall": return AnyView(MapDemo.view(expanded: true))
        // Five cars: the list is longer than the sheet's room, so the whole panel scrolls as one (D34 7a).
        case "road-panel-tall-5": return AnyView(MapDemo.view(expanded: true, fiveCars: true))
        // A car tapped on the map (D34 7b): ringed on the map, its row highlighted. Folded keeps the panel short;
        // tall-5 selects the fifth car, whose row is below the sheet's fold and is scrolled to.
        case "road-car-selected": return AnyView(MapDemo.view(selected: "c2"))
        case "road-car-selected-tall-5": return AnyView(MapDemo.view(expanded: true, fiveCars: true, selected: "c5"))
        case "road-panel-short-5": return AnyView(MapDemo.view(fiveCars: true))
        case "road-next-stop": return AnyView(NextStopDemo())
        case "road-next-stop-joining-after-leave": return AnyView(NextStopDemo(afterLeave: true))
        case "join-with-location": return nav(JoinDemo.ticket(withStops: true, drive: TicketDrive(distance: 185_000, travelTime: 2 * 3600 + 10 * 60)))
        case "join-without-location": return nav(JoinDemo.ticket(withStops: true))
        case "lobby-own-merges": return nav(OwnWayDemo.lobby(.merges))
        case "lobby-own-main": return nav(OwnWayDemo.lobby(.onMain))
        case "lobby-own-never": return nav(OwnWayDemo.lobby(.neverMerges))
        case "lobby-own-noroute": return nav(OwnWayDemo.lobby(.noRoute))
        case "road-arrival": return AnyView(StopArrivalDemo(.someHere))
        case "road-arrival-all": return AnyView(StopArrivalDemo(.allHere))
        case "road-not-sharing": return AnyView(StopArrivalDemo(.notSharing))
        case "road-arrival-meet": return AnyView(StopArrivalDemo(.meeting))
        case "road-leave": return AnyView(StopArrivalDemo(.leave))
        case "road-leave-confirm": return AnyView(StopArrivalDemo(.leaveConfirm))
        case "road-leave-other": return AnyView(StopArrivalDemo(.leaveOther))
        case "road-leave-meet": return AnyView(StopArrivalDemo(.leaveMeeting))
        case "road-skip": return AnyView(StopArrivalDemo(.skip))
        case "road-skip-mine": return AnyView(StopArrivalDemo(.skipMine))
        case "road-skip-others": return AnyView(StopArrivalDemo(.skipOthers))
        case "road-skip-lead": return AnyView(StopArrivalDemo(.skipLead))
        case "road-skip-all": return AnyView(StopArrivalDemo(.skipAll))
        case "road-skip-all-confirm": return AnyView(StopArrivalDemo(.skipAllConfirm))
        case "road-skip-all-others": return AnyView(StopArrivalDemo(.skipAllOthers))
        case "road-skip-all-meet": return AnyView(StopArrivalDemo(.skipAllMeeting))
        // The recap as the pushed page: system Back, the trip name as the large title, Share in the bar (D34).
        case "recap":
            return AnyView(NavigationStack {
                Color.clear.navigationTitle("Trips").navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: .constant(true)) {
                        RecapView(model: RecapModel(snapshot: .demo(), originName: "Tanjung Malim"))
                    }
            })
        // The recap's full-screen route map, with the step card over its bottom (Q15: Legal sits above the card).
        case "recap-map":
            let model = RecapModel(snapshot: .demo(), originName: "Tanjung Malim")
            if let recap = model.recap, let snapshot = model.snapshot {
                return AnyView(RecapMapView(recap: recap, snapshot: snapshot, onClose: {}))
            }
            return AnyView(Color.clear)
        case "add-search":
            return sheet(query: "Tapah", picked: nil, kind: .fuel, minutes: nil, canMeet: false)
        case "add-details":
            let place = DestinationResult(name: "R&R Tapah (northbound)", subtitle: "Perak", coordinate: .init(latitude: 4.2, longitude: 101.25), category: MKPointOfInterestCategory.restroom.rawValue)
            return sheet(query: "", picked: place, kind: .fuel, minutes: 20, canMeet: false)
        case "add-meet":
            let place = DestinationResult(name: "Petronas Sungai Buloh", subtitle: "Selangor", coordinate: .init(latitude: 3.2, longitude: 101.58), category: MKPointOfInterestCategory.gasStation.rawValue)
            return sheet(query: "", picked: place, kind: .meet, minutes: nil, canMeet: true, meet: true)
        // Home's sheet (D32): the list short and tall, and a picked trip short, tall, on a stop, loading, failed.
        case "home-compact": return home("list")
        case "home-tall": return home("list-tall")
        case "home-picked": return home("short")
        case "home-picked-tall": return home("tall")
        case "home-picked-item": return home("item")
        case "home-picked-loading": return home("loading")
        case "home-picked-failed": return home("failed")
        case "stop-request-places": return AnyView(StopCardPreview(scene: "responder", screen: "places"))
        case "stop-request-places-two-reasons": return AnyView(StopCardPreview(scene: "two", screen: "places-two-reasons"))
        case "stop-request-no-places": return AnyView(StopCardPreview(scene: "responder", screen: "no-places"))
        case "stop-approach": return AnyView(StopApproachDemo.view())
        case "stop-approach-food": return AnyView(StopApproachDemo.view(food: true))
        case "road-route-rebuilt": return AnyView(StopApproachDemo.routeNotice(waiting: false))
        case "road-route-waiting": return AnyView(StopApproachDemo.routeNotice(waiting: true))
        default: return BannerSlotDemo.view(name)
        }
    }
}
#endif
