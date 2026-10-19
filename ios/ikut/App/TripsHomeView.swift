import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are under a floating
/// glass sheet with New Trip, Join Trip and past trips.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    var onNewTrip: () -> Void
    var onJoin: () -> Void

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    @State private var expanded = false
    @GestureState private var dragOffset: CGFloat = 0

    /// Where the map opens when location isn't available yet.
    private static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))

    var body: some View {
        ZStack {
            Map(initialPosition: .userLocation(fallback: .region(Self.fallback))) {
                UserAnnotation()
            }
            .mapControlVisibility(.hidden)
            .ignoresSafeArea()
            .accessibilityHidden(true)
            sheet
        }
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

    // MARK: Sheet

    /// Height of the sheet when collapsed: grabber, title, the two pills and the top of past trips.
    private static let compactHeight: CGFloat = 300
    /// Room left above the expanded sheet for the profile button.
    private static let topClearance: CGFloat = 64

    /// A Flighty-style glass sheet floating over the map. Drag or tap the top to move between a
    /// compact and a tall detent. A custom overlay rather than a `.sheet`, like `ConvoyPanel`:
    /// a sheet that is always up would sit over pushed screens and block the name sheet.
    private var sheet: some View {
        GeometryReader { geo in
            let bottomInset = geo.safeAreaInsets.bottom
            // From the top of the safe area to the bottom of the screen.
            let full = geo.size.height + bottomInset
            let tall = max(Self.compactHeight, full - Self.topClearance)
            let height = sheetHeight(compact: Self.compactHeight, tall: tall)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    grabber
                    header
                }
                .contentShape(Rectangle())
                .gesture(sheetDrag(compact: Self.compactHeight, tall: tall))

                ScrollView {
                    pastTrips
                        .padding(.bottom, bottomInset + 16)
                }
                .scrollDisabled(!expanded)
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: height, alignment: .top)
            .glassSheetBackground()
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: bottomInset - 8)
        }
    }

    private func sheetHeight(compact: CGFloat, tall: CGFloat) -> CGFloat {
        let base = expanded ? tall : compact
        let raw = base - dragOffset
        // Rubber-band past either detent.
        if raw > tall { return tall + (raw - tall) * 0.2 }
        if raw < compact { return compact - (compact - raw) * 0.2 }
        return raw
    }

    private func sheetDrag(compact: CGFloat, tall: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragOffset) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let base = expanded ? tall : compact
                // Project the fling so a quick flick moves a detent even over a short distance.
                let projected = base - value.predictedEndTranslation.height
                withAnimation(.snappy) { expanded = projected > (compact + tall) / 2 }
            }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse trips" : "Expand trips")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(.snappy) { expanded.toggle() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trips")
                .font(.largeTitle.bold())
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 10) {
                Button(action: onNewTrip) {
                    Label("New Trip", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle())
                Button(action: onJoin) {
                    Label("Join Trip", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(GlassPillButtonStyle())
            }
            .padding(.top, 12)
        }
    }

    private var pastTrips: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Past trips")
            // Trip history isn't stored per user yet; see planning notes.
            Text("Trips you start or join will show here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
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
            .tint(.primary)
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

private extension View {
    /// Liquid Glass on iOS 26 and later, with bottom corners that follow the screen's; a material
    /// before that.
    @ViewBuilder
    func glassSheetBackground() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: ConcentricRectangle(corners: .concentric(minimum: 38), isUniform: false))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        }
    }
}

/// `SecondaryPillButtonStyle` for a glass background: the opaque card fill would read as a slab.
private struct GlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.fill.quaternary, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

#Preview {
    Backend.configure()
    return TripsHomeView(onNewTrip: {}, onJoin: {})
        .environment(AuthModel())
}
