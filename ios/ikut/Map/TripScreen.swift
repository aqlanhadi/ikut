import FirebaseAuth
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

    /// Whether the lobby reads the trip's cars and members (rule #396): while the trip screen is on screen, in the
    /// lobby's mode, or while driving with the convoy sheet pulled up, where the lobby continues below the convoy. Short
    /// or tall, only the convoy reads the cars and the members listener rests; what the lobby last read stays on screen.
    static func lobbyListens(onScreen: Bool, mode: TripScreenMode, pulledUp: Bool) -> Bool {
        guard onScreen else { return false }
        switch mode {
        case .home: return false
        case .lobby: return true
        case .driving: return pulledUp
        }
    }

    /// How much of the join-town work the lobby does (rule #396): in its own mode it works out how each car joins and
    /// looks the towns up; below the pulled-up convoy only how each car joins (its rows show it); otherwise nothing,
    /// even while the convoy's cars listener keeps changing the cars.
    enum JoinWork: Equatable { case none, joins, joinsAndTowns }

    static func joinWork(onScreen: Bool, mode: TripScreenMode, pulledUp: Bool) -> JoinWork {
        guard lobbyListens(onScreen: onScreen, mode: mode, pulledUp: pulledUp) else { return .none }
        return mode == .lobby ? .joinsAndTowns : .joins
    }

    /// What the lobby reads from the session (`TripSession.read`) in `mode`: the cars and members while it listens.
    static func lobbyReads(onScreen: Bool, mode: TripScreenMode, pulledUp: Bool) -> Set<TripRead> {
        lobbyListens(onScreen: onScreen, mode: mode, pulledUp: pulledUp) ? [.cars, .members] : []
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

/// The one sheet's size (D63 C3): Home's short or tall, the lobby's medium or tall, or the convoy's folded, unfolded or
/// pulled up. The heights behind each stay with their mode (`HomeSheet`, `LobbySheet`, `PanelSheet`).
enum TripSheetSize: Equatable {
    case home(tall: Bool)
    case lobby(tall: Bool)
    case driving(PanelSheet.Shown)

    var mode: TripScreenMode {
        switch self {
        case .home: .home
        case .lobby: .lobby
        case .driving: .driving
        }
    }

    /// Where each mode's sheet starts: short, medium, folded (every arrival at the map starts with the list folded).
    static func entry(_ mode: TripScreenMode) -> TripSheetSize {
        switch mode {
        case .home: .home(tall: false)
        case .lobby: .lobby(tall: false)
        case .driving: .driving(.folded)
        }
    }

    /// Home's or the lobby's tall detent; the convoy's is `shown`.
    var isTall: Bool {
        switch self {
        case .home(let tall), .lobby(let tall): tall
        case .driving: false
        }
    }

    /// The convoy sheet's size; folded outside driving.
    var shown: PanelSheet.Shown {
        if case .driving(let shown) = self { return shown }
        return .folded
    }
}

/// Why the one sheet steps aside (D63 C3): one list for every mode, each mode heeding its own (`heeded(in:)`).
enum TripSheetCover: Hashable, CaseIterable {
    /// Home's: a screen pushed over the map (the recap), the name sheet (wanted, or waiting for the name), the location
    /// sheet, or a trip being opened while a permission prompt may be up.
    case pushed, nameSheet, locationSheet, opening
    /// The trip's layer is not on screen (another screen pushed over the trip, or the trip closing).
    case tripOffScreen
    /// What the lobby pushes or presents over the whole screen.
    case changeDestination, suggestStops, alwaysExplainer
    /// The lobby's asks: presented over its sheet in the lobby, from inside the pulled-up convoy sheet while driving.
    case renaming, confirmLeave, confirmEnd
    /// The trip ended: the recap is pushed.
    case tripEnded

    /// Home's reasons, written by its root (`HomeView`).
    static let home: Set<Self> = [.pushed, .nameSheet, .locationSheet, .opening]
    /// The open trip's, written by its layers (`LobbyView`); cleared when a trip opens or closes.
    static let trip: Set<Self> = Set(allCases).subtracting(home)

    /// What the sheet steps aside for in `mode`. Driving keeps it up for rename, Leave and End (they present from inside
    /// the pulled-up sheet); the lobby keeps it up when the trip ends (the lobby going off screen takes it).
    static func heeded(in mode: TripScreenMode) -> Set<Self> {
        switch mode {
        case .home: home
        case .lobby: trip.subtracting([.tripEnded])
        case .driving: trip.subtracting([.renaming, .confirmLeave, .confirmEnd])
        }
    }
}

/// The one sheet (D63 C3): its size, whether it is on screen, and why it steps aside, in one place for Home, the lobby
/// and driving. The mode's switch (`TripScreenModel.go`) sets the size; within a mode its layer resizes it, and a
/// layer on its way out (a detent reported while its content leaves) cannot.
@Observable @MainActor
final class TripSheet {
    private(set) var size: TripSheetSize {
        didSet { if size != oldValue { changes &+= 1 } }
    }
    /// The sheet is on screen (the host's sheet reports its appear and dismiss); what else is presented waits for it to go.
    var up = false
    private(set) var covers: Set<TripSheetCover> = []
    /// How many times the size changed, so a test can tell a hand-over resized the sheet once.
    @ObservationIgnored private(set) var changes = 0

    init(size: TripSheetSize = .home(tall: false)) {
        self.size = size
    }

    /// The sheet is wanted on screen in its mode.
    var presented: Bool { covers.isDisjoint(with: TripSheetCover.heeded(in: size.mode)) }

    /// Any of `kinds` holds the sheet back now, in any mode.
    func covered(by kinds: Set<TripSheetCover>) -> Bool { !covers.isDisjoint(with: kinds) }

    /// Sets which of `kinds` hold the sheet back now; the other reasons stay as they are.
    func cover(_ reasons: Set<TripSheetCover>, among kinds: Set<TripSheetCover>) {
        let next = covers.subtracting(kinds).union(reasons.intersection(kinds))
        if next != covers { covers = next }
    }

    /// A resize within the mode on screen. One for another mode is ignored and returns false.
    @discardableResult
    func resize(to next: TripSheetSize) -> Bool {
        guard next.mode == size.mode else { return false }
        size = next
        return true
    }

    /// The mode's switch: its entry size. Only `TripScreenModel.go` switches.
    fileprivate func enter(_ mode: TripScreenMode) {
        size = .entry(mode)
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

/// The one sheet's content; whether it is up is the screen's (`TripSheet.presented`).
struct TripSheetSpec {
    var onDismiss: () -> Void = {}
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

/// The open trip's objects, made together when a trip opens on the screen and dropped together when it closes
/// (`TripScreenModel.open`, `exit`): nothing else makes them for a live trip.
@MainActor
struct OpenTrip {
    let id: String
    /// The one reader of the trip, and the tracker's owner (`TrackingDuty`): it goes with the trip.
    let session: TripSession
    let lobby: LobbyModel
    let planner: StopPlanner
    /// The driving layer's model: made with the trip, put on screen when driving starts.
    let map: TripMapModel

    /// The app's: a session for the signed-in person, and stop edits saved to the trip.
    static func live(tripId: String) -> OpenTrip {
        let session = TripSession(tripId: tripId, userId: Auth.auth().currentUser?.uid ?? "")
        return OpenTrip(id: tripId, session: session,
                        planner: StopPlanner { plan in try await TripService.saveStops(tripId: tripId, plan: plan) })
    }

    #if DEBUG
    /// The demos': a session that is never started (no reads, no tracking) and a planner that saves nothing.
    static func sample(tripId: String) -> OpenTrip {
        OpenTrip(id: tripId, session: TripSession(tripId: tripId, userId: "u-c1"),
                 planner: StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in }))
    }
    #endif

    init(id: String, session: TripSession, planner: StopPlanner) {
        self.id = id
        self.session = session
        lobby = LobbyModel(session: session)
        self.planner = planner
        map = TripMapModel(session: session)
        map.mode = TripScreenLogic.drivingEntryMode
    }
}

/// The trip screen's one model: the mode, the open trip's objects (`OpenTrip`), the one camera, what the map reports
/// about itself, and Keep screen on. HomeView owns it; the layers read it from the environment and move the camera
/// with their own logic (`LobbyMapLogic`, `MapCameraRoom`).
@Observable @MainActor
final class TripScreenModel {
    /// Home, the lobby or driving; switched only by `go(to:)`, with the sheet's size and the camera's target.
    private(set) var mode: TripScreenMode
    /// The one sheet: its size, whether it is up, and why it steps aside (D63 C3).
    let sheet: TripSheet
    /// Where the camera goes as the mode comes on screen: the layer coming on screen flies it there
    /// (`TripScreenLogic.entryCamera`).
    private(set) var entryCamera: TripScreenLogic.EntryCamera
    var camera: MapCameraPosition = .automatic
    var heading = 0.0
    var reading: TripCameraReading?
    /// The map's frame on screen (it runs under the status bar and the home indicator).
    var mapFrame: CGRect = .zero
    /// Driving: the convoy sheet is pulled up and the lobby continues below the convoy (`PanelSheet.showsContinuation`).
    var pulledUp = false
    /// The trip on screen in the lobby's and driving modes, with its objects; nil on Home.
    private(set) var trip: OpenTrip?
    var tripId: String? { trip?.id }
    @ObservationIgnored private let makeTrip: @MainActor (String) -> OpenTrip
    @ObservationIgnored private let defaults: UserDefaults
    /// Keep screen on: the lobby's switch, and what the driving map holds the screen by (`ScreenAwake`). Read from
    /// the phone's settings here only; on until the person chooses (`ScreenAwake.preference`).
    var keepScreenOn: Bool {
        didSet {
            defaults.set(keepScreenOn, forKey: Self.keepAwakeKey)
            defaults.set(true, forKey: Self.keepAwakeAnsweredKey)
        }
    }
    static let keepAwakeKey = "ikut.map.keepAwake"
    static let keepAwakeAnsweredKey = "ikut.map.keepAwakeAnswered"
    /// The camera as it moves, frame by frame, outside observation so a glide redraws nothing (Home's settle check).
    let cameraBox = CameraBox()
    /// The camera move in flight, paced by `CameraPace` (D57).
    let flight = CameraFlight()
    /// The follow camera's glide to the next fix (D70): a keyframe animation the map runs on `glides` changing, so
    /// MapKit plays it over its whole time (a `withAnimation` move this small it plays as its own short ease).
    private(set) var glides = 0
    @ObservationIgnored private(set) var glideTo: MapCamera?
    @ObservationIgnored private(set) var glideTime: TimeInterval = 0
    @ObservationIgnored private var glideEnds = Date.distantPast
    /// Bumped when the cars' running slides (`MarkerGlide`) must be placed at once: a flight starts, or the map's
    /// scale moved by more than a tenth, so a slide's start in points would no longer be where the car was.
    private(set) var placeSlides = 0
    @ObservationIgnored private var slideScale: Double?

    /// Glides the camera to `camera` linearly over `duration` seconds, from wherever it is drawn now.
    func glide(to camera: MapCamera, duration: TimeInterval) {
        glideTo = camera
        glideTime = duration
        glideEnds = Date().addingTimeInterval(duration)
        glides &+= 1
    }

    var isGliding: Bool { glideEnds > Date() }

    /// Marks the glide ended for a move that isn't a follow step (Fit, a flight, the sheet or a banner): setting the
    /// camera takes over a running keyframe glide by itself, while a second, ending keyframe started in the same
    /// update was measured to swallow that move (D70 `follow-drive-interrupts`).
    func endGlide() {
        glideEnds = .distantPast
    }

    /// The map's scale as it moves (`onMapCameraChange` continuous): places the slides once it moved a tenth.
    func noteScale(_ latitudeDelta: Double) {
        guard let was = slideScale else { slideScale = latitudeDelta; return }
        if MarkerGlide.scaleMoved(from: was, to: latitudeDelta) {
            slideScale = latitudeDelta
            placeSlides &+= 1
        }
    }

    init(mode: TripScreenMode = .lobby, defaults: UserDefaults = .standard,
         makeTrip: @escaping @MainActor (String) -> OpenTrip = { OpenTrip.live(tripId: $0) }) {
        self.mode = mode
        sheet = TripSheet(size: .entry(mode))
        entryCamera = TripScreenLogic.entryCamera(mode)
        self.defaults = defaults
        self.makeTrip = makeTrip
        keepScreenOn = ScreenAwake.preference(
            answered: defaults.bool(forKey: Self.keepAwakeAnsweredKey), stored: defaults.bool(forKey: Self.keepAwakeKey))
    }

    /// Home hands the map to a trip: its lobby, or driving when it has started (`TripScreenLogic.Event.open`). The
    /// trip's objects are made here, once: opening the trip already open keeps them. `asksAlways`: this phone will
    /// track the trip and still has only When In Use (`TripSessionLogic.asksAlwaysOnOpen`), so the Always explainer
    /// comes now, before the lobby: Home's sheet steps aside in this same transaction, and the lobby's comes up once,
    /// after the answer, instead of coming up and stepping aside for the ask when tracking starts.
    func open(tripId: String, started: Bool, asksAlways: Bool = false) {
        let fresh = trip?.id != tripId
        if fresh {
            trip?.session.stop()
            trip = makeTrip(tripId)
            sheet.cover([], among: TripSheetCover.trip)
        }
        if asksAlways, let session = trip?.session, session.consumeAlwaysExplainer(action: .showAlwaysExplainer) {
            session.alwaysExplainerShowing = true
            sheet.cover([.alwaysExplainer], among: [.alwaysExplainer])
        }
        pulledUp = false
        flight.cancel()
        go(to: TripScreenLogic.mode(after: .open(started: started), from: mode), fresh: fresh)
    }

    /// The one switch between Home, the lobby and driving (D63 C3): the mode, the sheet's size and the camera's target
    /// change together, so a caller's one `withAnimation` resizes the sheet once and aims the camera in that same
    /// transaction. The mode already on screen changes nothing, unless a different trip comes (`fresh`).
    func go(to next: TripScreenMode, fresh: Bool = false) {
        guard next != mode || fresh else { return }
        mode = next
        sheet.enter(next)
        entryCamera = TripScreenLogic.entryCamera(next)
    }

    /// Leave, End or Back to trips: Home's list on the same map. The trip's session stops here (tracking and its
    /// listeners), before Home takes the map, and its objects go.
    func exit() {
        trip?.session.stop()
        trip = nil
        sheet.cover([], among: TripSheetCover.trip)
        pulledUp = false
        flight.cancel()
        go(to: TripScreenLogic.mode(after: .exit, from: mode))
    }

    /// The open trip's layer went off screen (a screen pushed over it, or the trip closing): the sheet steps aside. A
    /// layer of a trip no longer open (its write landing after a newer `open`) changes nothing.
    func tripLayer(of session: TripSession, onScreen: Bool) {
        guard trip == nil || trip?.session === session else { return }
        sheet.cover(onScreen ? [] : [.tripOffScreen], among: [.tripOffScreen])
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
        endGlide()
        placeSlides &+= 1
        flight.fly(to: position, view: view, from: seenView, reduceMotion: reduceMotion,
                   continues: { [weak self] in self?.camera.positionedByUser == false }) { [weak self] in
            self?.camera = $0
        }
    }

    /// What the map reports once a move ends. Each is written only when it changed, so a move that ends where it began
    /// redraws nothing that reads them (the driving map's heading and scale).
    func read(heading: Double, reading: TripCameraReading) {
        if self.heading != heading { self.heading = heading }
        if self.reading != reading { self.reading = reading }
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
    @State private var stage: TripScreenModel
    private let content: Content

    init(mode: TripScreenMode = .lobby, makeTrip: (@MainActor (String) -> OpenTrip)? = nil,
         @ViewBuilder content: () -> Content) {
        _stage = State(initialValue: makeTrip.map { TripScreenModel(mode: mode, makeTrip: $0) } ?? TripScreenModel(mode: mode))
        self.content = content()
    }

    /// The app's one host (`HomeView`), whose stage it keeps to open and close trips on it.
    init(stage: TripScreenModel, @ViewBuilder content: () -> Content) {
        _stage = State(initialValue: stage)
        self.content = content()
    }

    var body: some View {
        content
            .backgroundPreferenceValue(TripMapSpecKey.self) { spec in map(spec ?? TripMapSpec()) }
            .overlayPreferenceValue(TripSheetSpecKey.self) { spec in
                Color.clear
                    .allowsHitTesting(false)
                    .sheet(isPresented: Binding(get: { spec != nil && stage.sheet.presented }, set: { _ in }),
                           onDismiss: {
                        stage.sheet.up = false
                        spec?.onDismiss()
                    }) {
                        // One container for every layer's content, so a hand-over swaps what is inside without the
                        // sheet's one "up" going down and up again.
                        ZStack { spec?.content }
                            .onAppear { stage.sheet.up = true }
                            .onDisappear { stage.sheet.up = false }
                    }
            }
            .environment(stage)
    }

    private func map(_ spec: TripMapSpec) -> some View {
        @Bindable var stage = stage
        var style = spec.style
        style.cameraHeading = stage.heading
        style.containerWidth = stage.mapFrame.maxX
        style.placeSlides = stage.placeSlides
        return MapReader { proxy in
            Map(position: $stage.camera) {
                TripMapContent(input: spec.input, style: style.converting { proxy.convert($0.clCoordinate, to: .global) })
            }
            .modifier(TripMapBehaviour(spec: spec, stage: stage))
        }
    }
}

/// The host map's camera, readings and gestures.
private struct TripMapBehaviour: ViewModifier {
    let spec: TripMapSpec
    @Bindable var stage: TripScreenModel

    func body(content: Content) -> some View {
        content
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControlVisibility(spec.hidesControls ? .hidden : .automatic)
            // The follow glide (D70): only the middle and the height move; the rest stays as the camera is.
            .mapCameraKeyframeAnimator(trigger: stage.glides) { [stage] initial in
                let to = stage.glideTo ?? initial
                let time = max(stage.glideTime, 0.01)
                KeyframeTrack(\MapCamera.centerCoordinate) { LinearKeyframe(to.centerCoordinate, duration: time) }
                KeyframeTrack(\MapCamera.distance) { LinearKeyframe(to.distance, duration: time) }
            }
            // MapKit fits and centres inside the safe area: the logo and Legal ride above what the layer keeps clear.
            .safeAreaPadding(.bottom, spec.bottomPadding)
            .onMapCameraChange(frequency: .continuous) { context in
                stage.cameraBox.record(context.camera, latitudeDelta: context.region.span.latitudeDelta)
                stage.noteScale(context.region.span.latitudeDelta)
            }
            .onMapCameraChange { context in
                stage.read(heading: context.camera.heading, reading: TripCameraReading(
                    distance: context.camera.distance, pitch: context.camera.pitch,
                    latitudeDelta: context.region.span.latitudeDelta))
            }
            // Home: a tap away from the picked trip's route goes back to the list. Elsewhere the map keeps its taps.
            .gesture(TapGesture().onEnded { spec.onTap?() }, including: spec.onTap == nil ? .subviews : .all)
            .ignoresSafeArea()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { stage.mapFrame = $0 }
    }
}
