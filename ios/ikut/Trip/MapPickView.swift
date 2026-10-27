import CoreLocation
import MapKit
import SwiftUI

/// "Choose on map": a full-screen map with a pin fixed at the centre. The map moves under it; once it settles the
/// spot is named, and "Use this place" picks it as a tapped result would be.
struct MapPickView: View {
    var origin: CLLocationCoordinate2D?
    /// The trip's route when adding a stop: drawn, and the label says how far along the spot is.
    var along: AlongRoute?
    var onUse: (DestinationResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flight = CameraFlight()
    @State private var position: MapCameraPosition
    @State private var center: CLLocationCoordinate2D
    @State private var span: MKCoordinateSpan
    @State private var namer: PinNamer
    /// Between a camera change and its settle, the centre is not yet the spot to name.
    @State private var moving = false

    init(
        origin: CLLocationCoordinate2D?, along: AlongRoute? = nil, start: CLLocationCoordinate2D? = nil,
        geocoder: ReverseGeocoding = CLReverseGeocoder(),
        onUse: @escaping (DestinationResult) -> Void
    ) {
        self.origin = origin
        self.along = along
        _namer = State(initialValue: PinNamer(geocoder: geocoder))
        self.onUse = onUse
        var region = Self.startRegion(origin: origin, route: along?.line.coordinates ?? [])
        if let start { region.center = start }
        _position = State(initialValue: .region(region))
        _center = State(initialValue: region.center)
        _span = State(initialValue: region.span)
    }

    /// The phone's last known spot (never asking for permission), else the trip's route, else Malaysia.
    static func startRegion(origin: CLLocationCoordinate2D?, route: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        if let origin, route.isEmpty { return MKCoordinateRegion(center: origin, span: .init(latitudeDelta: 0.05, longitudeDelta: 0.05)) }
        return SearchRegion.choose(location: nil, route: route)
    }

    /// The label over the pin: the name, else "Near <town>", else the coordinates; "· 62 km along" with a route.
    static func label(_ place: DestinationResult, along: AlongRoute?) -> String {
        [place.name, along?.pinLine(for: place.coordinate)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether a camera frame is away from the spot the map last settled on (under about 1 m counts as the same), so
    /// the answer is right whichever of the continuous and the end callbacks comes last.
    static func isMoving(_ frame: CLLocationCoordinate2D, settled: CLLocationCoordinate2D) -> Bool {
        abs(frame.latitude - settled.latitude) > 1e-5 || abs(frame.longitude - settled.longitude) > 1e-5
    }

    private var spot: DestinationResult { namer.place ?? PinName.place(nil, at: center) }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $position) {
                    if let line = along?.line.coordinates, line.count > 1 {
                        MapPolyline(coordinates: line).stroke(Color.ikutAccent, lineWidth: 5)
                    }
                }
                .mapControls { MapCompass() }
                .onMapCameraChange(frequency: .continuous) { context in
                    moving = Self.isMoving(context.region.center, settled: center)
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    moving = false
                    center = context.region.center
                    span = context.region.span
                    namer.start(center)
                }
                .gesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                        .onEnded { value in
                            guard case .second(true, let drag?) = value,
                                  let spot = proxy.convert(drag.startLocation, from: .local) else { return }
                            // The map glides to the pressed spot at the pace of `CameraPace` instead of snapping.
                            let region = MKCoordinateRegion(center: spot, span: span)
                            flight.fly(to: .region(region), view: CameraView(region: region),
                                       from: CameraView(region: MKCoordinateRegion(center: center, span: span)),
                                       reduceMotion: reduceMotion,
                                       continues: { position.positionedByUser == false }) { position = $0 }
                        })
                .overlay { pin }
            }
            .navigationTitle("Choose on map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button { onUse(spot) } label: { Text("Use this place").frame(maxWidth: .infinity) }
                    .actionButton(.primary)
                    .disabled(moving)
                    .ikutBottomBar()
            }
            .onAppear { namer.start(center) }
        }
    }

    /// The fixed pin, with its label above; the pin's tip sits on the centre of the map.
    private var pin: some View {
        Image(systemName: "mappin")
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(.red)
            .accessibilityHidden(true)
            .offset(y: -17)
            .overlay(alignment: .top) {
                Text(Self.label(spot, along: along))
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .fixedSize()
                    .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -52)
                    .accessibilityIdentifier("mapPick.label")
            }
            .allowsHitTesting(false)
    }
}
