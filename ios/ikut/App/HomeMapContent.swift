import CoreLocation
import MapKit
import SwiftUI

/// What Home draws on the app's one map (D54), as plain values: its list's past routes, a picked past trip, or the
/// create flow's pins and route. Which of them is set is decided by `TripMapInput.home`, `.picked` and `.newTrip`.
struct HomeMapInput {
    /// Home's list: the newest past routes, newest first.
    var pastRoutes: [PastTripRoute] = []
    /// The name Home lists for each past trip (by id), which may be newer than its cached route's.
    var pastNames: [String: String] = [:]
    /// A picked past trip's route, with its start and destination flag.
    var pickedRoute: PastTripRoute?
    /// Its stops and road reports, from its recap.
    var recapDots: [RecapTimelineItem] = []
    var selectedDotId: String?
    /// Where to?'s results (or the dropped pin), or New trip's one destination.
    var places: [DestinationResult] = []
    /// The result at the top of Where to?'s list.
    var focusedPlaceId: String?
    /// New trip's route, drawn to its destination before the trip is made.
    var newTripRoute: [CLLocationCoordinate2D] = []
}

/// Home's drawing on the one map: the past routes (the newest in the accent with its name, older ones fainter, a tap on
/// a destination picks that trip), a picked trip's route and recap dots, or Where to?'s pins and New trip's route.
struct HomeMapContent: MapContent {
    var input: HomeMapInput
    var style: TripMapStyle

    var body: some MapContent {
        // Oldest first so the newest draws on top.
        ForEach(Array(input.pastRoutes.enumerated().reversed()), id: \.element.id) { index, route in
            pastRoute(route, latest: index == 0)
        }
        if let route = input.pickedRoute { pickedRoute(route) }
        ForEach(input.recapDots) { item in
            let selected = input.selectedDotId == item.id
            Annotation(PickedTripLogic.pinLabel(item), coordinate: item.coordinate ?? route0, anchor: .center) {
                // A tap selects it like its timeline row (and doesn't fall through to the map's tap-away).
                Button { style.onRecapDotTap(item.id) } label: {
                    RecapEventDot(kind: item.kind, symbol: item.symbol, size: selected ? 30 : 22, selected: selected)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: SheetButtonSize.hit, height: SheetButtonSize.hit)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PickedTripLogic.pinLabel(item))
                .accessibilityHint("Shows it on the map")
            }
            .annotationTitles(selected ? .visible : .hidden)
        }
        if input.newTripRoute.count > 1 {
            MapPolyline(coordinates: input.newTripRoute)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: input.newTripRoute)
                .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        // New trip draws its one destination dark with its name; Where to? its results red, the top one larger.
        let destination = input.newTripRoute.count > 1
        ForEach(input.places) { place in
            let focused = !destination && place.id == input.focusedPlaceId
            Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                Self.placePin(focused: focused, color: destination ? Color(.label) : .red)
            }
            .annotationTitles(destination || focused ? .visible : .hidden)
        }
    }

    /// Never drawn: a recap dot always has a coordinate (`PickedTripLogic.markers`).
    private var route0: CLLocationCoordinate2D { .init(latitude: 0, longitude: 0) }

    @MapContentBuilder
    private func pastRoute(_ route: PastTripRoute, latest: Bool) -> some MapContent {
        let line = route.coordinates
        let name = input.pastNames[route.id] ?? route.name
        if line.count > 1 {
            MapPolyline(coordinates: line)
                .stroke(.white.opacity(latest ? 0.9 : 0.6),
                        style: StrokeStyle(lineWidth: latest ? 9 : 6, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: line)
                .stroke(Color.ikutAccent.opacity(latest ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: latest ? 5 : 3, lineCap: .round, lineJoin: .round))
        }
        if let start = route.start {
            Annotation("", coordinate: start, anchor: .center) {
                Circle().fill(.white).frame(width: latest ? 12 : 9, height: latest ? 12 : 9)
                    .overlay(Circle().stroke(Color.ikutAccent.opacity(latest ? 1 : 0.6), lineWidth: latest ? 3 : 2))
                    .accessibilityHidden(true)
            }
            .annotationTitles(.hidden)
        }
        Annotation(name, coordinate: route.destination, anchor: .center) {
            Button { style.onPastTripTap(route.id) } label: {
                Image(systemName: "flag.checkered")
                    .ikutGlyph(latest ? 13 : 10, weight: .bold, cap: 1.3)
                    .foregroundStyle(latest ? .white : Color.ikutAccent)
                    .frame(width: latest ? 30 : 22, height: latest ? 30 : 22)
                    .background(latest ? Color.ikutAccent : Color.white, in: Circle())
                    .overlay(Circle().stroke(latest ? Color.white : Color.ikutAccent.opacity(0.6), lineWidth: 2))
                    .elevation(.marker)
                    .frame(width: SheetButtonSize.hit, height: SheetButtonSize.hit)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(name), to \(route.destinationName)")
            .accessibilityHint("Shows the trip on the map")
        }
        .annotationTitles(latest ? .automatic : .hidden)
    }

    /// Only the picked trip's route, a dot at its start and a flag at the destination.
    @MapContentBuilder
    private func pickedRoute(_ route: PastTripRoute) -> some MapContent {
        let line = route.coordinates
        if line.count > 1 {
            MapPolyline(coordinates: line)
                .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: line)
                .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
        }
        if let start = route.start {
            Annotation("", coordinate: start, anchor: .center) {
                Circle().fill(.white).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.ikutAccent, lineWidth: 3))
                    .accessibilityHidden(true)
            }
            .annotationTitles(.hidden)
        }
        Annotation(route.destinationName, coordinate: route.destination, anchor: .center) {
            Image(systemName: "flag.checkered")
                .ikutGlyph(13, weight: .bold, cap: 1.3)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.ikutAccent, in: Circle())
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .elevation(.marker)
                .accessibilityHidden(true)
        }
        .annotationTitles(.visible)
    }

    private static func placePin(focused: Bool, color: Color) -> some View {
        let size: CGFloat = focused ? 36 : 28
        return Image(systemName: "mappin")
            .ikutGlyph(focused ? 16 : 13, weight: .bold, cap: 1.3)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .elevation(.marker)
            .accessibilityHidden(true)
    }
}
