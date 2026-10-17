import SwiftUI

/// Joiner flow: enter the code, pick a car (or add one), choose whether this phone tracks it, join.
struct JoinTripView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model: JoinModel
    @State private var codeText = ""
    @State private var showScanner = false
    @FocusState private var codeFocused: Bool
    var onJoined: (_ tripId: String, _ carId: String) -> Void

    init(initialCode: String? = nil, onJoined: @escaping (_ tripId: String, _ carId: String) -> Void) {
        let model = JoinModel(displayName: "", initialCode: initialCode)
        _model = State(initialValue: model)
        _codeText = State(initialValue: model.code)
        self.onJoined = onJoined
    }

    init(model: JoinModel, onJoined: @escaping (_ tripId: String, _ carId: String) -> Void) {
        _model = State(initialValue: model)
        _codeText = State(initialValue: model.code)
        self.onJoined = onJoined
    }

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack {
                    codeField
                    if QRScannerView.isAvailable {
                        Button {
                            codeFocused = false
                            showScanner = true
                        } label: {
                            Image(systemName: "qrcode.viewfinder").font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isJoining)
                        .accessibilityLabel("Scan QR code")
                    }
                }
            } header: {
                Text("Trip code")
            } footer: {
                if model.isLoadingPreview {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking for your trip…")
                    }
                    .accessibilityElement(children: .combine)
                } else if let preview = model.preview {
                    Label {
                        Text("\(Text(preview.name).bold().foregroundStyle(.primary)) · to \(preview.destinationName) · \(carCount(preview))")
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("The 6-character code from the organizer.")
                }
            }

            if model.preview != nil {
                Section("Your name") {
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .disabled(model.isJoining)
                        .accessibilityLabel("Your name")
                }

                Section("Which car are you in?") {
                    ForEach(model.cars) { car in
                        carRow(
                            name: car.name, color: car.color,
                            detail: car.hasTracker ? "Being tracked" : nil,
                            selected: model.selectedCar?.id == car.id
                        ) { model.select(car) }
                    }
                    carRow(
                        name: "New car", color: model.newCarColor, detail: nil, symbol: "plus",
                        selected: model.selection == .newCar
                    ) { model.selectNewCar() }

                    if model.selection == .newCar {
                        TextField("Car name", text: $model.newCarName)
                            .textInputAutocapitalization(.words)
                            .disabled(model.isJoining)
                            .accessibilityLabel("Car name")
                            .onChange(of: model.newCarName) { model.newCarNameDidEdit() }
                    }
                }

                Section {
                    Toggle(isOn: $model.tracker) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("This phone tracks the car")
                            Text(trackerHint).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isJoining || model.selection == nil)
                }
            }

            if let message = model.errorMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(message)")
                    if model.preview == nil, !model.isLoadingPreview, JoinService.isCompleteCode(model.code) {
                        Button("Try again") { model.retryPreview() }
                    }
                }
            }

            if let taken = model.trackerTakenResult {
                Section {
                    Label(
                        "You're in. Someone else is already tracking that car, so your phone won't share its location.",
                        systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Continue") { onJoined(taken.tripId, taken.carId) }
                        .bold()
                }
            } else if model.preview != nil {
                Section {
                    Button(action: join) {
                        HStack {
                            Spacer()
                            if model.isJoining {
                                ProgressView().accessibilityLabel("Joining trip")
                            } else {
                                Text("Join Trip").bold()
                            }
                            Spacer()
                        }
                    }
                    .disabled(!model.canJoin || auth.userID == nil)
                }
            }
        }
        .navigationTitle("Join Trip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.displayName.isEmpty { model.displayName = auth.displayName ?? "" }
            if model.code.isEmpty { codeFocused = true }
            model.start()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { codeText = $0 }
        }
    }

    private var codeField: some View {
        TextField("Trip code", text: $codeText)
            .font(.system(.title, design: .monospaced, weight: .semibold))
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .focused($codeFocused)
            .disabled(model.isJoining)
            .accessibilityLabel("Trip code")
            .onChange(of: codeText) {
                model.codeChanged(codeText)
                if codeText != model.code { codeText = model.code }
            }
    }

    private var trackerHint: String {
        model.selectedCarHasTracker
            ? "Someone is already tracking this car."
            : "One tracker per car saves battery."
    }

    private func carCount(_ preview: TripPreview) -> String {
        preview.cars.count == 1 ? "1 car" : "\(preview.cars.count) cars"
    }

    private func carRow(
        name: String, color: String, detail: String?, symbol: String? = nil,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol ?? "car.fill")
                    .font(.footnote.bold())
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color(joinHex: color) ?? .gray, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
        }
        .disabled(model.isJoining)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func join() {
        Task {
            if let result = await model.join() { onJoined(result.tripId, result.carId) }
        }
    }
}

private extension Color {
    /// "#RRGGBB" (the `#` is optional); nil if malformed.
    init?(joinHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}

#Preview {
    Backend.configure()
    return NavigationStack {
        JoinTripView { _, _ in }
    }
    .environment(AuthModel())
}
