import FirebaseAuth
import SwiftUI

/// Shown after creating or joining a trip: join code, QR, share and the live list of cars.
struct LobbyView: View {
    let onOpenMap: () -> Void
    let onExit: () -> Void
    @Environment(LocationPermission.self) private var location
    @State private var model: LobbyModel
    @State private var session: TripSession
    @State private var copied = false
    @State private var showAlwaysExplainer = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var actionError: String?

    init(tripId: String, onOpenMap: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onOpenMap = onOpenMap
        self.onExit = onExit
        _model = State(initialValue: LobbyModel(tripId: tripId))
        _session = State(initialValue: TripSession(
            tripId: tripId, userId: Auth.auth().currentUser?.uid ?? ""))
    }

    private var isOrganizer: Bool {
        guard let trip = model.trip else { return false }
        return trip.organizerId == Auth.auth().currentUser?.uid
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                statusBanner
                if let trip = model.trip {
                    codeCard(trip.code)
                    carsSection
                    if isOrganizer, !session.isEnded { organizerControls }
                    leaveControls
                } else if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onOpenMap) {
                Text("Go to map").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle("Lobby")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.start()
            session.start()
        }
        // The session keeps running when another screen (the map) is pushed on top; it stops when
        // the lobby is popped and the session is released.
        .onDisappear { model.stop() }
        .onChange(of: session.isTracking) { _, tracking in
            guard tracking else { return }
            let action = LocationAccess.nextAction(
                status: location.status, accuracy: location.accuracy, context: .goingToBackground)
            if session.consumeAlwaysExplainer(action: action) { showAlwaysExplainer = true }
        }
        .sheet(isPresented: $showAlwaysExplainer) {
            // Declining is fine: the background activity session keeps tracking alive on When In Use.
            AlwaysLocationExplainerView(permission: location) { _ in showAlwaysExplainer = false }
        }
        .confirmationDialog("Leave this trip?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave trip", role: .destructive) { run { try await session.leave(); onExit() } }
        } message: {
            Text("Your phone stops sharing its location.")
        }
        .confirmationDialog("End the trip for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End trip", role: .destructive) { run { try await session.endTrip() } }
        } message: {
            Text("Everyone stops sharing their location. This can't be undone.")
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
            isWorking = false
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if session.isEnded {
            exitBanner("Trip ended", systemImage: "flag.checkered")
        } else if session.membershipLost && model.trip != nil {
            exitBanner("You're no longer in this trip", systemImage: "person.fill.xmark")
        } else if session.isTracking {
            Label("Sharing location", systemImage: "location.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.green.opacity(0.15), in: Capsule())
        }
    }

    private func exitBanner(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Button("Back to Home", action: onExit).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(model.trip?.name ?? " ").font(.title2.bold())
            if let destination = model.trip?.destination.name {
                Label(destination, systemImage: "mappin.and.ellipse")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
    }

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: 16) {
            Text("Join code").font(.footnote).foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 44, weight: .bold, design: .monospaced))
                .kerning(4)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .textSelection(.enabled)
            if let image = QRCode.image(for: LobbyLogic.joinURL(code: code)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("QR code to join with code \(code)")
            }
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                ShareLink(item: LobbyLogic.shareText(code: code)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var carsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cars").font(.headline)
            if model.groupedCars.isEmpty {
                Text("No cars yet").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(model.groupedCars) { item in
                CarRow(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Room for future organizer controls (rename, remove members, ...).
    private var organizerControls: some View {
        Button(role: .destructive) { confirmEnd = true } label: {
            Text("End trip").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(isWorking)
    }

    @ViewBuilder
    private var leaveControls: some View {
        if !session.isEnded, !session.membershipLost {
            Button(role: .destructive) { confirmLeave = true } label: {
                Text("Leave trip").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isWorking)
        }
        if let actionError {
            Text(actionError).font(.footnote).foregroundStyle(.red)
        }
    }
}

private struct CarRow: View {
    let item: LobbyCar

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(LobbyColor.color(hex: item.car.color))
                .frame(width: 14, height: 14)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.car.name).font(.body.weight(.semibold))
                    if item.car.isLead {
                        Text("Lead")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.fill.secondary, in: Capsule())
                    }
                }
                Text(item.members.isEmpty ? "No one yet" : item.members.map(\.displayName).joined(separator: ", "))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Label(item.hasTracker ? "Tracker" : "No tracker",
                  systemImage: item.hasTracker ? "location.fill" : "location.slash")
                .font(.caption)
                .foregroundStyle(item.hasTracker ? Color.green : Color.secondary)
        }
        .padding(12)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

enum LobbyColor {
    /// "#RRGGBB" to a color; gray for anything malformed.
    static func color(hex: String) -> Color {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return .gray }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
