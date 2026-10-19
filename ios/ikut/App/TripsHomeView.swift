import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are, then a sheet-like
/// card with New Trip, Join Trip and past trips.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    var onNewTrip: () -> Void
    var onJoin: () -> Void

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?

    /// Where the map opens when location isn't available yet.
    private static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 250)
                card
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(alignment: .top) {
            Map(initialPosition: .userLocation(fallback: .region(Self.fallback))) {
                UserAnnotation()
            }
            .mapControlVisibility(.hidden)
            .allowsHitTesting(false)
            .frame(height: 380)
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
        }
        .background(Color.ikutScreen)
        .overlay(alignment: .topTrailing) { profileButton }
        .alert("Your name", isPresented: $renaming) {
            TextField("Your name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
        } message: {
            Text("What the convoy sees in new trips.")
        }
        .alert("Couldn't change your name", isPresented: .constant(renameError != nil)) {
            Button("OK") { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trips")
                .font(.largeTitle.bold())
                .padding(.horizontal, 4)
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                Button(action: onNewTrip) {
                    Label("New Trip", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle())
                Button(action: onJoin) {
                    Label("Join Trip", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
            .padding(.top, 12)

            CardHeader("Past trips")
            // Trip history isn't stored per user yet; see planning notes.
            Text("Trips you start or join will show here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 58)
                .ikutCard()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, minHeight: 600, alignment: .top)
        .background(
            Color.ikutScreen,
            in: UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous)
        )
        .shadow(color: .black.opacity(0.10), radius: 15, y: -8)
    }

    @ViewBuilder
    private var profileButton: some View {
        if let name = auth.displayName, auth.state == .signedIn {
            Menu {
                Section(name) {
                    Button("Change Name", systemImage: "pencil") {
                        newName = name
                        renaming = true
                    }
                }
                #if DEBUG
                Section(Backend.current.label) {}
                #endif
            } label: {
                Text(name.prefix(1).uppercased())
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 7, y: 4)
            }
            .accessibilityLabel("Profile, \(name)")
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func saveName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success = DisplayName.validate(trimmed) else {
            renameError = "Use 1 to \(DisplayName.maxLength) characters."
            return
        }
        Task {
            do { try await auth.updateDisplayName(trimmed) } catch { renameError = error.localizedDescription }
        }
    }
}

#Preview {
    Backend.configure()
    return TripsHomeView(onNewTrip: {}, onJoin: {})
        .environment(AuthModel())
}
