import FirebaseAuth
import SwiftUI

/// Shown after creating or joining a trip: join code, QR, share and the live list of cars.
struct LobbyView: View {
    let onOpenMap: () -> Void
    @State private var model: LobbyModel
    @State private var copied = false

    init(tripId: String, onOpenMap: @escaping () -> Void) {
        self.onOpenMap = onOpenMap
        _model = State(initialValue: LobbyModel(tripId: tripId))
    }

    private var isOrganizer: Bool {
        guard let trip = model.trip else { return false }
        return trip.organizerId == Auth.auth().currentUser?.uid
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header
                if let trip = model.trip {
                    codeCard(trip.code)
                    carsSection
                    if isOrganizer { organizerControls }
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
        .onAppear { model.start() }
        .onDisappear { model.stop() }
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
        EmptyView()
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
