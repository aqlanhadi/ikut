import SwiftUI

/// Joining a trip as the content of Home's sheet (D58): the name (H1) and the location ask (H2) when this person still
/// needs them, then the code (H3) and which car (H4), one step at a time.
/// The sheet keeps one height for every step (`HomeSheet.joinHeight`); only the content changes. The map behind it
/// draws the found trip (Home's map, fed by `JoinStepper.mapInput`).
struct JoinSheet: View {
    @Environment(AuthModel.self) private var auth
    @Environment(LocationPermission.self) private var location
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var stepper: JoinStepper
    var onClose: () -> Void
    /// Joined: the trip, and whether this phone tracks its car (it shares, and nobody else had the car).
    var onJoined: (_ tripId: String, _ tracks: Bool) -> Void

    @State private var codeText: String
    @State private var showScanner = false
    @ScaledMetric(relativeTo: .title2) private var codeBoxSize: CGFloat = 26
    @FocusState private var codeFocused: Bool
    @FocusState private var nameFocused: Bool
    /// The name is being signed in, or iOS's location prompt is up.
    @State private var isWorking = false
    @State private var nameError: String?
    /// iOS was asked on the Join tap and refused: the line shows and the next tap joins as the co-pilot.
    @State private var refusedOnTap = false

    init(stepper: JoinStepper, onClose: @escaping () -> Void, onJoined: @escaping (_ tripId: String, _ tracks: Bool) -> Void) {
        self.stepper = stepper
        self.onClose = onClose
        self.onJoined = onJoined
        _codeText = State(initialValue: stepper.model.code)
    }

    private var model: JoinModel { stepper.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTopRow(title: stepper.title, subtitle: stepper.indicator, subtitleIdentifier: "joinStep") {
                if stepper.canGoBack {
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
                    case .name: nameStep
                    case .location: LocationAskContent().padding(.top, Spacing.m)
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
            focusForStep()
            // The lookup waits for the name step: the server wants a signed-in person.
            if stepper.step != .name { model.start() }
        }
        .onChange(of: stepper.step) { focusForStep() }
        .sheet(isPresented: $showScanner) {
            QRScannerView { codeText = $0 }
        }
        // The keyboard goes once the trip is found, so the card has the room.
        .onChange(of: model.preview != nil) { _, found in if found { codeFocused = false } }
    }

    private func focusForStep() {
        nameFocused = stepper.step == .name
        codeFocused = stepper.step == .code && model.code.isEmpty
    }

    private func goNext() {
        withAnimation(HomeSheet.motion(reduceMotion: reduceMotion)) { stepper.goNext() }
    }

    private func back() {
        withAnimation(HomeSheet.motion(reduceMotion: reduceMotion)) { _ = stepper.goBack() }
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        switch stepper.step {
        case .name:
            Button(action: submitName) {
                Group {
                    if isWorking { ProgressView().accessibilityLabel("Signing in") } else { Text("Get started") }
                }
                .barActionLabel()
            }
            .actionBarStyle(prominent: true)
            .disabled(!stepper.canContinue || isWorking)
            .accessibilityIdentifier("joinNameContinue")
            .sheetActionBar(sides: false)
            .padding(.bottom, PanelSheet.sideGap)
        case .location:
            Button(action: askLocation) {
                Group {
                    if isWorking { ProgressView().accessibilityLabel("Asking") } else { Text("Continue") }
                }
                .barActionLabel()
            }
            .actionBarStyle(prominent: true)
            .disabled(isWorking)
            .accessibilityIdentifier("joinLocationContinue")
            .sheetActionBar(sides: false)
            Button("Not now") { goNext() }
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(isWorking)
                .accessibilityIdentifier("joinLocationSkip")
                .padding(.bottom, PanelSheet.sideGap)
        case .code:
            if stepper.canContinue {
                Button { goNext() } label: {
                    Text("Continue").barActionLabel()
                }
                .actionBarStyle(prominent: true)
                .accessibilityIdentifier("joinContinue")
                .sheetActionBar(sides: false)
                .padding(.bottom, PanelSheet.sideGap)
            }
        case .car:
            if let taken = model.trackerTakenResult {
                Button { onJoined(taken.tripId, false) } label: { Text("Continue").barActionLabel() }
                    .actionBarStyle(prominent: true)
                    .accessibilityIdentifier("joinContinue")
                    .sheetActionBar(sides: false)
                    .padding(.bottom, PanelSheet.sideGap)
            } else {
                if let line = locationOffLine {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                        Button("Open Settings") { location.openSettings() }
                            .font(.footnote.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("joinLocationOff")
                }
                if JoinSteps.sharing(selectedCar: model.selectedCar, ownCar: model.selection == .newCar) != .none { sharingRow }
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

    /// Signs in with the name, then on to the next step.
    private func submitName() {
        guard stepper.canContinue, !isWorking else { return }
        isWorking = true
        nameError = nil
        Task {
            do {
                try await auth.signInAsGuest(name: model.displayName)
                isWorking = false
                goNext()
            } catch {
                nameError = error.localizedDescription
                isWorking = false
            }
        }
    }

    /// Leads into iOS's own prompt (and the full-accuracy one when the person chose approximate); whatever the answer,
    /// the sheet goes on. Joining to share is checked again on Join (`join`), which asks iOS once more if it can.
    private func askLocation() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            if await location.requestWhenInUse() != .denied { _ = await location.requestFullAccuracy() }
            isWorking = false
            goNext()
        }
    }

    // MARK: H1 Name

    private var nameStep: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Drive together. Arrive together.")
                .font(.title3).foregroundStyle(.secondary)
                .padding(.top, Spacing.s)
            NameFieldCard(name: $model.displayName, focused: $nameFocused, disabled: isWorking, onSubmit: submitName)
            Text("What the convoy sees in new trips. Joining needs only a name, no account.")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, Spacing.s)
            if let nameError {
                InlineNote(nameError, tone: .alert, inset: 0)
                    .padding(.top, Spacing.s)
                    .accessibilityIdentifier("nameError")
            }
        }
        .onChange(of: model.displayName) { nameError = nil }
    }

    private var firstName: String { (try? DisplayName.validate(model.displayName).get()) ?? model.displayName }

    private var joinLabel: String {
        JoinSteps.joinLabel(car: model.selectedCar, ownCar: model.selection == .newCar, firstName: firstName,
                            coPilot: locationOffLine != nil)
    }

    private var wantsToShare: Bool { model.selection == .newCar || model.tracker }

    /// Sharing wanted needs location: ask iOS on this tap. Refused on this tap: stay here with the line and the button
    /// saying Join as co-pilot, and the next tap joins. Already denied before the tap: the line was showing, so it joins.
    private func join() {
        Task {
            let lineShown = locationOffLine != nil
            var status = location.status
            if wantsToShare, status == .notDetermined { status = await location.requestWhenInUse() }
            let decision = JoinSteps.tracker(wantsToShare: wantsToShare, authorization: status)
            if decision.note != nil, !lineShown {
                refusedOnTap = true
                return
            }
            refusedOnTap = false
            if let result = await model.join(sharing: decision.tracker) { onJoined(result.tripId, decision.tracker && model.tracker) }
        }
    }

    /// The co-pilot line: while sharing is wanted and location is not allowed, after a refusal on the tap or when iOS
    /// already said no. Allowing it in Settings turns it off again (the status refreshes when the app comes back).
    private var locationOffLine: String? {
        let decision = JoinSteps.tracker(wantsToShare: wantsToShare, authorization: location.status)
        guard refusedOnTap || location.status == .denied else { return nil }
        return decision.note
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
            Text(JoinSteps.mapCaption(preview))
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

    /// Pinned above Join, so it is on screen whatever the list's scroll: what this phone will share. In someone else's car
    /// a switch (off when someone already shares, where the person rides as the co-pilot); in my own car a plain line.
    @ViewBuilder private var sharingRow: some View {
        @Bindable var model = model
        switch JoinSteps.sharing(selectedCar: model.selectedCar, ownCar: model.selection == .newCar) {
        case .none:
            EmptyView()
        case .ownCar:
            Label("Your phone shares this car’s location, even with the screen off.", systemImage: "location.fill")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.s)
                .accessibilityIdentifier("joinShareNote")
        case .switchRow:
            Toggle(isOn: $model.tracker) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Share this car’s location")
                    Text(model.tracker
                         ? "Keeps sharing with the screen off."
                         : "You’re the co-pilot: call stops and report hazards for the driver.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Color(.systemGreen))
            .disabled(model.isJoining)
            .accessibilityIdentifier("joinShare")
            .padding(.top, Spacing.s)
        }
    }
}
