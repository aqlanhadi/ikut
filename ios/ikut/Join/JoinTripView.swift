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
        ScrollView {
            VStack(spacing: 0) {
                codeBoxes
                    .padding(.top, 22)
                summaryLine
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(message)")
                        if model.preview == nil, !model.isLoadingPreview, JoinService.isCompleteCode(model.code) {
                            Button("Try again") { model.retryPreview() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                }

                if model.preview != nil {
                    CardHeader("Your name")
                    TextField("Your name", text: $model.displayName)
                        .textContentType(.givenName)
                        .textInputAutocapitalization(.words)
                        .disabled(model.isJoining)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 50)
                        .ikutCard()
                        .accessibilityLabel("Your name")

                    CardHeader("Which car are you in?")
                    carsCard

                    VStack(alignment: .leading, spacing: 0) {
                        Toggle(isOn: $model.tracker) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share this car's location")
                                Text(trackerHint).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Color(.systemGreen))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .disabled(model.isJoining || model.selection == nil)
                    }
                    .ikutCard()
                    .padding(.top, 22)

                    if model.trackerTakenResult != nil {
                        Label(
                            "You're in. Someone else is already tracking that car, so your phone won't share its location.",
                            systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let taken = model.trackerTakenResult {
                Button("Continue") { onJoined(taken.tripId, taken.carId) }
                    .buttonStyle(PillButtonStyle())
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.ikutScreen)
            } else if model.preview != nil {
                Button(action: join) {
                    if model.isJoining {
                        ProgressView().tint(.white).accessibilityLabel("Joining trip")
                    } else {
                        Text("Join Trip")
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!model.canJoin || auth.userID == nil)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.ikutScreen)
            }
        }
        .navigationTitle("Join Trip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if QRScannerView.isAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        codeFocused = false
                        showScanner = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .disabled(model.isJoining)
                    .accessibilityLabel("Scan QR code")
                }
            }
        }
        .task {
            if model.displayName.isEmpty { model.displayName = auth.displayName ?? "" }
            if model.code.isEmpty { codeFocused = true }
            model.start()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { codeText = $0 }
        }
    }

    /// Six boxes drawn from `codeText`, with one real (invisible) text field on top so typing,
    /// paste and AutoFill all keep working.
    private var codeBoxes: some View {
        let characters = Array(codeText)
        let length = TripService.codeLength
        return HStack(spacing: 8) {
            ForEach(0..<length, id: \.self) { index in
                let active = codeFocused && index == min(characters.count, length - 1)
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .ikutCardShape(radius: 14)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.ikutAccent, lineWidth: active ? 2 : 0)
                    }
            }
        }
        .accessibilityHidden(true)
        .overlay { codeField }
    }

    private var codeField: some View {
        TextField("", text: $codeText)
            .foregroundStyle(.clear)
            .tint(.clear)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            .focused($codeFocused)
            .disabled(model.isJoining)
            .accessibilityLabel("Trip code")
            .accessibilityValue(codeText)
            .onChange(of: codeText) {
                model.codeChanged(codeText)
                if codeText != model.code { codeText = model.code }
            }
    }

    @ViewBuilder
    private var summaryLine: some View {
        if model.isLoadingPreview {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for your trip…")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if let preview = model.preview {
            Label {
                Text("\(Text(preview.name).bold().foregroundStyle(.primary)) · to \(preview.destinationName) · \(carCount(preview))")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(.systemGreen))
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            Text("The 6-character code from the organizer.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var carsCard: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            ForEach(Array(model.cars.enumerated()), id: \.element.id) { index, car in
                if index > 0 { RowDivider() }
                carRow(
                    name: car.name, badge: CarBadge(number: car.number ?? index + 1, colorHex: car.color, size: 26),
                    detail: car.hasTracker ? "Being tracked" : nil,
                    selected: model.selectedCar?.id == car.id
                ) { model.select(car) }
            }
            if !model.cars.isEmpty { RowDivider() }
            carRow(
                name: "New Car", badge: CarBadge(symbol: "plus", colorHex: "#8E8E93", size: 26), detail: nil,
                selected: model.selection == .newCar
            ) { model.selectNewCar() }

            if model.selection == .newCar {
                RowDivider()
                TextField("Car name", text: $model.newCarName)
                    .textInputAutocapitalization(.words)
                    .disabled(model.isJoining)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 46)
                    .accessibilityLabel("Car name")
                    .onChange(of: model.newCarName) { model.newCarNameDidEdit() }
            }
        }
        .ikutCard()
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
        name: String, badge: CarBadge, detail: String?,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.ikutAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

private extension View {
    func ikutCardShape(radius: CGFloat) -> some View {
        background(Color.ikutCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

#Preview {
    Backend.configure()
    return NavigationStack {
        JoinTripView { _, _ in }
    }
    .environment(AuthModel())
}
