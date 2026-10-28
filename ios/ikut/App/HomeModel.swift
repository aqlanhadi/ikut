import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Home's flows and what they remember (D63 B4), out of `TripsHomeView` so they can be tested without a screen: the
/// trips list, the past trip picked on the map and Back, Where to? / New trip and Close, Join and Close, a link
/// arriving mid-join, the hand-off to the lobby once a trip is made or joined, and where the camera was before each so
/// that Close and Back return it. `HomeView` makes one and resets it whenever Home comes back from a trip.
///
/// The model changes state only. The camera is moved by the view: a step that ends a flow returns where the camera
/// should go (`CameraReturn`), and the view runs it through `HomeCamera`'s pacing. Small view state (rename text,
/// confirm dialogs, the sheet's measured height) stays in the views.
@MainActor @Observable
final class HomeModel {
    // MARK: The list

    /// Trips this phone has been in, newest first (`PastTrips`).
    var past: [PastTrips.Entry]
    /// Routes of the newest ended trips, drawn on the map (newest first).
    var routes: [PastTripRoute]
    /// The status line of each trip in Now (one read when the list appears), by trip id.
    var nowStatus: [String: String] = [:]
    /// The trips in Now that Home read as started: a tap opens them on the driving map.
    var nowStarted: Set<String> = []
    /// Where the list puts the camera when Home comes on screen: the cached past routes, or where you are.
    var listCamera: MapCameraPosition
    /// Where the camera last went to show you (`HomeCamera`); nil before the first fix.
    var here: CLLocationCoordinate2D?
    /// The one sheet (`TripSheet`), the screen's: Home sizes it only while Home is on screen.
    var sheet: TripSheet
    /// The sheet is at its tall detent (the detent selection reads and writes it). Every flow starts and ends short.
    var expanded: Bool {
        get { sheet.size == .home(tall: true) }
        set { sheet.resize(to: .home(tall: newValue)) }
    }
    /// Screenshot demo: shows what it was given and reads nothing from the phone or the server.
    var isDemo = false
    /// Reduce Motion is on (set by the view): the sheet's changes crossfade instead of moving.
    var reduceMotion = false

    // MARK: Requests from HomeView

    /// New trip was tapped and its gates (name, location) are through: the sheet becomes Where to? over this map.
    /// Cleared again when the flow closes or the trip is made.
    var creating = false
    /// Join was opened and its gates are through: the sheet becomes the join steps. Cleared when the sheet closes or the
    /// trip is joined.
    var joining: JoinStart?

    // MARK: The flows

    /// The past trip picked on the map, whose recap fills the sheet.
    var picked: PickedTrip?
    /// Its route when it is older than the 12 drawn and the recap hasn't loaded yet.
    var fetchedRoute: PastTripRoute?
    /// The create flow (Where to?, then New trip) over this map; nil while the sheet shows its list.
    var flow: NewTripFlow?
    /// The join steps over this map; nil while the sheet shows its list.
    var joinFlow: JoinStepper?
    /// The trip was made and its lobby is being opened: the flow stays until Home's sheet is covered, so the list never flashes.
    var finishingCreate = false
    /// The same for a trip that was joined.
    var finishingJoin = false

    /// Where the camera was before picking, creating and joining, for Back and Close.
    private(set) var cameraBeforePick: MapCameraPosition?
    private(set) var cameraBeforeCreate: MapCameraPosition?
    private(set) var cameraBeforeJoin: MapCameraPosition?

    init(past: [PastTrips.Entry] = [], routes: [PastTripRoute] = [],
         listCamera: MapCameraPosition = .region(HomeCamera.fallback), sheet: TripSheet = TripSheet()) {
        self.sheet = sheet
        self.past = past
        self.routes = routes
        self.listCamera = listCamera
    }

    /// Home as it opens: on the cached past routes when there are any, else a fixed region, never MapKit's
    /// follow-the-user (`HomeCamera`). The phone's last known spot is read once the view is on screen.
    static func launching(sheet: TripSheet = TripSheet()) -> HomeModel {
        let cache = PastTripsMapService.cachedRoutes()
        let cached = PastTripsMapLogic.tripsToDraw(PastTrips.all()).compactMap { cache[$0.id] }
        let insets = TripsHomeView.obscured(mapHeight: 0)
        let region = PastTripsMapLogic.region(fitting: cached, bottomObscured: insets.bottom, topObscured: insets.top)
        return HomeModel(routes: region != nil ? cached : [], listCamera: HomeCamera.launch(cachedRoutes: region), sheet: sheet)
    }

    /// What the sheet's content changing runs on: the camera's motion, or a short crossfade with Reduce Motion.
    var motion: Animation? { HomeSheet.motion(reduceMotion: reduceMotion) }

    var mode: HomeSheet.Mode { HomeSheet.mode(flow: flow, leftTripPicked: picked?.isLeft == true, joining: joinFlow != nil) }

    // MARK: The list

    func reloadPast(defaults: UserDefaults = .standard) { past = PastTrips.all(defaults: defaults) }

    /// Reads each trip in Now once. A trip that ended while this phone wasn't in it, or that this phone left or was
    /// removed from, is remembered as past and moves to Past trips; the others get their status line and whether they
    /// started.
    func readNow(signedIn: Bool, load: (String) async -> HomeNow.Read = { await HomeNow.load(tripId: $0) },
                 defaults: UserDefaults = .standard) async {
        for entry in HomeNow.split(past).now {
            let read = await load(entry.id)
            if Task.isCancelled { return }
            if let moved = HomeNow.movesToPast(read, signedIn: signedIn) {
                PastTrips.record(tripId: entry.id, name: read.name ?? entry.name,
                                 destination: read.destination ?? entry.destination, endedAt: moved,
                                 left: HomeNow.wasLeft(read), defaults: defaults)
                reloadPast(defaults: defaults)
            } else {
                nowStatus[entry.id] = read.line
                if read.started { nowStarted.insert(entry.id) } else { nowStarted.remove(entry.id) }
            }
        }
    }

    /// What tapping a trip in the list does.
    enum Opening: Equatable {
        /// An ended trip is picked on this map.
        case pick(PastTrips.Entry)
        /// One still running opens on the same map: its lobby, or driving once Home has read that it started.
        case trip(PastTrips.Entry, started: Bool)
    }

    func opening(_ entry: PastTrips.Entry) -> Opening {
        entry.endedAt == nil ? .trip(entry, started: nowStarted.contains(entry.id)) : .pick(entry)
    }

    // MARK: Where the camera goes back to

    /// Close or Back to trips: the view around you when the list has no routes and the camera showed you, else the
    /// camera saved before the flow (`HomeCamera.back`).
    enum CameraReturn: Equatable {
        case here
        case saved(MapCameraPosition)
        /// Nothing was saved: the camera stays where it is.
        case stay
    }

    private func returning(to saved: MapCameraPosition?, camera: MapCameraPosition) -> CameraReturn {
        switch HomeCamera.back(hasRoutes: !routes.isEmpty, hereKnown: here != nil, positionedByUser: camera.positionedByUser) {
        case .here: return .here
        case .saved: return saved.map { .saved($0) } ?? .stay
        }
    }

    // MARK: Picked trip

    /// An ended trip is picked: the sheet shows its recap, short. `recap` is a demo's ready-made one.
    func pick(_ entry: PastTrips.Entry, camera: MapCameraPosition, recap: RecapModel? = nil) {
        cameraBeforePick = camera
        fetchedRoute = nil
        withAnimation(motion) {
            expanded = false
            picked = PickedTrip(entry: entry, model: recap)
        }
    }

    /// The route to draw for the picked trip (`PickedTripLogic.route`).
    var pickedRoute: PastTripRoute? {
        picked.flatMap { PickedTripLogic.route(for: $0.entry, snapshot: $0.model.snapshot, drawn: routes, fetched: fetchedRoute) }
    }

    /// Back to the list; nil when nothing was picked.
    @discardableResult
    func closePicked(camera: MapCameraPosition) -> CameraReturn? {
        guard picked != nil else { return nil }
        withAnimation(motion) {
            picked = nil
            expanded = false
        }
        fetchedRoute = nil
        let back = returning(to: cameraBeforePick, camera: camera)
        cameraBeforePick = nil
        return back
    }

    // MARK: Where to? and New trip

    /// New trip's gates are through: Where to? takes over the sheet and the map. A trip picked on the map is put away
    /// first, and `goBack` runs its camera return.
    func beginCreate(camera: MapCameraPosition, flow newFlow: @autoclosure () -> NewTripFlow = NewTripFlow(),
                     goBack: (CameraReturn) -> Void) {
        guard flow == nil else { return }
        cameraBeforeCreate = camera
        if let back = closePicked(camera: camera) { goBack(back) }
        withAnimation(motion) {
            expanded = false
            flow = newFlow()
        }
    }

    /// Back to Home's list. Nothing was written.
    func closeCreate(camera: MapCameraPosition) -> CameraReturn {
        flow?.cancel()
        withAnimation(motion) {
            flow = nil
            expanded = false
        }
        creating = false
        let back = returning(to: cameraBeforeCreate, camera: camera)
        cameraBeforeCreate = nil
        return back
    }

    /// Create trip was tapped on New trip: writes the trip with `create` and returns its id, with the flow kept until
    /// the lobby covers Home's sheet (`coverSheet`). Without a signed-in person nothing is written.
    func createTrip(userID: String?, displayName: String?, covered: Bool,
                    using create: (TripOrganizer, String, DestinationResult, BuiltRoute) async throws -> String) async -> String? {
        guard let flow else { return nil }
        guard let userID else {
            flow.createError = "Couldn’t sign you in. Check your signal and try again."
            return nil
        }
        let organizer = TripOrganizer(id: userID, displayName: displayName ?? "Organizer")
        let id = await flow.create { name, place, route in try await create(organizer, name, place, route) }
        guard let id else { return nil }
        flow.search.errorMessage = nil
        finishingCreate = true
        creating = false
        // Demo and tests have no parent to cover the sheet.
        if !covered, isDemo { finishingCreate = false; self.flow = nil }
        return id
    }

    // MARK: Join

    /// Join's gates are through (or a link brought a code): the sheet becomes the join steps. A link arriving mid-join
    /// does not swap the steps from under the person (`JoinStepper.shouldReplace`); a link during Where to? or a picked
    /// trip leaves them, and Close then returns the camera to before whichever was first.
    func beginJoin(_ start: JoinStart, camera: MapCameraPosition, displayName: String?, signedIn: Bool,
                   location: LocationAccess.Status, api: any JoinAPI = LiveJoinAPI()) {
        guard JoinStepper.shouldReplace(joinFlow) else { return }
        if joinFlow == nil {
            cameraBeforeJoin = cameraBeforeCreate ?? cameraBeforePick ?? camera
        }
        flow?.cancel()
        if picked != nil { picked = nil }
        creating = false
        let hasName = signedIn && !(displayName ?? "").isEmpty
        let stepper = JoinStepper.begin(start, displayName: displayName ?? "",
                                        plan: JoinSteps.plan(hasName: hasName, location: location), api: api)
        withAnimation(motion) {
            expanded = false
            flow = nil
            joinFlow = stepper
        }
        cameraBeforeCreate = nil
        cameraBeforePick = nil
    }

    /// Back to Home's list. Nothing was written.
    func closeJoin(camera: MapCameraPosition) -> CameraReturn {
        withAnimation(motion) {
            joinFlow = nil
            expanded = false
        }
        joining = nil
        let back = returning(to: cameraBeforeJoin, camera: camera)
        cameraBeforeJoin = nil
        return back
    }

    /// The trip was joined and its lobby is opening: the steps stay until the lobby covers the sheet.
    func joined(covered: Bool) {
        finishingJoin = true
        joining = nil
        // Demo and tests have no parent to cover the sheet.
        if !covered, isDemo { finishingJoin = false; joinFlow = nil }
    }

    // MARK: Hand-off

    /// Home's sheet is covered (the lobby took over): a flow that was finishing is let go, so Home never flashes its list.
    func coverSheet() {
        if finishingCreate {
            finishingCreate = false
            flow = nil
            cameraBeforeCreate = nil
        }
        if finishingJoin {
            finishingJoin = false
            joinFlow = nil
            cameraBeforeJoin = nil
        }
    }
}
