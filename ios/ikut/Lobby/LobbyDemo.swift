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
        case organizer, organizerEmpty, member, meetAndFailure, turnBack, suggestAdded, started
        /// The organiser pulled up to the tall height (B5).
        case tall
        /// B4: a meeting point, five cars, the last one not sharing yet.
        case notReady
        /// The organiser's lobby before the start with this phone sharing: "Sharing" leads the subtitle (#394).
        case sharing
        /// Driving, the organiser's convoy sheet pulled up with R&R Bidor passed (D53, canvas row L).
        case pulledUp
        /// Driving, a participant no longer in the trip: the banner with Back to trips on the folded sheet (#403).
        case drivingLost
        /// A trip nobody has joined, one whose route is being rebuilt, and one that couldn't be read.
        case noCars, routeUpdating, unreadable
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

    static func lobby(_ scene: Scene, driving: LobbyView.SampleDriving? = nil) -> LobbyView {
        let planner = StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in })
        func model(_ stops: [PlannedStop], started: Bool = false) -> LobbyModel {
            let model = LobbyModel.sample(started: started, seconds: 2 * 3600 + 40 * 60, stops: stops, route: route)
            planner.sync(trip: model.trip, stops: model.stops)
            return model
        }
        /// Wyna’s X70 joins 45 km along and Hafiz’s Hilux 90 km along, Daniel’s City leaves with the convoy.
        func joining(_ base: LobbyModel) -> LobbyModel {
            let offsets = ["c2": 45_000.0, "c3": 90_000.0, "c4": 0.0]
            let cars = base.cars.map { car -> Car in
                var car = car
                car.mergeOffset = car.id.flatMap { offsets[$0] }
                return car
            }
            return LobbyModel(sampleTrip: base.trip!, cars: cars, members: base.members, stops: base.stops)
        }
        /// The demo geocoder answers at once: Rawang near KL, Tanjung Malim further up.
        let towns = JoinTowns(place: { $0.latitude < 3.55 ? "Rawang" : "Tanjung Malim" }, pause: .zero)
        switch scene {
        case .organizer:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(
                sample: joining(model(stopsOnRoute)), planner: planner, organizer: true, joinTowns: towns, driving: driving)
        case .tall:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: true, tall: true)
        case .notReady:
            let meet = StopDraft(
                id: "m", name: "Petronas Jalan Duta", coordinate: .init(latitude: 3.17, longitude: 101.68), kind: .meet,
                meetAt: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()), routeOffset: 0)
            let items = [meet] + stopsOnRoute.map(StopDraft.init)
            planner.showForDemo(items: items)
            let base = model(stopsOnRoute)
            func ready(_ car: Car) -> Car { var car = car; car.trackerUserId = car.trackerUserId ?? "u3"; return car }
            let siti = Car(id: "c5", name: "Siti’s Bezza", color: "#8E8E93", trackerUserId: nil, isLead: false, route: nil,
                           mergeOffset: nil, state: .convoy, number: 5)
            let crowded = LobbyModel(
                sampleTrip: base.trip!, cars: joining(base).cars.map(ready) + [siti],
                members: base.members + [Member(id: "u8", displayName: "Nora", carId: "c5", role: .member)],
                stops: base.stops)
            return LobbyView(sample: crowded, planner: planner, organizer: true, joinTowns: towns)
        case .organizerEmpty:
            return LobbyView(sample: model([]), planner: planner, organizer: true)
        case .suggestAdded:
            // After Add in Suggest stops: the R&R is an ordinary 20 min Rest in the list (SuggestStops.dc.html d).
            let tapah = [stop("s1", "R&R Tapah (northbound)", 4.2, 101.25, .rest, 20, 0)]
            planner.showForDemo(items: tapah.map(StopDraft.init))
            return LobbyView(sample: model(tapah), planner: planner, organizer: true)
        case .member:
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: false)
        case .noCars:
            let base = model(stopsOnRoute)
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(sample: LobbyModel(sampleTrip: base.trip!, cars: [], members: [], stops: base.stops), planner: planner, organizer: true)
        case .routeUpdating:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init), status: .building)
            return LobbyView(sample: model(stopsOnRoute), planner: planner, organizer: true, tall: true)
        case .unreadable:
            return LobbyView(sample: LobbyModel(sampleError: "Can’t reach the server. Check your signal and try again."), planner: planner, organizer: true)
        case .sharing:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(
                sample: joining(model(stopsOnRoute)), planner: planner, organizer: true, joinTowns: towns, sharing: true)
        case .pulledUp, .drivingLost:
            let lost = scene == .drivingLost
            // The first stop along the way (R&R Bidor) left 20 minutes ago; the others still ahead.
            var stops = stopsOnRoute
            stops[0].arrivedAt = Date().addingTimeInterval(-35 * 60)
            stops[0].leftAt = Date().addingTimeInterval(-20 * 60)
            stops[0].leftBy = "u1"
            return LobbyView(
                sample: model(stops, started: true), planner: planner, organizer: !lost, sharing: !lost, lost: lost,
                driving: { continuation, banner in
                    let map = MapDemo.model()
                    map.mode = TripScreenLogic.drivingEntryMode
                    return AnyView(TripMapView(
                        session: TripSession(tripId: "demo", userId: "u-c1"), model: map, stopService: DemoStopService(),
                        demoPulledUp: !lost, continuation: continuation, topBanner: banner))
                })
        case .started:
            planner.showForDemo(items: stopsOnRoute.map(StopDraft.init))
            return LobbyView(sample: model(stopsOnRoute, started: true), planner: planner, organizer: true)
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

/// Add a stop on KL to Ipoh (AddStop.dc.html): four R&Rs along the route, in the lobby's own sheet.
extension LobbyStopsDemo {
    enum AddScene { case list, picked, results, searchedPlace, meetingPoint, searchError }

    private static func rnr(_ id: String, _ name: String, _ lat: Double, _ lng: Double) -> PlaceAlong {
        let at = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let offset = RouteLine(route).project(at)?.offset ?? 0
        return PlaceAlong(
            id: id, kind: .services, name: name, coordinate: at, ring: nil, facilities: [.fuel, .food, .toilets], brands: [],
            offset: offset, distance: 40, side: .left, carriageway: .ours, ours: true, entrance: at, slipEntrance: false, routeOffset: offset)
    }

    static func addStop(_ scene: AddScene) -> LobbyView {
        let planner = StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in })
        let trip = LobbyModel.sample(started: false, seconds: 2 * 3600 + 40 * 60, stops: [], route: route)
        planner.sync(trip: trip.trip, stops: trip.stops)
        let candidates = [
            rnr("demo/gopeng", "Gopeng R&R", 4.45, 101.12), rnr("demo/sungai-buloh", "Sungai Buloh R&R", 3.2, 101.64),
            rnr("demo/tapah", "Tapah R&R", 4.2, 101.25), rnr("demo/behrang", "Behrang R&R", 3.8, 101.33),
        ]
        let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
        let model = AddStopModel(line: RouteLine(route), routeSeconds: 2 * 3600 + 40 * 60,
                                 along: AlongRoute(coordinates: route, seconds: 2 * 3600 + 40 * 60),
                                 canMeet: scene == .meetingPoint, canAdd: true, candidates: candidates)
        let place = DestinationResult(name: "Petronas Sungai Buloh", subtitle: "Selangor", coordinate: .init(latitude: 3.2, longitude: 101.58),
                                      category: MKPointOfInterestCategory.gasStation.rawValue)
        switch scene {
        case .list: break
        case .picked: model.select("demo/tapah")
        case .searchError:
            model.search.query = "petrol station"
            model.search.errorMessage = CreateTripModel.searchMessage
        case .results:
            model.search.showForDemo(query: "petrol station", results: [
                place,
                DestinationResult(name: "Petronas Tapah Road", subtitle: "Perak", coordinate: .init(latitude: 4.17, longitude: 101.3), category: MKPointOfInterestCategory.gasStation.rawValue),
                DestinationResult(name: "Shell Taiping", subtitle: "Perak", coordinate: .init(latitude: 4.85, longitude: 100.74), category: MKPointOfInterestCategory.gasStation.rawValue),
            ], origin: kl, originName: "Kuala Lumpur")
        case .searchedPlace:
            model.pick(place)
            model.searchedMinutes = 20
        case .meetingPoint:
            model.pick(place)
            model.kind = .meet
            model.meetClock = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())
        }
        return LobbyView(sample: trip, planner: planner, organizer: true, adding: model)
    }
}

/// The Suggest stops sheet on KL to Ipoh (SuggestStops.dc.html): one R&R on our side of the route.
@MainActor
enum SuggestStopsDemo {
    static func sheet(seconds: Double = 2 * 3600 + 25 * 60, moved: Int = 0, nothing: Bool = false, noRoute: Bool = false) -> some View {
        let line = RouteLine(LobbyStopsDemo.route)
        let at = CLLocationCoordinate2D(latitude: 4.2, longitude: 101.25)
        let offset = line.project(at)?.offset ?? 0
        let tapah = PlaceAlong(
            id: "demo/tapah", kind: .services, name: "R&R Tapah (northbound)", coordinate: at, ring: nil,
            facilities: [.fuel, .food, .toilets], brands: [], offset: offset, distance: 40, side: .left,
            carriageway: .ours, ours: true, entrance: at, slipEntrance: false, routeOffset: offset)
        let model = SuggestStopsModel(line: noRoute ? nil : line, routeSeconds: seconds, existing: [], sites: [], fuel: [], candidates: nothing ? [] : [tapah])
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

/// `trip-start-swap`: the organiser's lobby, and 2 s later Start trip, so the switch to driving can be watched: the same
/// map, the camera from the whole route to my car, the lobby's sheet becoming the convoy's (D53).
struct TripStartSwapDemo: View {
    @Environment(TripScreenModel.self) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let lobby = LobbyStopsDemo.lobby(.organizer, driving: { continuation, banner in
        let model = MapDemo.model()
        model.mode = TripScreenLogic.drivingEntryMode
        return AnyView(TripMapView(
            session: TripSession(tripId: "demo", userId: "u-c1"), model: model, stopService: DemoStopService(),
            continuation: continuation, topBanner: banner))
    })

    var body: some View {
        lobby.task {
            try? await Task.sleep(for: .seconds(2))
            let next = TripScreenLogic.mode(after: .start, from: stage.mode)
            withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { stage.go(to: next) }
        }
    }
}

/// `home-create-swap`: Home's New trip over the one map, and 2 s later Create trip, so the switch to the lobby can be
/// watched: the same map, the camera from New trip's route to the whole trip above the lobby's sheet, New trip's sheet
/// becoming the lobby's (D54). Nothing is written.
struct HomeCreateSwapDemo: View {
    @Environment(TripScreenModel.self) private var stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if stage.tripId == nil {
                HomePickedDemo.view("new-trip")
            } else {
                LobbyStopsDemo.lobby(.organizer)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { stage.open(tripId: "demo", started: false) }
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
        /// A lobby is the trip screen's lobby mode, over the screen's one map.
        func trip<V: View>(_ view: V) -> AnyView { nav(TripScreenHost { view }) }
        func home(_ state: String) -> AnyView {
            // Home is the Home mode of the app's one map (D54).
            AnyView(TripScreenHost(mode: .home) { HomePickedDemo.view(state) }.environment(AuthModel()).environment(LocationPermission()))
        }
        func lobbyAsking(_ scene: LobbyStopsDemo.Scene, _ ask: String) -> LobbyView {
            var lobby = LobbyStopsDemo.lobby(scene)
            lobby.demoAsk = ask
            return lobby
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
        case "search-error":
            let model = CreateTripModel()
            model.query = "petrol station"
            model.errorMessage = CreateTripModel.searchMessage
            return search(model)
        // Q23: screens that had no launch state. First, the ones before Home: welcome, the name step, the location
        // denied page and the Always explainer, each on its own.
        case "welcome": return AnyView(WelcomeView(onGetStarted: {}, onJoin: {}))
        case "name-entry": return AnyView(NameEntryView().environment(AuthModel()))
        case "location-denied": return AnyView(LocationDeniedView(onOpenSettings: {}))
        case "always-explainer": return AnyView(AlwaysLocationExplainerView(permission: LocationPermission(), onFinish: { _ in }))
        // Home's name alert (with its field) and the one saying it couldn't be saved.
        case "home-rename": return home("rename")
        case "home-rename-error": return home("rename-error")
        // D72 (Debug): Home's name button opens Settings: on You, on Design, and Design with the font sizes list pushed.
        case "settings": return home("settings")
        case "settings-design": return home("settings-design")
        case "settings-design-fonts": return home("settings-design-fonts")
        // The lobby with an ask already up: Start with a car not sharing, Leave, End, Trip name, the QR code.
        case "lobby-confirm-start": return trip(lobbyAsking(.notReady, "start"))
        case "lobby-confirm-leave": return trip(lobbyAsking(.member, "leave"))
        case "lobby-confirm-end": return trip(lobbyAsking(.organizer, "end"))
        case "lobby-rename": return trip(lobbyAsking(.organizer, "rename"))
        case "lobby-qr": return trip(lobbyAsking(.organizer, "qr"))
        case "lobby-action-error": return trip(lobbyAsking(.organizer, "action-error"))
        case "lobby-change-destination": return trip(lobbyAsking(.organizer, "change-destination"))
        case "lobby-no-cars": return trip(LobbyStopsDemo.lobby(.noCars))
        case "lobby-route-updating": return trip(LobbyStopsDemo.lobby(.routeUpdating))
        case "lobby-error": return trip(LobbyStopsDemo.lobby(.unreadable))
        // Before Home: the name step with its sign-in problem line and its spinner; the first screen with no trips.
        case "name-entry-error", "name-entry-signing-in":
            return AnyView(NameEntryView(demo: name == "name-entry-error" ? "error" : "signing-in").environment(AuthModel()))
        case "join-location-off":
            return AnyView(TripScreenHost(mode: .home) { HomePickedDemo.view(name) }
                .environment(AuthModel()).environment(LocationPermission(demo: .denied)))
        case "home-empty": return home("empty")
        case "home-new-trip-error": return home("new-trip-error")
        case "home-new-trip-creating": return home("new-trip-creating")
        case "root-loading": return AnyView(ProgressView())
        case "alert-banner": return AnyView(MapDemo.alertBanner())
        case "road-offline": return AnyView(MapDemo.view(online: false))
        // Driving, the two notification asks the map makes at trip start.
        case "road-ask-alerts": return AnyView(MapDemo.view(ask: .roadAlerts))
        case "road-ask-alerts-off": return AnyView(MapDemo.view(ask: .roadAlertsOff))
        // The stop card's other screens: the message typed, "Are you a passenger?", and "Sent to the convoy".
        case "road-card-pit-stop-typed": return AnyView(MapDemo.view(card: "typed"))
        case "road-card-pit-stop-passenger": return AnyView(MapDemo.view(card: "passenger"))
        case "road-card-pit-stop-sent": return AnyView(MapDemo.view(card: "sent"))
        // Suggest stops with nothing near that time, and with no route to look along.
        case "suggest-stops-nothing": return AnyView(SuggestStopsDemo.sheet(nothing: true))
        case "suggest-stops-cant": return AnyView(SuggestStopsDemo.sheet(noRoute: true))
        case "add-search-error": return trip(LobbyStopsDemo.addStop(.searchError))
        // The recap page while it loads, and when it couldn't load.
        case "recap-loading", "recap-failed":
            let model = name == "recap-failed" ? RecapModel(failedTripId: "demo") : RecapModel(tripId: "demo-never-loaded")
            return AnyView(NavigationStack {
                Color.clear.navigationTitle("Trips").navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(isPresented: .constant(true)) { RecapView(model: model) }
            })
        case "lobby-organizer": return trip(LobbyStopsDemo.lobby(.organizer))
        case "lobby-tall": return trip(LobbyStopsDemo.lobby(.tall))
        case "lobby-not-ready": return trip(LobbyStopsDemo.lobby(.notReady))
        case "lobby-empty": return trip(LobbyStopsDemo.lobby(.organizerEmpty))
        case "lobby-suggest-added": return trip(LobbyStopsDemo.lobby(.suggestAdded))
        // The Suggest stops sheet: the button is on lobby-empty; then the suggestion, the stepper moved, a short trip,
        // and the largest text.
        case "suggest-stops": return AnyView(SuggestStopsDemo.sheet())
        case "suggest-stops-moved": return AnyView(SuggestStopsDemo.sheet(moved: 1))
        case "suggest-stops-short": return AnyView(SuggestStopsDemo.sheet(seconds: 50 * 60))
        case "suggest-stops-large": return AnyView(SuggestStopsDemo.sheet().dynamicTypeSize(.accessibility5))
        // lobby-member: a participant before the organiser starts (the waiting line, D39).
        case "lobby-member": return trip(LobbyStopsDemo.lobby(.member))
        case "lobby-turnback": return trip(LobbyStopsDemo.lobby(.turnBack))
        case "lobby-meet-failure": return trip(LobbyStopsDemo.lobby(.meetAndFailure))
        // lobby-started: the organiser back in the lobby after Start trip, the convoy on the move.
        case "lobby-started": return trip(LobbyStopsDemo.lobby(.started))
        // The lobby, then Start trip after 2 s: the sheet becomes the convoy's and the camera flies to my car (D53).
        case "trip-start-swap": return trip(TripStartSwapDemo())
        // Driving with the convoy sheet pulled up: the journey (R&R Bidor passed), code, trip, options, End (D53).
        case "road-pulled-up": return nav(TripScreenHost(mode: .driving) { LobbyStopsDemo.lobby(.pulledUp) })
        // The organiser's lobby before the start while this phone shares: "➤ Sharing" leads the subtitle (#394).
        case "lobby-sharing": return trip(LobbyStopsDemo.lobby(.sharing))
        // Driving, no longer in the trip: "You’re no longer in this trip" and Back to trips on top of the sheet (#403).
        case "road-no-longer-in-trip": return nav(TripScreenHost(mode: .driving) { LobbyStopsDemo.lobby(.drivingLost) })
        case "road-markers": return AnyView(MapMarkersDemo())
        case "road-header-moving": return AnyView(PanelHeaderDemo(.moving))
        case "road-header-parked": return AnyView(PanelHeaderDemo(.parked))
        case "road-header-never": return AnyView(PanelHeaderDemo(.never))
        case "road-header-convoy": return AnyView(PanelHeaderDemo(nil))
        case "road-panel-you-offline": return AnyView(MapDemo.view(expanded: true, online: false))
        case "road-panel-tall": return AnyView(MapDemo.view(expanded: true))
        // Five cars: the list is longer than the sheet's room, so the whole panel scrolls as one (D34 7a).
        case "road-panel-tall-5": return AnyView(MapDemo.view(expanded: true, fiveCars: true))
        // The card sheets over the convoy sheet (D44): Pit stop, "Fuel chosen" in it, and Report.
        case "road-card-pit-stop": return AnyView(MapDemo.view(card: "home"))
        case "road-card-pit-stop-reason": return AnyView(MapDemo.view(card: "reason"))
        // The message field with the keyboard up: the card sits above the keyboard (Q16).
        case "road-card-pit-stop-message": return AnyView(MapDemo.view(card: "message"))
        case "road-card-report": return AnyView(MapDemo.view(report: true))
        case "road-panel-short-5": return AnyView(MapDemo.view(fiveCars: true))
        // The list unfolded; the debris approach folds it 3 s in, and my car passes the debris about 9 s later (D42).
        case "road-hazard-pass": return AnyView(MapDemo.hazardPass())
        case "road-next-stop": return AnyView(NextStopDemo())
        case "road-next-stop-joining-after-leave": return AnyView(NextStopDemo(afterLeave: true))
        // Joining in Home's sheet (D58): the name and the location ask first for someone new (H1, H2), the code (empty, found, found with the drive from here, not found), then which
        // car (nothing picked, someone else's car, my own car). The sheet is the same height on all of them.
        case "join-h1-name", "join-h2-location", "join-h3-empty", "join-h3-found", "join-h3-found-drive", "join-h3-not-found",
             "join-h3-looking", "join-h3-no-signal", "join-h4-joining", "join-h4-car", "join-h4-copilot", "join-h4-own":
            return home(name)
        case "lobby-own-merges": return trip(OwnWayDemo.lobby(.merges))
        case "lobby-own-main": return trip(OwnWayDemo.lobby(.onMain))
        case "lobby-own-never": return trip(OwnWayDemo.lobby(.neverMerges))
        case "lobby-own-noroute": return trip(OwnWayDemo.lobby(.noRoute))
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
        // D57: the camera's long and short hops on the driving map, then the recap map's steps, looping.
        case "camera-tour": return AnyView(CameraTourDemo().environment(LocationPermission()).environment(AuthModel()))
        // D70: following my car on its own fixes every second, the other cars written every 5 s, gliding.
        case "follow-drive": return AnyView(FollowDriveDemo().environment(LocationPermission()).environment(AuthModel()))
        case "follow-drive-interrupts": return AnyView(FollowDriveDemo(interrupts: true).environment(LocationPermission()).environment(AuthModel()))
        case "follow-drive-still": return AnyView(FollowDriveDemo(still: true).environment(LocationPermission()).environment(AuthModel()))
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
        // Add a stop over the map (B6, D51): the R&Rs in order, one chosen, and a searched place that isn't an R&R.
        case "lobby-add-stop": return trip(LobbyStopsDemo.addStop(.list))
        case "lobby-add-stop-picked": return trip(LobbyStopsDemo.addStop(.picked))
        case "add-search": return trip(LobbyStopsDemo.addStop(.results))
        case "add-details": return trip(LobbyStopsDemo.addStop(.searchedPlace))
        case "add-meet": return trip(LobbyStopsDemo.addStop(.meetingPoint))
        // Home's sheet (D32): the list short and tall, and a picked trip short, tall, on a stop, loading, failed.
        case "home-compact": return home("list")
        case "home-tall": return home("list-tall")
        case "home-tap": return home("tap")
        case "home-tour": return home("tour")
        // D57: Home's camera hops (first fix, every trip, a pick, a stop, back, a far hop), paced, looping.
        case "home-camera-tour": return home("camera-tour")
        case "home-picked": return home("short")
        case "home-picked-tall": return home("tall")
        case "home-picked-item": return home("item")
        case "home-picked-loading": return home("loading")
        // The create flow over Home's map (D48): Where to? with results as pins, and New trip with the route drawn.
        // Home with a trip in Now (D49): gathering, on the move, one that couldn't be read. "home-compact" has none.
        case "home-now": return home("now")
        case "home-now-started": return home("now-started")
        case "home-now-failed": return home("now-failed")
        case "home-where-to": return home("where-to")
        case "home-new-trip": return home("new-trip")
        // New trip, then Create trip 2 s later: the switch to the lobby on the same map (D54).
        case "home-create-swap":
            // Its Create trip opens a sample trip: nothing is read, tracked or saved.
            return nav(TripScreenHost(mode: .home, makeTrip: { OpenTrip.sample(tripId: $0) }) { HomeCreateSwapDemo() })
        case "home-picked-failed": return home("failed")
        // A trip left early, picked: its route, and no recap (D54, #421).
        case "home-picked-left": return home("left")
        case "stop-request-places": return AnyView(StopCardPreview(scene: "responder", screen: "places"))
        case "stop-request-places-two-reasons": return AnyView(StopCardPreview(scene: "two", screen: "places-two-reasons"))
        case "stop-request-no-places": return AnyView(StopCardPreview(scene: "responder", screen: "no-places"))
        case "stop-approach-food": return AnyView(StopApproachDemo.view(food: true))
        case "road-route-waiting": return AnyView(StopApproachDemo.routeNotice(waiting: true))
        default: return BannerSlotDemo.view(name)
        }
    }
}
#endif
