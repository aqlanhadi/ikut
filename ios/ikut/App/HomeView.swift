import SwiftUI

/// Root navigation: the welcome screen until "Get Started", then Home (`TripsHomeView`).
/// Signed-out visitors give a name (sheet) before Create or Join.
/// Gets location access good enough for a trip before opening Create Trip or Join.
struct HomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location

    private enum Route: Hashable {
        case create
        case join(code: String?)
        case lobby(tripId: String)
        case recap(tripId: String)
    }

    /// A code from an opened link, waiting for the Join screen (set by `IkutApp`).
    @Binding var pendingJoinCode: String?

    @State private var path: [Route] = []
    /// New trip's gates are through: Home's sheet becomes Where to? over its own map (no pushed screen).
    @State private var creating = false
    @AppStorage("ikut.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showDenied = false
    @State private var showName = false
    /// Where to go once the name step finishes.
    @State private var afterName: Route?
    /// A route is being opened (a permission prompt may be up), so Home's sheet stays away.
    @State private var opening = false
    /// Home's sheet is on screen (it reports its own appear and dismiss). The name and denied sheets wait for it to go.
    @State private var homeSheetUp = false
    /// The route to open once the name sheet has gone (its dismissal is the signal, so a permission prompt can't collide).
    @State private var routeAfterName: Route?

    /// Home's sheet is presented over Home, so it steps aside for everything that is pushed or presented
    /// from here, and comes back when they are gone.
    private var homeSheetCovered: Bool {
        HomeSheet.isCovered(pathCount: path.count, showName: showName, showDenied: showDenied,
                            afterName: afterName != nil, opening: opening)
    }

    init(pendingJoinCode: Binding<String?> = .constant(nil)) {
        _pendingJoinCode = pendingJoinCode
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if hasSeenWelcome {
                    TripsHomeView(
                        onNewTrip: { begin(.create) },
                        onJoin: { begin(.join(code: nil)) },
                        // Only a trip that hasn't ended reaches here: an ended one is picked on Home's map.
                        onOpenTrip: { entry in begin(.lobby(tripId: entry.id)) },
                        covered: homeSheetCovered,
                        sheetUp: $homeSheetUp,
                        creating: $creating,
                        onCreated: { tripId in path = [.lobby(tripId: tripId)] }
                    )
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
                    // Never pushed: creating a trip happens in Home's sheet (see `creating`).
                    EmptyView()
                case .join(let code):
                    JoinTripView(initialCode: code) { tripId, _ in
                        path = [.lobby(tripId: tripId)]
                    }
                case .lobby(let tripId):
                    LobbyView(tripId: tripId, onExit: { path = [] }, onEnded: { path = [.recap(tripId: $0)] })
                case .recap(let tripId):
                    RecapView(tripId: tripId, onDone: { path = [] })
                }
            }
            .sheet(isPresented: Binding(get: { BottomSheet.presents(wanted: showName, sheetUp: homeSheetUp) },
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
            .sheet(isPresented: Binding(get: { BottomSheet.presents(wanted: showDenied, sheetUp: homeSheetUp) },
                                        set: { showDenied = $0 })) {
                LocationDeniedView { location.openSettings() }
            }
            .onChange(of: auth.state) { old, new in
                // The server dropped this user mid-trip (AuthModel signed them out): back to Home, where the
                // next Start or Join asks for a name again.
                if old == .signedIn, new == .signedOut { path = [] }
            }
            .onChange(of: pendingJoinCode, initial: true) {
                guard let code = pendingJoinCode else { return }
                pendingJoinCode = nil
                // A name comes first when signed out; the join carries on afterwards.
                if auth.state != .signedIn { begin(.join(code: code)); return }
                // Don't pull someone out of a trip they're already in.
                if path.contains(where: { if case .lobby = $0 { true } else { false } }) { return }
                Task { await open(.join(code: code), replacing: true) }
            }
        }
    }

    /// Signed in: go straight to the route. Signed out: ask for a name first.
    private func begin(_ route: Route) {
        if auth.state == .signedIn {
            Task { await open(route) }
        } else {
            afterName = route
            showName = true
        }
    }

    private func open(_ route: Route, replacing: Bool = false) async {
        // A join link (or code) opened during Where to? or New trip leaves that flow: Home is not left on it afterwards.
        if case .join = route { creating = false }
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
                if case .create = route { creating = true; return }
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
