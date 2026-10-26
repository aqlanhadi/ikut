import MapKit
import SwiftUI

/// The trip screen's two modes over its one map (D53): the lobby (the whole route, the lobby's sheet) and driving
/// (following your car, the pill, the banners and the convoy sheet). Start trip and Show map are a camera move and a
/// sheet change, not a new screen.
enum TripScreenMode: Equatable {
    case lobby, driving
}

/// What decides the trip screen's mode, which layer draws, where the camera goes and the sheet's sizes; pure, so it
/// can be tested.
enum TripScreenLogic {
    enum Event: Equatable {
        /// The organiser's Start trip.
        case start
        /// A trip already under way: Show map.
        case showMap
        /// The driving screen's Back (until the sheet is pulled up for the lobby instead, piece 3).
        case back
    }

    static func mode(after event: Event, from mode: TripScreenMode) -> TripScreenMode {
        switch event {
        case .start, .showMap: .driving
        case .back: .lobby
        }
    }

    /// The layer on screen in `mode`: it alone draws its chrome, publishes what the map draws (`TripMapSpec`) and fills
    /// the sheet (`TripSheetSpec`).
    enum Layer: Equatable { case lobby, driving }

    static func layer(in mode: TripScreenMode) -> Layer {
        switch mode {
        case .lobby: .lobby
        case .driving: .driving
        }
    }

    /// Where the camera goes as a mode comes on screen.
    enum EntryCamera: Equatable {
        /// The whole route with its pins, above the lobby's sheet (`LobbyMapTarget.wholeTrip`).
        case wholeTrip
        /// Your car, in the driving map's follow camera (`MapMode.follow`, `MapCameraLogic`).
        case follow
    }

    static func entryCamera(_ mode: TripScreenMode) -> EntryCamera {
        switch mode {
        case .lobby: .wholeTrip
        case .driving: .follow
        }
    }

    /// The driving map's camera mode on entry.
    static var drivingEntryMode: MapMode { .follow }

    /// Whether the entry move animates: a switch flies the camera from where the other mode left it; the screen's
    /// first frame just places it.
    static func animatesEntry(mapHasCamera: Bool) -> Bool { mapHasCamera }

    /// The one sheet's sizes in each mode: the lobby's medium and tall, or the convoy panel's short and tall.
    enum Sheet: Equatable {
        case lobby(compact: CGFloat)
        case driving(PanelSheet.Heights)

        var mode: TripScreenMode {
            switch self {
            case .lobby: .lobby
            case .driving: .driving
            }
        }

        var detents: Set<PresentationDetent> {
            switch self {
            case .lobby(let compact): LobbySheet.detents(compact: compact)
            case .driving(let heights): PanelSheet.detents(in: heights)
            }
        }

        /// The map stays touchable with the sheet up to this detent: the lobby's medium, the convoy's tall.
        var touchableUpThrough: PresentationDetent {
            switch self {
            case .lobby(let compact): LobbySheet.medium(compact)
            case .driving(let heights): .height(heights.tall)
            }
        }
    }
}

/// What a layer asks the one map to draw: the content, and the bottom safe area the logo and Legal ride above.
struct TripMapSpec {
    var input = TripMapInput()
    /// The hazard pinging and the candidate taps; the host adds the heading and width it measures itself.
    var style = TripMapStyle()
    var bottomPadding: CGFloat = 0
    var hidesControls = false
}

/// The one sheet's content and whether it is up now (the cover rules: `LobbySheet`, `PanelSheet`).
struct TripSheetSpec {
    var presented: Bool
    var onDismiss: () -> Void
    var content: AnyView
}

struct TripMapSpecKey: PreferenceKey {
    static var defaultValue: TripMapSpec? { nil }
    static func reduce(value: inout TripMapSpec?, nextValue: () -> TripMapSpec?) { value = nextValue() ?? value }
}

struct TripSheetSpecKey: PreferenceKey {
    static var defaultValue: TripSheetSpec? { nil }
    static func reduce(value: inout TripSheetSpec?, nextValue: () -> TripSheetSpec?) { value = nextValue() ?? value }
}

/// The map's own camera, as it last reported it once a move ended.
struct TripCameraReading: Equatable {
    var distance: Double
    var pitch: Double
    var latitudeDelta: Double
}

/// The trip screen's shared state: the mode, the one camera, and what the map reports about itself. The host owns it;
/// the layers read it from the environment and move the camera with their own logic (`LobbyMapLogic`,
/// `MapCameraRoom`).
@Observable @MainActor
final class TripMapStage {
    var mode: TripScreenMode
    var camera: MapCameraPosition = .automatic
    var heading = 0.0
    var reading: TripCameraReading?
    /// The map's frame on screen (it runs under the status bar and the home indicator).
    var mapFrame: CGRect = .zero

    init(mode: TripScreenMode = .lobby) { self.mode = mode }

    /// Something has placed the camera, so the next entry move is a flight from it.
    var hasCamera: Bool { camera != .automatic }
}

/// The trip screen: one full-screen map with one camera, the layer for the mode over it, and one sheet whose content
/// and detents change with the mode (never dismissed and presented again for a switch).
struct TripScreenHost<Content: View>: View {
    @State private var stage: TripMapStage
    private let content: Content

    init(mode: TripScreenMode = .lobby, @ViewBuilder content: () -> Content) {
        _stage = State(initialValue: TripMapStage(mode: mode))
        self.content = content()
    }

    var body: some View {
        content
            .backgroundPreferenceValue(TripMapSpecKey.self) { spec in map(spec ?? TripMapSpec()) }
            .overlayPreferenceValue(TripSheetSpecKey.self) { spec in
                Color.clear
                    .allowsHitTesting(false)
                    .sheet(isPresented: Binding(get: { spec?.presented ?? false }, set: { _ in }),
                           onDismiss: { spec?.onDismiss() }) {
                        spec?.content
                    }
            }
            .environment(stage)
    }

    private func map(_ spec: TripMapSpec) -> some View {
        @Bindable var stage = stage
        var style = spec.style
        style.cameraHeading = stage.heading
        style.containerWidth = stage.mapFrame.maxX
        return Map(position: $stage.camera) {
            TripMapContent(input: spec.input, style: style)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(spec.hidesControls ? .hidden : .automatic)
        // MapKit fits and centres inside the safe area: the logo and Legal ride above what the layer keeps clear.
        .safeAreaPadding(.bottom, spec.bottomPadding)
        .onMapCameraChange { context in
            stage.heading = context.camera.heading
            stage.reading = TripCameraReading(
                distance: context.camera.distance, pitch: context.camera.pitch,
                latitudeDelta: context.region.span.latitudeDelta)
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stage.mapFrame = $0 }
    }
}
