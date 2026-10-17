import SwiftUI

/// Signed-in home until the real home with past trips lands.
/// Gets location access good enough for a trip before opening Create Trip or Join.
struct HomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location

    private enum Route: Hashable {
        case create
        case join(code: String?)
        case lobby(tripId: String)
    }

    /// A code from an opened link, waiting for the Join screen (set by `IkutApp`).
    @Binding var pendingJoinCode: String?

    @State private var path: [Route] = []
    @State private var showDenied = false

    init(pendingJoinCode: Binding<String?> = .constant(nil)) {
        _pendingJoinCode = pendingJoinCode
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 12) {
                Text("ikut")
                    .font(.largeTitle.bold())
                if let name = auth.displayName {
                    Text("Signed in as \(name)")
                        .foregroundStyle(.secondary)
                }
                Button("Start a Trip") {
                    Task { await open(.create) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 24)
                Button("Join a Trip") {
                    Task { await open(.join(code: nil)) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text(Backend.current.label)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .padding()
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .create:
                    CreateTripView(defaultName: auth.displayName.map { "\($0)'s trip" } ?? "") { tripId in
                        path = [.lobby(tripId: tripId)]
                    }
                case .join(let code):
                    JoinTripView(initialCode: code) { tripId, _ in
                        path = [.lobby(tripId: tripId)]
                    }
                case .lobby(let tripId):
                    // The live map (M1) replaces this no-op.
                    LobbyView(tripId: tripId, onOpenMap: {}, onExit: { path = [] })
                }
            }
            .sheet(isPresented: $showDenied) {
                LocationDeniedView { location.openSettings() }
            }
            .onChange(of: pendingJoinCode, initial: true) {
                guard let code = pendingJoinCode else { return }
                pendingJoinCode = nil
                // Don't pull someone out of a trip they're already in.
                if path.contains(where: { if case .lobby = $0 { true } else { false } }) { return }
                Task { await open(.join(code: code), replacing: true) }
            }
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
