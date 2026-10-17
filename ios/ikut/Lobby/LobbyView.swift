import FirebaseAuth
import SwiftUI

/// Shown after creating or joining a trip: join code, QR, share and the live list of cars.
struct LobbyView: View {
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
    @State private var showMap = false

    init(tripId: String, onExit: @escaping () -> Void) {
        self.onExit = onExit
        _model = State(initialValue: LobbyModel(tripId: tripId))
        _session = State(initialValue: TripSession(
            tripId: tripId, userId: Auth.auth().currentUser?.uid ?? ""))
    }

    private var isOrganizer: Bool {
        guard let trip = model.trip else { return false }
        return trip.organizerId == Auth.auth().currentUser?.uid
    }

    private var currentUserId: String? { Auth.auth().currentUser?.uid }
    private var canLeave: Bool { !session.isEnded && !session.membershipLost }
    private var canEnd: Bool { isOrganizer && !session.isEnded }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                statusBanner
                if let trip = model.trip {
                    tripCard(trip)
                    CardHeader("Invite")
                    inviteCard(trip.code)
                    carsHeader
                    carsCard
                    if let actionError {
                        Text(actionError)
                            .font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 12)
                    }
                } else if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.top, 20)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Start Trip") { showMap = true }
                .buttonStyle(PillButtonStyle())
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.ikutScreen)
        }
        // The map shares this lobby's session; the lobby stays on the stack underneath it.
        .navigationDestination(isPresented: $showMap) {
            TripMapView(session: session, onExit: onExit)
        }
        .navigationTitle("Trip lobby")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canLeave || canEnd {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canEnd {
                            Button("End trip", systemImage: "flag.checkered", role: .destructive) { confirmEnd = true }
                        }
                        if canLeave {
                            Button("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                confirmLeave = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Trip options")
                }
            }
        }
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
                .foregroundStyle(Color.ikutPositive)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.ikutPositive.opacity(0.15), in: Capsule())
                .padding(.bottom, 4)
        }
    }

    private func exitBanner(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Button("Back to Home", action: onExit).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .ikutCard()
        .padding(.bottom, 8)
    }

    /// Read-only version of the New Trip card: name, then destination with its pin tile.
    private func tripCard(_ trip: Trip) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Name").frame(width: 64, alignment: .leading)
                Text(trip.name).frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .accessibilityElement(children: .combine)
            RowDivider()
            HStack(spacing: 12) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                Text(trip.destination.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Destination, \(trip.destination.name)")
        }
        .ikutCard()
    }

    private func inviteCard(_ code: String) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Join code").font(.footnote).foregroundStyle(.secondary)
                Text(LobbyLogic.displayCode(code))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .kerning(2)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
                HStack(spacing: 8) {
                    ShareLink(item: LobbyLogic.shareText(code: code)) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ikutAccent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Color.ikutAccent.opacity(0.10), in: Capsule())
                    }
                    Button {
                        UIPasteboard.general.string = code
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.ikutAccent)
                            .frame(width: 36, height: 36)
                            .background(Color.ikutAccent.opacity(0.10), in: Circle())
                    }
                    .accessibilityLabel(copied ? "Copied" : "Copy code")
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
            if let image = QRCode.image(for: LobbyLogic.joinURL(code: code)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104, height: 104)
                    .padding(6)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityLabel("QR code to join with code \(code)")
            }
        }
        .padding(16)
        .ikutCard()
    }

    private var carsHeader: some View {
        let cars = model.groupedCars
        let ready = cars.filter(\.hasTracker).count
        return CardHeader("Cars", trailing: cars.isEmpty ? nil : "\(ready) of \(cars.count) ready")
    }

    private var carsCard: some View {
        let cars = model.groupedCars
        return VStack(spacing: 0) {
            if cars.isEmpty {
                Text("No cars yet")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            ForEach(Array(cars.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                CarRow(item: item, position: index + 1, currentUserId: currentUserId)
            }
        }
        .ikutCard()
    }
}

private struct CarRow: View {
    let item: LobbyCar
    /// 1-based place in the list, used when the car has no number of its own.
    let position: Int
    let currentUserId: String?

    var body: some View {
        HStack(spacing: 12) {
            CarBadge(number: item.car.number ?? position, colorHex: item.car.color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.car.name)
                    if item.car.isLead {
                        Text("Lead")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.fill.secondary, in: Capsule())
                    }
                }
                Text(people)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(item.hasTracker ? "Tracking" : "Waiting")
                .font(.subheadline)
                .foregroundStyle(item.hasTracker ? Color.ikutPositive : Color.ikutWarning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 58)
        .accessibilityElement(children: .combine)
    }

    private var people: String {
        LobbyLogic.peopleLine(
            members: item.members, trackerUserId: item.car.trackerUserId, currentUserId: currentUserId)
    }
}

/// Display strings for the lobby (kept here so the logic file stays untouched).
extension LobbyLogic {
    /// "K7M2QX" shown as "K7M 2QX".
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// "You (organizer, tracker) · Siti", "Wyna (tracker) · 3 others", "Daniel · no tracker yet".
    static func peopleLine(members: [Member], trackerUserId: String?, currentUserId: String?) -> String {
        guard !members.isEmpty else { return "No one yet" }
        let ordered = members.filter { $0.id == currentUserId } + members.filter { $0.id != currentUserId }
        func label(_ m: Member) -> String {
            var roles: [String] = []
            if m.role == .organizer { roles.append("organizer") }
            if let id = m.id, id == trackerUserId { roles.append("tracker") }
            let name = m.id == currentUserId ? "You" : m.displayName
            return roles.isEmpty ? name : "\(name) (\(roles.joined(separator: ", ")))"
        }
        var parts: [String]
        if ordered.count <= 2 {
            parts = ordered.map(label)
        } else {
            parts = ordered.prefix(1).map(label)
            parts.append("\(ordered.count - 1) others")
        }
        if trackerUserId == nil { parts.append("no tracker yet") }
        return parts.joined(separator: " · ")
    }
}
