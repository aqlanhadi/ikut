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
    @AppStorage("ikut.hasSeenWelcome") private var hasSeenWelcome = false
    @State private var showDenied = false
    @State private var showName = false
    /// Where to go once the name step finishes.
    @State private var afterName: Route?

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
                        onOpenTrip: { entry in
                            path.append(entry.endedAt == nil ? .lobby(tripId: entry.id) : .recap(tripId: entry.id))
                        }
                    )
                } else {
                    WelcomeView(
                        onGetStarted: { hasSeenWelcome = true },
                        onJoin: {
                            hasSeenWelcome = true
                            begin(.join(code: nil))
                        }
                    )
                    .overlay(alignment: .topTrailing) {
                        #if DEBUG
                        Text(Backend.current.label)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .accessibilityHidden(true)
                        #endif
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .create:
                    CreateTripView { tripId in
                        path = [.lobby(tripId: tripId)]
                    }
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
            .sheet(isPresented: $showName) {
                NameEntryView {
                    showName = false
                    guard let route = afterName else { return }
                    afterName = nil
                    Task {
                        // Let the sheet finish dismissing before a permission prompt appears.
                        try? await Task.sleep(for: .milliseconds(400))
                        await open(route)
                    }
                }
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showDenied) {
                LocationDeniedView { location.openSettings() }
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
        while true {
            switch LocationAccess.nextAction(status: location.status, accuracy: location.accuracy, context: .joiningTrip) {
            case .requestWhenInUse:
                if await location.requestWhenInUse() == .notDetermined { return }
            case .requestFullAccuracy:
                if await location.requestFullAccuracy() == .reduced { showDenied = true; return }
            case .showSettingsPrompt:
                showDenied = true
                return
            case .ready, .showAlwaysExplainer:
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
