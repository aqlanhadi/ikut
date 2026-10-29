import SwiftUI

/// Root navigation: the welcome screen until "Get started", then the app's one map (`TripScreenHost`, D54) with Home
/// (`TripsHomeView`) or a trip (`LobbyView`: its lobby or the driving map) over it. Opening a trip and leaving it are a
/// camera move and a sheet change on that map; Join is Home's sheet too (its steps, D58), and the recap is pushed over it.
/// Signed-out visitors give a name (sheet) before Create or Join.
/// Gets location access good enough for a trip before opening Create Trip, Join or a trip.
struct HomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Route: Hashable {
        case create
        case join(code: String?)
        /// A trip opened on the map (never pushed): its lobby, or driving when it has started.
        case trip(tripId: String, started: Bool)
        case recap(tripId: String)
    }

    /// A code from an opened link, waiting for the Join screen (set by `IkutApp`).
    @Binding var pendingJoinCode: String?

    @State private var path: [Route] = []
    /// The trip whose recap was pushed. The lobby reports the end again whenever it reappears (its `onChange` is
    /// `initial`), which is what popping the recap does, so the path alone can't tell a new end from that echo (D92).
    @State private var recapPushedFor: String?
    /// The one map's mode, camera and open trip with its session and models, shared by Home and the trip (D54). The
    /// trip's objects are made and dropped by it (`open`, `exit`), not here.
    @State private var stage: TripScreenModel
    /// Where the app opens has been decided (`LaunchRoute`): until then nothing is drawn, so Home never flashes before
    /// the trip this phone is in.
    @State private var launched = false
    /// Home's flows (`HomeModel`): once New trip's or Join's gates are through, `home.creating` / `home.joining` turn
    /// Home's sheet into Where to? or the join steps over its own map, with the code from a link or QR filled in (D58;
    /// no pushed screen). Made afresh each time Home comes back from a trip.
    @State private var home: HomeModel
    @AppStorage("ikut.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showDenied = false
    @State private var showName = false
    /// Where to go once the name step finishes.
    @State private var afterName: Route?
    /// A route is being opened (a permission prompt may be up), so Home's sheet stays away.
    @State private var opening = false
    /// The route to open once the name sheet has gone (its dismissal is the signal, so a permission prompt can't collide).
    @State private var routeAfterName: Route?

    /// The one sheet is presented over Home, so it steps aside for everything that is pushed or presented from here,
    /// and comes back when they are gone (`TripSheetCover.home`).
    private var homeCovers: Set<TripSheetCover> {
        var covers = Set<TripSheetCover>()
        if !path.isEmpty { covers.insert(.pushed) }
        if showName || afterName != nil { covers.insert(.nameSheet) }
        if showDenied { covers.insert(.locationSheet) }
        if opening { covers.insert(.opening) }
        return covers
    }

    init(pendingJoinCode: Binding<String?> = .constant(nil)) {
        _pendingJoinCode = pendingJoinCode
        let stage = TripScreenModel(mode: .home)
        _stage = State(initialValue: stage)
        _home = State(initialValue: HomeModel.launching(sheet: stage.sheet))
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hasSeenWelcome {
                    if launched {
                        TripScreenHost(stage: stage) { layer }
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .onAppear(perform: startLaunch)
                    }
                } else {
                    WelcomeView(
                        onGetStarted: { hasSeenWelcome = true },
                        onJoin: {
                            hasSeenWelcome = true
                            begin(.join(code: nil))
                        }
                    )
                }
            }
            // Debug builds say which backend they talk to (emulator or production), on Welcome and on Home's map.
            .overlay(alignment: .topTrailing) {
                #if DEBUG
                Text(Backend.current.label)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.m)
                    .accessibilityHidden(true)
                #endif
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Trips") // only the pushed pages' Back label; this page has no bar
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .create:
                    // Never pushed: creating a trip happens in Home's sheet (see `home.creating`).
                    EmptyView()
                case .join:
                    // Never pushed: joining happens in Home's sheet (see `home.joining`).
                    EmptyView()
                case .trip:
                    // Never pushed: a trip opens on the one map (see `openTrip`).
                    EmptyView()
                case .recap(let tripId):
                    RecapView(tripId: tripId, onDone: closeRecap)
                }
            }
            .sheet(isPresented: Binding(get: { BottomSheet.presents(wanted: showName, sheetUp: stage.sheet.up) },
                                        set: { showName = $0 }),
                   onDismiss: {
                // Home's sheet is held back until the route is open; a swipe-down instead of Continue drops the trip.
                if let route = routeAfterName {
                    routeAfterName = nil
                    Task { await open(route) }
                } else {
                    afterName = nil
                }
            }) {
                NameEntryView {
                    routeAfterName = afterName
                    afterName = nil
                    // Opening from here on, so Home's sheet stays away until the route is pushed.
                    opening = routeAfterName != nil
                    showName = false
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: Binding(get: { BottomSheet.presents(wanted: showDenied, sheetUp: stage.sheet.up) },
                                        set: { showDenied = $0 })) {
                LocationDeniedView { location.openSettings() }
            }
            .onChange(of: auth.state) { old, new in
                // The server dropped this user mid-trip (AuthModel signed them out): back to Home, where the
                // next Start or Join asks for a name again.
                if old == .signedIn, new == .signedOut {
                    path = []
                    if stage.tripId != nil { closeTrip() }
                }
            }
            .onChange(of: path) { old, new in
                // Back and the edge swipe pop the recap without Done: the ended trip closes with the pop, so its lobby or
                // map never shows again (D92). Done clears the path and closes the trip together, so this doesn't repeat.
                let recapShown: ([Route]) -> Bool = { $0.contains { if case .recap = $0 { true } else { false } } }
                if TripScreenLogic.closesTripAfterRecapLeft(recapWasPushed: recapShown(old), recapIsPushed: recapShown(new),
                                                            openTripId: stage.tripId) {
                    exitTrip()
                }
            }
            .onChange(of: pendingJoinCode, initial: true) { handlePendingJoin() }
            .onChange(of: homeCovers, initial: true) { _, covers in stage.sheet.cover(covers, among: TripSheetCover.home) }
        }
    }

    /// A join link: Join, after the name when signed out. It waits while launch decides, and never pulls someone out
    /// of a trip they're in.
    private func handlePendingJoin() {
        // Launch decides first: a trip this phone is in comes before the link.
        guard launched || !hasSeenWelcome, let code = pendingJoinCode else { return }
        pendingJoinCode = nil
        // Don't pull someone out of a trip they're already in.
        if auth.state == .signedIn, stage.tripId != nil { return }
        // The join sheet asks for a name and location itself when needed (D58).
        begin(.join(code: code))
    }

    /// Decides where the app opens (#401): straight into a trip this phone is still in, the lobby before Start and the
    /// driving map after, with nothing else drawn first; otherwise Home (or Join for a link). Reads only when signed in
    /// with a trip in Now.
    private func startLaunch() {
        let signedIn = auth.state == .signedIn
        let entries = PastTrips.all()
        guard LaunchRoute.needsReads(signedIn: signedIn, entries: entries) else {
            finishLaunch(.home)
            return
        }
        Task {
            finishLaunch(await LaunchRoute.load(signedIn: signedIn, pendingJoin: pendingJoinCode, entries: entries))
        }
    }

    private func finishLaunch(_ route: LaunchRoute) {
        guard !launched else { return }
        // Signed out meanwhile: no trip to open.
        guard auth.state == .signedIn, case .trip(let tripId, let started) = route else {
            launched = true
            handlePendingJoin()
            return
        }
        // Never pulled out of a trip by a link (as mid-trip).
        pendingJoinCode = nil
        switch LocationAccess.nextAction(status: location.status, accuracy: location.accuracy, context: .joiningTrip) {
        case .ready, .showAlwaysExplainer:
            // The map's first frame is the trip's: no flight, no Home before it.
            stage.open(tripId: tripId, started: started)
            launched = true
        default:
            // Location needs asking first, as for any trip opened from Home: over Home, then the trip.
            launched = true
            begin(.trip(tripId: tripId, started: started))
        }
    }

    /// Home, or the trip open on the map: one layer at a time over the one map, each publishing what the map draws and
    /// the sheet's content (`TripMapSpec`, `TripSheetSpec`).
    @ViewBuilder private var layer: some View {
        if let trip = stage.trip {
            LobbyView(trip: trip, onExit: exitTrip, onEnded: { ended in
                // The recap is its own screen, pushed over the trip; its Done returns to Home's list (`closeRecap`).
                // The lobby and the driving map both report the end, and may again when the recap is closed: once.
                guard ended == stage.tripId, recapPushedFor != ended, !path.contains(.recap(tripId: ended)) else { return }
                recapPushedFor = ended
                path = [.recap(tripId: ended)]
            })
            // A different trip is a new session, model and planner.
            .id(trip.id)
        } else {
            TripsHomeView(
                model: home,
                onNewTrip: { begin(.create) },
                onJoin: { begin(.join(code: nil)) },
                // Only a trip that hasn't ended reaches here: an ended one is picked on Home's map.
                onOpenTrip: { entry, started in begin(.trip(tripId: entry.id, started: started)) },
                // The organiser tracks their own car; a joiner when they share theirs.
                onCreated: { tripId in openTrip(tripId, started: false, tracks: true) },
                onJoined: { tripId, tracks in openTrip(tripId, started: false, tracks: tracks) }
            )
        }
    }

    /// The trip takes over the one map: Home's sheet becomes the lobby's (or the convoy's) at its entry size, and the
    /// camera's target changes, in one transaction (`TripScreenModel.go`).
    /// `tracks`: this phone will track the trip (made or joined sharing), so Always is asked before the lobby comes up
    /// when it has only When In Use. A trip reopened from Home or at launch is not known to track yet: it asks once
    /// tracking starts, over the lobby.
    private func openTrip(_ tripId: String, started: Bool, tracks: Bool = false) {
        home.creating = false
        home.joining = nil
        let asks = TripSessionLogic.asksAlwaysOnOpen(willTrack: tracks, action: location.backgroundAction)
        withAnimation(Motion.sheet(reduceMotion: reduceMotion)) {
            stage.open(tripId: tripId, started: started, asksAlways: asks)
        }
    }

    /// Leave, End or Back to trips: the trip's sheet becomes Home's list and the camera flies back to it.
    private func exitTrip() {
        withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { closeTrip() }
    }

    /// The map back to Home; the trip's session stops and goes with its objects (`TripScreenModel.exit`).
    private func closeTrip() {
        recapPushedFor = nil
        stage.exit()
        home = HomeModel.launching(sheet: stage.sheet)
        enterHome()
    }

    /// Home's list camera, flown in the same transaction as the switch back to Home (D63 C4) instead of when its layer
    /// appears an update later: the routes, where you are and the map's height are all known here.
    private func enterHome() {
        if home.here == nil, home.routes.isEmpty { home.here = TripsHomeView.lastKnownLocation() }
        if let camera = home.entryCamera(mapHeight: stage.space.frame.height) {
            stage.move(to: camera, animated: TripScreenLogic.animatesEntry(mapHasCamera: stage.hasCamera), reduceMotion: reduceMotion)
        }
        stage.enteredWithCamera()
    }

    /// Done on the recap: back to the one map, which is Home's list again (the ended trip's lobby or map closes in the
    /// same step, so it never shows again under the pop).
    private func closeRecap() {
        path = []
        if stage.tripId != nil { closeTrip() }
    }

    /// Signed in: go straight to the route. Signed out: ask for a name first.
    private func begin(_ route: Route) {
        // Joining asks for the name and the location as its own first steps in Home's sheet (D58). Only a denied or
        // approximate location still goes through the settings prompt first.
        if case .join(let code) = route, JoinSteps.sheetHostsLocation(status: location.status, accuracy: location.accuracy) {
            hasSeenWelcome = true
            home.creating = false
            home.joining = JoinStart(code: code)
            return
        }
        if auth.state == .signedIn {
            Task { await open(route) }
        } else {
            afterName = route
            showName = true
        }
    }

    private func open(_ route: Route, replacing: Bool = false) async {
        // A join link (or code) opened during Where to? or New trip leaves that flow: Home is not left on it afterwards.
        if case .join = route { home.creating = false }
        opening = true
        defer { opening = false }
        while true {
            switch LocationAccess.nextAction(status: location.status, accuracy: location.accuracy, context: .joiningTrip) {
            case .requestWhenInUse:
                if await location.requestWhenInUse() == .notDetermined { return }
            case .requestFullAccuracy:
                if await location.requestFullAccuracy() == .reduced {
                    showDenied = true
                    return
                }
            case .showSettingsPrompt:
                showDenied = true
                return
            case .ready, .showAlwaysExplainer:
                if case .create = route { home.creating = true; return }
                if case .join(let code) = route {
                    // A link on a fresh install opens Home first: there is no Welcome to push Join over any more.
                    hasSeenWelcome = true
                    home.joining = JoinStart(code: code)
                    return
                }
                if case .trip(let tripId, let started) = route { openTrip(tripId, started: started); return }
                if replacing { path = [route] } else { path.append(route) }
                return
            }
        }
    }
}

#Preview {
    Backend.configure()
    return HomeView()
        .environment(AuthModel())
        .environment(LocationPermission())
}
