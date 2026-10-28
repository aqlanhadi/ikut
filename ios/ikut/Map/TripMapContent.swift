import CoreLocation
import MapKit
import SwiftUI

/// What one trip's map draws, as plain values, so the lobby and the driving map are the same drawing fed differently
/// (D53). Which layers a screen asks for is decided here, in `lobby` and `driving`, and tested.
struct TripMapInput {
    /// The layers a screen asks for, to say (and test) who draws what.
    struct Layers: OptionSet {
        let rawValue: Int
        static let user = Layers(rawValue: 1)
        static let route = Layers(rawValue: 2)
        static let ownRoute = Layers(rawValue: 4)
        static let overlays = Layers(rawValue: 8)
        static let pins = Layers(rawValue: 16)
        static let hazards = Layers(rawValue: 32)
        static let cars = Layers(rawValue: 64)
        /// Home (D54): the routes of your past trips.
        static let pastRoutes = Layers(rawValue: 128)
        /// Home: the past trip picked, with its start and destination.
        static let pickedRoute = Layers(rawValue: 256)
        /// Home: the picked trip's stops and road reports from its recap.
        static let recapDots = Layers(rawValue: 512)
        /// Where to?'s results (or the dropped pin), or New trip's destination.
        static let places = Layers(rawValue: 1024)
        /// New trip's route, before the trip is made.
        static let newTripRoute = Layers(rawValue: 2048)
    }

    var showsUser = false
    var route: [CLLocationCoordinate2D] = []
    /// A participant's own way in, solid in their car's colour (the lobby; theirs only).
    var ownRoute: [CLLocationCoordinate2D] = []
    var ownColorHex = "#0A7CFF"
    /// Other cars' routes, dashed, with their join points (driving only, after Start).
    var overlays: [RouteOverlay] = []
    /// Stop pins, the destination flag, the join point and Add a stop's candidates; the chosen one is drawn on top.
    var pins: [LobbyPin] = []
    var hazards: [HazardMarker] = []
    var cars: [MapMarker] = []
    /// Home: what it draws over the same map (`home`, `picked`, `newTrip`).
    var home = HomeMapInput()

    var layers: Layers {
        var result: Layers = []
        if showsUser { result.insert(.user) }
        if route.count > 1 { result.insert(.route) }
        if ownRoute.count > 1 { result.insert(.ownRoute) }
        if !overlays.isEmpty { result.insert(.overlays) }
        if !pins.isEmpty { result.insert(.pins) }
        if !hazards.isEmpty { result.insert(.hazards) }
        if !cars.isEmpty { result.insert(.cars) }
        if !home.pastRoutes.isEmpty { result.insert(.pastRoutes) }
        if home.pickedRoute != nil { result.insert(.pickedRoute) }
        if !home.recapDots.isEmpty { result.insert(.recapDots) }
        if !home.places.isEmpty { result.insert(.places) }
        if home.newTripRoute.count > 1 { result.insert(.newTripRoute) }
        return result
    }

    /// The lobby: your position, the route, your own way in, the pins. Never another car's start or join point (#361)
    /// and no car markers: only the driving map has them, after Start.
    static func lobby(route: [CLLocationCoordinate2D], pins: [LobbyPin], ownRoute: [CLLocationCoordinate2D],
                      ownColorHex: String) -> TripMapInput {
        TripMapInput(showsUser: true, route: route, ownRoute: ownRoute, ownColorHex: ownColorHex, pins: pins)
    }

    /// The driving map: the route, other cars' routes and join points, hazards and the cars.
    static func driving(route: [CLLocationCoordinate2D], overlays: [RouteOverlay], hazards: [HazardMarker],
                        cars: [MapMarker]) -> TripMapInput {
        TripMapInput(route: route, overlays: overlays, hazards: hazards, cars: cars)
    }

    /// Home's list: your position and the routes of your past trips, newest first (`names`: the name Home lists for
    /// each, which may be newer than the cached route's).
    static func home(routes: [PastTripRoute], names: [String: String]) -> TripMapInput {
        TripMapInput(showsUser: true, home: HomeMapInput(pastRoutes: routes, pastNames: names))
    }

    /// A past trip picked on Home: only its route, with its stops and road reports.
    static func picked(route: PastTripRoute?, dots: [RecapTimelineItem], selectedId: String?) -> TripMapInput {
        TripMapInput(home: HomeMapInput(pickedRoute: route, recapDots: dots, selectedDotId: selectedId))
    }

    /// Where to? (the results as pins, `focusedId` the one at the top of the list) or New trip (`route` drawn to its
    /// one destination).
    static func newTrip(places: [DestinationResult], focusedId: String?, route: [CLLocationCoordinate2D]) -> TripMapInput {
        TripMapInput(showsUser: true, home: HomeMapInput(places: places, focusedPlaceId: focusedId, newTripRoute: route))
    }

    /// The cars drawn at `drawn` (the driving layer's glide, D70) where it has them.
    func drawing(cars drawn: [String: MapCoordinate]) -> TripMapInput {
        guard !drawn.isEmpty else { return self }
        var input = self
        input.cars = cars.map { car in
            var car = car
            if let spot = drawn[car.id] { car.coordinate = spot }
            return car
        }
        return input
    }

    /// Pins in drawing order: the chosen R&R last, so it is on top.
    var orderedPins: [LobbyPin] { pins.sorted { !$0.isSelectedCandidate && $1.isSelectedCandidate } }
}

/// How the content is drawn: what only the view knows.
struct TripMapStyle {
    var cameraHeading = 0.0
    var containerWidth: CGFloat = 0
    /// The hazard that pings because an alert for it is up.
    var pingingEventId: String?
    var onCandidateTap: (String) -> Void = { _ in }
    /// Home: a past trip's destination flag (its id).
    var onPastTripTap: (String) -> Void = { _ in }
    /// Home: one of the picked trip's stops or road reports (its timeline id).
    var onRecapDotTap: (String) -> Void = { _ in }
}

/// The one map layer both screens draw with. The camera, gestures and padding stay in each view.
struct TripMapContent: MapContent {
    var input: TripMapInput
    var style = TripMapStyle()

    var body: some MapContent {
        if input.showsUser { UserAnnotation() }
        HomeMapContent(input: input.home, style: style)
        if input.route.count > 1 {
            MapPolyline(coordinates: input.route)
                .stroke(MapPalette.routeCasing, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: input.route)
                .stroke(MapPalette.route, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
        }
        if input.ownRoute.count > 1 {
            MapPolyline(coordinates: input.ownRoute)
                .stroke(Color.car(hex: input.ownColorHex), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        ForEach(input.overlays) { overlay in
            let path = overlay.path.map(\.clCoordinate)
            MapPolyline(coordinates: path)
                .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: path)
                .stroke(
                    Color.car(hex: overlay.colorHex),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [6, 6]))
            if let merge = overlay.merge {
                Annotation("Join point", coordinate: merge.clCoordinate, anchor: .center) {
                    MergePointView(colorHex: overlay.colorHex, containerWidth: style.containerWidth)
                }
                .annotationTitles(.hidden)
            }
        }
        ForEach(input.orderedPins) { pin in
            Annotation("", coordinate: pin.coordinate, anchor: .bottom) {
                LobbyPinView(pin: pin, colorHex: input.ownColorHex)
                    .onTapGesture { if case .candidate = pin.kind { style.onCandidateTap(pin.id) } }
            }
        }
        ForEach(input.hazards) { hazard in
            Annotation(hazard.label, coordinate: hazard.coordinate, anchor: .center) {
                HazardMapContent(marker: hazard, pinging: hazard.id == style.pingingEventId)
                    .accessibilityIdentifier("hazard.marker")
            }
            .annotationTitles(.hidden)
        }
        ForEach(input.cars) { marker in
            Annotation(marker.name, coordinate: marker.coordinate.clCoordinate, anchor: .center) {
                MapMarkerView(marker: marker, cameraHeading: style.cameraHeading, containerWidth: style.containerWidth)
            }
            .annotationTitles(.hidden)
        }
    }
}
