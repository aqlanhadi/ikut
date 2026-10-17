import SwiftUI

/// Signed-in home until the real home with past trips lands.
/// Gets location access good enough for a trip before opening Create Trip or Join.
struct HomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location

    private enum Route: Hashable {
        case create
        case join
        case lobby(tripId: String)
    }

    @State private var path: [Route] = []
    @State private var showDenied = false

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
                    Task { await open(.join) }
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
                case .join:
                    JoinTripView { tripId, _ in
                        path = [.lobby(tripId: tripId)]
                    }
                case .lobby(let tripId):
                    // The live map (M1) replaces this no-op.
                    LobbyView(tripId: tripId, onOpenMap: {})
                }
            }
            .sheet(isPresented: $showDenied) {
                LocationDeniedView { location.openSettings() }
            }
        }
    }

    private func open(_ route: Route) async {
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
                path.append(route)
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
