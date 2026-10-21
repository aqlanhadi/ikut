import SwiftUI

/// Joiner flow (Join.dc.html): enter the code, then on the trip's ticket give a name, say whether
/// you're driving, pick a car (or add one) and join.
struct JoinTripView: View {
    @Environment(AuthModel.self) private var auth
    @State private var model: JoinModel
    @State private var codeText = ""
    @State private var showScanner = false
    @State private var role: Role = .driver
    @FocusState private var codeFocused: Bool
    var onJoined: (_ tripId: String, _ carId: String) -> Void

    /// Drivers share their car's location; passengers ride along without tracking.
    enum Role: String, CaseIterable, Identifiable {
        case driver, passenger
        var id: Self { self }
        var label: String { self == .driver ? "I’m driving" : "Passenger" }
        var symbol: String { self == .driver ? "steeringwheel" : "person.fill" }
    }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let preview = model.preview {
                    ticket(preview)
                        .padding(.top, Spacing.m)
                } else {
                    codeBoxes
                        .padding(.top, Spacing.sectionLarge)
                    summaryLine
                        .padding(.horizontal, Spacing.l)
                        .padding(.top, Spacing.gap)
                }

                if let message = model.errorMessage {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Error: \(message)")
                        if model.preview == nil, !model.isLoadingPreview, JoinService.isCompleteCode(model.code) {
                            Button("Try again") { model.retryPreview() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.gap)
                }

                if model.preview != nil {
                    nameAndRoleCard
                        .padding(.top, Spacing.m)
                    CardHeader(role == .driver ? "Which car are you driving?" : "Which car are you riding in?")
                    carGrid
                    roleNote
                        .padding(.top, Spacing.m)

                    if model.trackerTakenResult != nil {
                        InlineNote(
                            "You're in. Someone else is already tracking that car, so your phone won't share its location.",
                            systemImage: "info.circle")
                            .padding(.top, Spacing.m)
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let taken = model.trackerTakenResult {
                Button("Continue") { onJoined(taken.tripId, taken.carId) }
                    .buttonStyle(PillButtonStyle())
                    .ikutBottomBar()
            } else if model.preview != nil {
                Button(action: join) {
                    if model.isJoining {
                        ProgressView().tint(.white).accessibilityLabel("Joining trip")
                    } else {
                        Text(joinLabel)
                    }
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!model.canJoin || auth.userID == nil)
                .ikutBottomBar()
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
        // Picking a car sets `tracker` (off when someone already tracks it); follow it.
        .onChange(of: model.selection) { role = model.tracker ? .driver : .passenger }
        .onChange(of: role) { model.tracker = role == .driver }
    }

    // MARK: Code entry

    /// Six boxes drawn from `codeText`, with one real (invisible) text field on top so typing,
    /// paste and AutoFill all keep working.
    private var codeBoxes: some View {
        let characters = Array(codeText)
        let length = TripService.codeLength
        return HStack(spacing: Spacing.s) {
            ForEach(0..<length, id: \.self) { index in
                let active = codeFocused && index == min(characters.count, length - 1)
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .ikutCard(radius: Radius.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Looking for your trip…")
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

    // MARK: Ticket

    /// The found trip as a ticket: name, "Code found", destination, then code and car count.
    private func ticket(_ preview: TripPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text(preview.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    Label("Code found", systemImage: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.ikutPositive)
                        .padding(.horizontal, Spacing.chipX)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.ikutPositive.opacity(0.14), in: Capsule())
                }
                RouteEnds(from: nil, to: preview.destinationName)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.cozy)
            .padding(.bottom, Spacing.m)

            TicketTear()

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    StatCaption("Code")
                    Text(LobbyLogic.displayCode(model.code))
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .kerning(1)
                        .accessibilityLabel(model.code.map(String.init).joined(separator: " "))
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    StatCaption("Cars")
                    Text("\(preview.cars.count) in")
                        .font(.system(.body, design: .rounded).weight(.bold))
                }
                .accessibilityElement(children: .combine)
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change") {
                    codeText = ""
                    codeFocused = true
                }
                .font(.subheadline.weight(.semibold))
                .disabled(model.isJoining)
                .accessibilityLabel("Change code")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.gap)
            .padding(.bottom, Spacing.cozy)
        }
        .ikutCard()
        // The code field stays in the view tree (hidden) so "Change" can clear it and type again.
        .background { codeField.opacity(0).allowsHitTesting(false) }
    }

    // MARK: Name, role and car

    private var nameAndRoleCard: some View {
        @Bindable var model = model
        return VStack(spacing: Spacing.tight) {
            HStack(spacing: Spacing.m) {
                Text("Name")
                TextField("Your name", text: $model.displayName)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .multilineTextAlignment(.trailing)
                    .disabled(model.isJoining)
                    .accessibilityLabel("Your name")
            }
            .frame(minHeight: 44)
            .padding(.horizontal, Spacing.l)

            Picker("Your role", selection: $role) {
                ForEach(Role.allCases) { role in
                    Label(role.label, systemImage: role.symbol).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.large)
            .disabled(model.isJoining)
            .padding(.horizontal, Spacing.s)
            .padding(.bottom, Spacing.s)
        }
        .ikutCard()
    }

    private var carGrid: some View {
        @Bindable var model = model
        return VStack(spacing: Spacing.s) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible(), spacing: Spacing.s)], spacing: Spacing.s) {
                ForEach(Array(model.cars.enumerated()), id: \.element.id) { index, car in
                    carTile(
                        name: car.name,
                        badge: CarBadge(number: car.number ?? index + 1, colorHex: car.color, size: 26),
                        detail: car.hasTracker ? "Being tracked" : "No tracker yet",
                        selected: model.selectedCar?.id == car.id
                    ) { model.select(car) }
                }
                carTile(
                    name: "A new car", badge: CarBadge(symbol: "plus", colorHex: "#8E8E93", size: 26),
                    detail: "Not listed yet", selected: model.selection == .newCar
                ) { model.selectNewCar() }
            }
            if model.selection == .newCar {
                TextField("Car name", text: $model.newCarName)
                    .textInputAutocapitalization(.words)
                    .disabled(model.isJoining)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 46)
                    .ikutCard()
                    .accessibilityLabel("Car name")
                    .onChange(of: model.newCarName) { model.newCarNameDidEdit() }
            }
        }
    }

    private func carTile(
        name: String, badge: CarBadge, detail: String,
        selected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.gap) {
                badge
                VStack(alignment: .leading, spacing: 0) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 56)
            .ikutCard(radius: Radius.row)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Color.ikutAccent, lineWidth: selected ? 2 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isJoining)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// Drivers get the tracker switch; passengers a note on what they can do instead.
    @ViewBuilder
    private var roleNote: some View {
        @Bindable var model = model
        if role == .driver {
            Toggle(isOn: $model.tracker) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Share this car’s location")
                    Text(model.selectedCarHasTracker
                         ? "Someone is already tracking this car."
                         : "Set it and forget it. Works with the screen off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Color(.systemGreen))
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .disabled(model.isJoining || model.selection == nil)
            .ikutCard()
        } else {
            HStack(alignment: .top, spacing: Spacing.m) {
                IconTile(
                    symbol: model.selectedCarHasTracker ? "location.fill" : "location.slash.fill",
                    color: model.selectedCarHasTracker ? Color.green : Color.orange,
                    size: 30, font: .system(size: 15, weight: .semibold))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(model.selectedCarHasTracker
                         ? "\(selectedCarName) is already tracked"
                         : "No one is sharing \(selectedCarName)’s location yet")
                    Text("You’re the co-pilot: call stops and report hazards for the driver.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.m)
            .ikutCard()
            .accessibilityElement(children: .combine)
        }
    }

    private var selectedCarName: String { model.selectedCar?.name ?? "your car" }

    private var joinLabel: String {
        if let car = model.selectedCar { return "Join in \(car.name)" }
        return "Join Trip"
    }

    private func join() {
        Task {
            if let result = await model.join() { onJoined(result.tripId, result.carId) }
        }
    }
}

/// Dashed tear line across a ticket card, with a notch cut on each side.
private struct TicketTear: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.clear)
                .frame(height: 2)
                .overlay {
                    GeometryReader { proxy in
                        Path { p in
                            p.move(to: CGPoint(x: 0, y: 1))
                            p.addLine(to: CGPoint(x: proxy.size.width, y: 1))
                        }
                        .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    }
                }
                .padding(.horizontal, Spacing.l)
            HStack {
                Circle().fill(Color.ikutScreen).frame(width: 20, height: 20).offset(x: -10)
                Spacer()
                Circle().fill(Color.ikutScreen).frame(width: 20, height: 20).offset(x: 10)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    Backend.configure()
    return NavigationStack {
        JoinTripView { _, _ in }
    }
    .environment(AuthModel())
}
