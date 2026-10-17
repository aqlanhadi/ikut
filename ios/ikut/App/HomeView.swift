import SwiftUI

/// Signed-in home until the real home, lobby and join screens land (T3, T4).
/// Gets location access good enough for a trip before opening Create Trip.
struct HomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location

    @State private var showCreate = false
    @State private var showDenied = false
    @State private var createdTripID: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("ikut")
                    .font(.largeTitle.bold())
                if let name = auth.displayName {
                    Text("Signed in as \(name)")
                        .foregroundStyle(.secondary)
                }
                if let createdTripID {
                    Label("Trip created: \(createdTripID)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.top, 8)
                }
                Button("Start a Trip") {
                    Task { await startTrip() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 24)
                Text(Backend.current.label)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.top, 24)
            }
            .padding()
            .navigationDestination(isPresented: $showCreate) {
                CreateTripView(defaultName: auth.displayName.map { "\($0)'s trip" } ?? "") { tripID in
                    createdTripID = tripID
                    showCreate = false
                }
            }
            .sheet(isPresented: $showDenied) {
                LocationDeniedView { location.openSettings() }
            }
        }
    }

    private func startTrip() async {
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
                showCreate = true
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
