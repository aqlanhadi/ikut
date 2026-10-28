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

    /// Pins in drawing order: the chosen R&R last, so it is on top.
    var orderedPins: [LobbyPin] { pins.sorted { !$0.isSelectedCandidate && $1.isSelectedCandidate } }
}

/// How the content is drawn: what only the view knows.
struct TripMapStyle {
    var cameraHeading = 0.0
    var containerWidth: CGFloat = 0
    /// Where a coordinate is drawn on screen now, for the cars' glide (`MarkerGlide`); nil off the driving host.
    var point: ((MapCoordinate) -> CGPoint?)?
    /// Changes when running slides must be placed (`TripMapStage.placeSlides`).
    var placeSlides = 0

    func converting(_ point: @escaping (MapCoordinate) -> CGPoint?) -> TripMapStyle {
        var style = self
        style.point = point
        return style
    }
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
                    .modifier(MarkerGlide(coordinate: marker.coordinate, duration: marker.glide,
                                          place: style.placeSlides, point: style.point))
            }
            .annotationTitles(.hidden)
        }
    }
}

/// A car's marker gliding to its new place (D70). MapKit plays its own short ease for an annotation that moves, whatever
/// animation it is given, so the annotation is moved at once and its view starts back where the car is drawn now
/// (the step in points, from the map's own conversion, which knows its heading, pitch and padding, plus what is left
/// of a slide still running) and slides to it linearly over `duration`, a SwiftUI animation MapKit leaves alone.
/// Placed instead: with Reduce Motion, for a car placed rather than glided (`duration` 0), for a step too small to
/// see (`placeUnder`), and whenever `place` changes (a flight, the scale moving), so a slide never runs on in
/// points of a scale the map has left.
struct MarkerGlide: ViewModifier {
    var coordinate: MapCoordinate
    var duration: TimeInterval
    var place: Int
    var point: ((MapCoordinate) -> CGPoint?)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset = CGSize.zero
    @State private var slide: Slide?

    /// A step shorter than this, in points, is placed: a standing car, or one far out at Fit zoom.
    static let placeUnder: CGFloat = 1.5
    /// A scale change bigger than this share places the slides.
    static let scaleTolerance = 0.1

    struct Slide: Equatable {
        var from: CGSize
        var start: Date
        var duration: TimeInterval

        /// The offset still to cover at `now` (the slide is linear).
        func remaining(at now: Date) -> CGSize {
            let left = max(0, 1 - now.timeIntervalSince(start) / max(duration, 0.001))
            return CGSize(width: from.width * left, height: from.height * left)
        }
    }

    static func scaleMoved(from: Double, to: Double) -> Bool {
        guard from > 0, to > 0 else { return false }
        return abs(to / from - 1) > scaleTolerance
    }

    static func worthGliding(_ from: CGSize) -> Bool {
        (from.width * from.width + from.height * from.height).squareRoot() >= placeUnder
    }

    func body(content: Content) -> some View {
        content
            .offset(offset)
            .onChange(of: coordinate) { old, new in start(from: old, to: new) }
            .onChange(of: place) { stop() }
    }

    private func start(from old: MapCoordinate, to new: MapCoordinate) {
        let now = Date()
        let left = slide?.remaining(at: now) ?? .zero
        guard !reduceMotion, duration > 0, let a = point?(old), let b = point?(new) else { stop(); return }
        let from = CGSize(width: a.x - b.x + left.width, height: a.y - b.y + left.height)
        guard Self.worthGliding(from) else { stop(); return }
        jump(to: from)
        withAnimation(.linear(duration: duration)) { offset = .zero }
        slide = Slide(from: from, start: now, duration: duration)
    }

    private func stop() {
        slide = nil
        jump(to: .zero)
    }

    private func jump(to value: CGSize) {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { offset = value }
    }
}
