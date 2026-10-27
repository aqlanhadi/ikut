import SwiftUI

/// Joining a trip as the content of Home's sheet (D58): the code (H3), then which car (H4), one step at a time.
/// The sheet keeps one height for every step (`HomeSheet.joinHeight`); only the content changes. The map behind it
/// draws the found trip (Home's map, fed by `JoinStepper.mapInput`).
struct JoinSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var stepper: JoinStepper
    var onClose: () -> Void
    var onJoined: (_ tripId: String) -> Void

    @State private var codeText: String
    @State private var showScanner = false
    @ScaledMetric(relativeTo: .title2) private var codeBoxSize: CGFloat = 26
    @FocusState private var codeFocused: Bool

    init(stepper: JoinStepper, onClose: @escaping () -> Void, onJoined: @escaping (_ tripId: String) -> Void) {
        self.stepper = stepper
        self.onClose = onClose
        self.onJoined = onJoined
        _codeText = State(initialValue: stepper.model.code)
    }

    private var model: JoinModel { stepper.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTopRow(title: stepper.title, subtitle: stepper.indicator, subtitleIdentifier: "joinStep") {
                if JoinSteps.previous(before: stepper.step) != nil {
                    RoundGlassIconButton(systemImage: "chevron.left", label: "Back", action: back)
                        .accessibilityIdentifier("joinBack").disabled(model.isJoining)
                }
            } trailing: {
                RoundGlassIconButton(systemImage: "xmark", label: "Close", action: onClose)
                    .accessibilityIdentifier("sheet.close").disabled(model.isJoining)
            }
            .padding(.top, Spacing.xs)

            ScrollView {
                Group {
                    switch stepper.step {
                    case .code: codeStep
                    case .car: carStep
                    }
                }
                .padding(.bottom, Spacing.l)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .id(stepper.step)
            .transition(.opacity)

            bottomBar
        }
        .animation(HomeSheet.motion(reduceMotion: reduceMotion), value: stepper.step)
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
        .task {
            if model.displayName.isEmpty { model.displayName = auth.displayName ?? "" }
            if model.code.isEmpty { codeFocused = true }
            model.start()
        }
        .sheet(isPresented: $showScanner) {
            QRScannerView { codeText = $0 }
        }
        // The keyboard goes once the trip is found, so the card has the room.
        .onChange(of: model.preview != nil) { _, found in if found { codeFocused = false } }
    }

    private func back() {
        withAnimation(HomeSheet.motion(reduceMotion: reduceMotion)) { stepper.goBack() }
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        switch stepper.step {
        case .code:
            if stepper.canContinue {
                Button { withAnimation(HomeSheet.motion(reduceMotion: reduceMotion)) { stepper.goNext() } } label: {
                    Text("Continue").barActionLabel()
                }
                .actionBarStyle(prominent: true)
                .accessibilityIdentifier("joinContinue")
                .sheetActionBar(sides: false)
                .padding(.bottom, PanelSheet.sideGap)
            }
        case .car:
            if let taken = model.trackerTakenResult {
                Button { onJoined(taken.tripId) } label: { Text("Continue").barActionLabel() }
                    .actionBarStyle(prominent: true)
                    .accessibilityIdentifier("joinContinue")
                    .sheetActionBar(sides: false)
                    .padding(.bottom, PanelSheet.sideGap)
            } else {
                Button(action: join) {
                    Group {
                        if model.isJoining {
                            ProgressView().accessibilityLabel("Joining trip")
                        } else {
                            Text(joinLabel).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .barActionLabel()
                }
                .actionBarStyle(prominent: true)
                .disabled(!stepper.canContinue || auth.userID == nil)
                .accessibilityIdentifier("joinConfirm")
                .sheetActionBar(sides: false)
                .padding(.bottom, PanelSheet.sideGap)
            }
        }
    }

    private var firstName: String { (try? DisplayName.validate(model.displayName).get()) ?? model.displayName }

    private var joinLabel: String {
        JoinSteps.joinLabel(car: model.selectedCar, ownCar: model.selection == .newCar, firstName: firstName)
    }

    private func join() {
        Task {
            if let result = await model.join() { onJoined(result.tripId) }
        }
    }

    // MARK: H3 Code

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            codeBoxes
                .padding(.top, Spacing.m)
            if let preview = model.preview {
                tripCard(preview)
                Button("Use a different code") {
                    codeText = ""
                    codeFocused = true
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                status
                if QRScannerView.isAvailable {
                    Button {
                        codeFocused = false
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder").inlineActionLabel()
                    }
                    .actionBarStyle(prominent: false)
                    .accessibilityIdentifier("joinScan")
                }
            }
        }
    }

    /// Looking, the caption, or why the code wasn't found, with Try again when it was a bad connection.
    @ViewBuilder private var status: some View {
        if model.isLoadingPreview {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Looking for your trip…")
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else if let message = model.errorMessage {
            VStack(alignment: .leading, spacing: Spacing.s) {
                InlineNote(message, tone: .alert, inset: 0)
                    .accessibilityIdentifier("joinError")
                if JoinService.isCompleteCode(model.code) {
                    Button("Try again") { model.retryPreview() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        } else {
            Text("The 6-letter code from the organiser.")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Six boxes drawn from `codeText`, with one real (invisible) text field on top so typing, paste and AutoFill all
    /// keep working.
    private var codeBoxes: some View {
        let characters = Array(codeText)
        let length = TripService.codeLength
        return HStack(spacing: Spacing.s) {
            ForEach(0..<length, id: \.self) { index in
                let active = codeFocused && index == min(characters.count, length - 1)
                Text(index < characters.count ? String(characters[index]) : "")
                    .font(.system(size: ScaledSize.capped(codeBoxSize, base: 26, cap: 1.4), weight: .semibold, design: .monospaced))
                    // One letter per box: it can't wrap, so it shrinks a little at the largest sizes.
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .surfaceTile(radius: Radius.control)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.ikutAccent, lineWidth: active ? 2 : 0)
                    }
            }
        }
        .accessibilityHidden(true)
        .overlay { codeField }
        .onChange(of: model.code) { _, code in if code != codeText { codeText = code } }
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

    /// The found trip: name, "Code found", where to and who is in, the meeting point and stops, and what the map shows.
    private func tripCard(_ preview: TripPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Code found", systemImage: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.ikutPositive)
                .padding(.horizontal, Spacing.chipX)
                .padding(.vertical, Spacing.xs)
                .background(Color.ikutPositive.opacity(0.14), in: Capsule())
            Text(preview.name)
                .font(.title3.weight(.semibold))
                .padding(.top, Spacing.xs)
            Text(JoinSteps.toLine(preview)).font(.subheadline)
            if let line = model.ticketDrive?.line {
                Text(line).font(.footnote).foregroundStyle(.secondary).transition(.opacity)
            }
            if let meet = JoinSteps.meetLine(preview) {
                Text(meet).font(.subheadline)
            }
            Text("The map shows where the trip ends. Nobody’s start is shown.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, Spacing.xs)
        }
        .animation(.easeOut, value: model.ticketDrive)
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile(radius: Radius.control)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("joinTripCard")
    }

    // MARK: H4 Car

    private var carStep: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Which car are you in?")
                .font(.title2.bold())
                .padding(.top, Spacing.s)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(model.cars.enumerated()), id: \.element.id) { index, car in
                    if index > 0 { RowDivider() }
                    carRow(
                        name: car.name,
                        badge: CarBadge(number: car.number ?? index + 1, colorHex: car.color, size: 28),
                        detail: car.hasTracker ? "Location shared" : "No one sharing yet",
                        selected: model.selectedCar?.id == car.id
                    ) { model.select(car) }
                }
                if !model.cars.isEmpty { RowDivider() }
                carRow(
                    name: "My own car", badge: CarBadge(symbol: "plus", colorHex: "#8E8E93", size: 28),
                    detail: "Shares this car’s location", selected: model.selection == .newCar
                ) { model.selectNewCar() }
            }
            .surfaceTile(radius: Radius.control)

            if model.selection == .newCar {
                TextField("Car name", text: $model.newCarName)
                    .textInputAutocapitalization(.words)
                    .disabled(model.isJoining)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 46)
                    .surfaceTile(radius: Radius.control)
                    .accessibilityLabel("Car name")
                    .onChange(of: model.newCarName) { model.newCarNameDidEdit() }
            }

            if model.selectedCar != nil { shareRow }

            if let message = model.errorMessage {
                InlineNote(message, tone: .alert, inset: 0)
                    .accessibilityIdentifier("joinError")
            }
            if model.trackerTakenResult != nil {
                InlineNote(
                    "You’re in. Someone else is already sharing that car’s location, so your phone won’t.",
                    systemImage: "info.circle", inset: 0)
            }
        }
    }

    private func carRow(name: String, badge: CarBadge, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .wrapsAtAccessibilitySizes(lines: 2)
                    Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes()
                }
                Spacer(minLength: Spacing.s)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.ikutAccent)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isJoining)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// In someone else's car: share this car's location too (off when someone already does), or ride as the co-pilot.
    private var shareRow: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Toggle(isOn: $model.tracker) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Share this car’s location")
                    Text(model.selectedCarHasTracker
                         ? "Someone is already sharing this car’s location."
                         : "Keeps sharing with the screen off.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Color(.systemGreen))
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .disabled(model.isJoining)
            .surfaceTile(radius: Radius.control)
            if !model.tracker {
                InlineNote("You’re the co-pilot: call stops and report hazards for the driver.", inset: 0)
            }
        }
    }
}
