import MapKit
import SwiftUI

/// The app's modes over its one map (D53, D54): Home (its list, a picked past trip, Where to? and New trip), the lobby
/// (the whole route, the lobby's sheet) and driving (following your car, the pill, the banners and the convoy sheet).
/// Create trip, a trip in Now, Start trip and Show map are a camera move and a sheet change, not a new screen; Leave,
/// End and Back to trips return to Home's list the same way. There is no way back to the lobby's mode: while driving,
/// the lobby's rows continue below the convoy when its sheet is pulled up to its tallest height (canvas row L, #424).
enum TripScreenMode: Equatable {
    case home, lobby, driving
}

/// What decides the trip screen's mode, which layer draws, where the camera goes and the sheet's sizes; pure, so it
/// can be tested.
enum TripScreenLogic {
    enum Event: Equatable {
        /// The organiser's Start trip.
        case start
        /// A trip already under way: Show map.
        case showMap
        /// A trip opened from Home (Create trip, a row in Now, Join, or the app opening into it): its lobby, or driving
        /// when it has started.
        case open(started: Bool)
        /// Leave trip, End trip (after the recap), Back to trips: Home's list.
        case exit
    }

    static func mode(after event: Event, from mode: TripScreenMode) -> TripScreenMode {
        switch event {
        // Home has no trip open: nothing to start or show.
        case .start, .showMap: mode == .home ? .home : .driving
        case .open(let started): started ? .driving : .lobby
        case .exit: .home
        }
    }

    /// Whether the lobby's own listeners (the trip, cars, members and stops: `LobbyModel`) run: while the trip screen
    /// is on screen, in the lobby's mode, or while driving with the convoy sheet pulled up, where the lobby continues
    /// below the convoy. Short or tall, the convoy has its own listeners and the lobby's rest, so the trip is read by
    /// one listener set at a time; what the lobby last read stays on screen until it listens again.
    static func lobbyListens(onScreen: Bool, mode: TripScreenMode, pulledUp: Bool) -> Bool {
        guard onScreen else { return false }
        switch mode {
        case .home: return false
        case .lobby: return true
        case .driving: return pulledUp
        }
    }

    /// The layer on screen in `mode`: it alone draws its chrome, publishes what the map draws (`TripMapSpec`) and fills
    /// the sheet (`TripSheetSpec`).
    enum Layer: Equatable { case home, lobby, driving }

    static func layer(in mode: TripScreenMode) -> Layer {
        switch mode {
        case .home: .home
        case .lobby: .lobby
        case .driving: .driving
        }
    }

    /// Where the camera goes as a mode comes on screen.
    enum EntryCamera: Equatable {
        /// Home's own: every past route drawn above its short sheet, or where you are when there are none.
        case homeList
        /// The whole route with its pins, above the lobby's sheet (`LobbyMapTarget.wholeTrip`).
        case wholeTrip
        /// Your car, in the driving map's follow camera (`MapMode.follow`, `MapCameraLogic`).
        case follow
    }

    static func entryCamera(_ mode: TripScreenMode) -> EntryCamera {
        switch mode {
        case .home: .homeList
        case .lobby: .wholeTrip
        case .driving: .follow
        }
    }

    /// The driving map's camera mode on entry.
    static var drivingEntryMode: MapMode { .follow }

    /// Whether the entry move animates: a switch flies the camera from where the other mode left it; the screen's
    /// first frame just places it.
    static func animatesEntry(mapHasCamera: Bool) -> Bool { mapHasCamera }

    /// The one sheet's sizes in each mode: Home's short (the list's, or Where to?'s and New trip's own) and tall, the
    /// lobby's medium and tall, or the convoy panel's short and tall.
    enum Sheet: Equatable {
        case home(HomeSheet.Mode, compact: CGFloat)
        case lobby(compact: CGFloat)
        case driving(PanelSheet.Heights)

        var mode: TripScreenMode {
            switch self {
            case .home: .home
            case .lobby: .lobby
            case .driving: .driving
            }
        }

        var detents: Set<PresentationDetent> {
            switch self {
            case .home(let mode, let compact): HomeSheet.detents(mode, compact: compact)
            case .lobby(let compact): LobbySheet.detents(compact: compact)
            case .driving(let heights): PanelSheet.detents(in: heights)
            }
        }

        /// The map stays touchable (and undimmed) with the sheet up to this detent: the lobby's medium; the convoy's
        /// tallest, so the map, the pill, the banners and the round buttons answer at every height (#402).
        var touchableUpThrough: PresentationDetent {
            switch self {
            case .home(let mode, let compact): HomeSheet.short(HomeSheet.height(mode, compact: compact))
            case .lobby(let compact): LobbySheet.medium(compact)
            case .driving(let heights): .height(heights.full)
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
    /// A tap on the map away from its annotations (Home: back from a picked trip to the list); nil, the map keeps it.
    var onTap: (() -> Void)?
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
    /// Driving: the convoy sheet is pulled up and the lobby continues below the convoy (`PanelSheet.showsContinuation`).
    var pulledUp = false
    /// The trip on screen in the lobby's and driving modes; nil on Home.
    private(set) var tripId: String?
    /// The camera as it moves, frame by frame, outside observation so a glide redraws nothing (Home's settle check).
    let cameraBox = CameraBox()
    /// The camera move in flight, paced by `CameraPace` (D57).
    let flight = CameraFlight()

    init(mode: TripScreenMode = .lobby, tripId: String? = nil) {
        self.mode = mode
        self.tripId = tripId
    }

    /// Home hands the map to a trip: its lobby, or driving when it has started (`TripScreenLogic.Event.open`).
    func open(tripId: String, started: Bool) {
        self.tripId = tripId
        pulledUp = false
        flight.cancel()
        mode = TripScreenLogic.mode(after: .open(started: started), from: mode)
    }

    /// Leave, End or Back to trips: Home's list on the same map.
    func exit() {
        tripId = nil
        pulledUp = false
        flight.cancel()
        mode = TripScreenLogic.mode(after: .exit, from: mode)
    }

    /// Something has placed the camera, so the next entry move is a flight from it.
    var hasCamera: Bool { camera != .automatic }

    /// The camera as the map last drew it, mid-move or at rest; nil before it has drawn.
    var seenView: CameraView? {
        cameraBox.seen.map {
            CameraView(latitude: $0.camera.centerCoordinate.latitude, longitude: $0.camera.centerCoordinate.longitude,
                       latitudeSpan: $0.latitudeDelta)
        }
    }

    /// A paced move to `position`, which shows `view` (`CameraPace`): from wherever the camera is now, taking over a
    /// move in flight, and stopping if the person takes the map.
    func fly(to position: MapCameraPosition, view: CameraView, reduceMotion: Bool) {
        flight.fly(to: position, view: view, from: seenView, reduceMotion: reduceMotion,
                   continues: { [weak self] in self?.camera.positionedByUser == false }) { [weak self] in
            self?.camera = $0
        }
    }

    /// Puts the camera at `position` at once, ending any move in flight.
    func place(_ position: MapCameraPosition) {
        flight.cancel()
        camera = position
    }
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

    /// The app's one host (`HomeView`), whose stage it keeps to open and close trips on it.
    init(stage: TripMapStage, @ViewBuilder content: () -> Content) {
        _stage = State(initialValue: stage)
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
        .onMapCameraChange(frequency: .continuous) { context in
            stage.cameraBox.record(context.camera, latitudeDelta: context.region.span.latitudeDelta)
        }
        .onMapCameraChange { context in
            stage.heading = context.camera.heading
            stage.reading = TripCameraReading(
                distance: context.camera.distance, pitch: context.camera.pitch,
                latitudeDelta: context.region.span.latitudeDelta)
        }
        // Home: a tap away from the picked trip's route goes back to the list. Elsewhere the map keeps its taps.
        .gesture(TapGesture().onEnded { spec.onTap?() }, including: spec.onTap == nil ? .subviews : .all)
        .ignoresSafeArea()
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stage.mapFrame = $0 }
    }
}
