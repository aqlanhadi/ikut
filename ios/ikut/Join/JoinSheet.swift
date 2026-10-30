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
            SheetTopRow(title: .verbatim(stepper.title), subtitle: .verbatim(stepper.indicator), subtitleIdentifier: AXID.Join.step) {
                if stepper.canGoBack {
                    RoundGlassIconButton(systemImage: Symbol.back, label: "Back", action: back)
                        .accessibilityIdentifier(AXID.Join.back).disabled(model.isJoining)
                }
            } trailing: {
                RoundGlassIconButton(systemImage: Symbol.close, label: "Close", action: onClose)
                    .accessibilityIdentifier(AXID.Sheet.close).disabled(model.isJoining)
            }
            .padding(.top, Spacing.xs)
            .padding(.horizontal, Spacing.l)

            // The steps that are rows are one system list on the sheet's glass (D86); the location ask is its own
            // layout, so it stays a scroll view.
            Group {
                switch stepper.step {
                case .name:
                    stepList { nameStep }
                        .onChange(of: model.displayName) { nameError = nil }
                case .location:
                    ScrollView {
                        LocationAskContent().padding(.top, Spacing.m)
                            .padding(.horizontal, Spacing.l).padding(.bottom, Spacing.l)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                case .code: stepList { codeStep }
                case .car: stepList { carStep }
                }
            }
            .id(stepper.step)
            .transition(.opacity)

            bottomBar.padding(.horizontal, Spacing.l)
        }
        .animation(HomeSheet.motion(reduceMotion: reduceMotion), value: stepper.step)
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
        .buttonSurface(.glass)
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

    private func stepList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        List { content() }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
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
                .font(.headline).frame(maxWidth: .infinity)
            }
            .ikutButton(.primary, tint: .ikutAccentFill)
            .disabled(!stepper.canContinue || isWorking)
            .accessibilityIdentifier(AXID.Join.nameContinue)
            .sheetActionBar(sides: false)
            .padding(.bottom, PanelSheet.sideGap)
        case .location:
            Button(action: askLocation) {
                Group {
                    if isWorking { ProgressView().accessibilityLabel("Asking") } else { Text("Continue") }
                }
                .font(.headline).frame(maxWidth: .infinity)
            }
            .ikutButton(.primary, tint: .ikutAccentFill)
            .disabled(isWorking)
            .accessibilityIdentifier(AXID.Join.locationContinue)
            .sheetActionBar(sides: false)
            Button("Not now") { goNext() }
                .font(.body.weight(.semibold))
                .ikutRow(fillWidth: true)
                .disabled(isWorking)
                .accessibilityIdentifier(AXID.Join.locationSkip)
                .padding(.bottom, PanelSheet.sideGap)
        case .code:
            if stepper.canContinue {
                Button { goNext() } label: {
                    Text("Continue").font(.headline).frame(maxWidth: .infinity)
                }
                .ikutButton(.primary, tint: .ikutAccentFill)
                .accessibilityIdentifier(AXID.Join.continueStep)
                .sheetActionBar(sides: false)
                .padding(.bottom, PanelSheet.sideGap)
            }
        case .car:
            if let taken = model.trackerTakenResult {
                Button { onJoined(taken.tripId, model.tracks) } label: { Text("Continue").font(.headline).frame(maxWidth: .infinity) }
                    .ikutButton(.primary, tint: .ikutAccentFill)
                    .accessibilityIdentifier(AXID.Join.continueStep)
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
                    .accessibilityIdentifier(AXID.Join.locationOff)
                }
                if JoinSteps.sharing(selectedCar: model.selectedCar, ownCar: model.selection == .newCar) != .none { sharingRow }
                Button(action: join) {
                    Group {
                        if model.isJoining {
                            ProgressView().accessibilityLabel("Joining trip")
                        } else {
                            Text(joinLabel).wrapsAtAccessibilitySizes().minimumScaleFactor(0.7)
                        }
                    }
                    .font(.headline).frame(maxWidth: .infinity)
                }
                .ikutButton(.primary, tint: .ikutAccentFill)
                .disabled(!stepper.canContinue || auth.userID == nil)
                .accessibilityIdentifier(AXID.Join.confirm)
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

    @ViewBuilder private var nameStep: some View {
        @Bindable var model = model
        Section {
            TextField("Your name", text: $model.displayName)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .focused($nameFocused)
                .disabled(isWorking)
                .accessibilityLabel("Your name")
                .accessibilityIdentifier(AXID.Name.field)
                .onSubmit(submitName)
        } header: {
            // The line and the caption share the header, so the field stays as high as it was above the keyboard.
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("Drive together. Arrive together.")
                    .font(.title3).foregroundStyle(.secondary).textCase(nil)
                Text("Your name").accessibilityHidden(true)
            }
        } footer: {
            Text("What the convoy sees in new trips. Joining needs only a name, no account.")
        }
        if let nameError {
            Section {
                InlineNote(.verbatim(nameError), tone: .alert, inset: 0)
                    .lobbyRow()
                    .accessibilityIdentifier(AXID.Name.error)
            }
        }
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
            if let result = await model.join(sharing: decision.tracker) { onJoined(result.tripId, model.tracks) }
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

    @ViewBuilder private var codeStep: some View {
        Section {
            codeBoxes.lobbyRow()
            if model.preview == nil { status.lobbyRow(top: Spacing.xs) }
        }
        if let preview = model.preview {
            Section { tripCard(preview) }
            Section {
                Button("Use a different code") {
                    codeText = ""
                    codeFocused = true
                }
            }
        } else if QRScannerView.isAvailable {
            Section {
                Button {
                    codeFocused = false
                    showScanner = true
                } label: {
                    HStack(spacing: Spacing.m) {
                        Image(systemName: Symbol.scanCode).accessibilityHidden(true)
                        Text("Scan QR code")
                    }
                }
                .accessibilityIdentifier(AXID.Join.scan)
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
                InlineNote(.verbatim(message), tone: .alert, inset: 0)
                    .accessibilityIdentifier(AXID.Join.error)
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
                    .font(.ikutDisplay(scaled: codeBoxSize, base: 26, cap: 1.4, weight: .semibold, design: .monospaced))
                    // One letter per box: it can't wrap, so it shrinks a little at the largest sizes.
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .ikutRow(fillWidth: true)
                    .surfaceTile(radius: Radius.inner)
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
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
            .accessibilityIdentifier(AXID.Join.codeField)
            .accessibilityValue(codeText)
            .onChange(of: codeText) {
                model.codeChanged(codeText)
                if codeText != model.code { codeText = model.code }
            }
    }

    /// The found trip: name, "Code found", where to and who is in, the meeting point and stops, and what the map shows.
    private func tripCard(_ preview: TripPreview) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Chip(text: "Code found", tone: .positive, lead: .symbol(Symbol.tick))
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
        .animation(Motion.line(reduceMotion: reduceMotion), value: model.ticketDrive)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Join.tripCard)
    }

    // MARK: H4 Car

    @ViewBuilder private var carStep: some View {
        @Bindable var model = model
        Section {
            ForEach(Array(model.cars.enumerated()), id: \.element.id) { index, car in
                carRow(
                    name: car.name,
                    badge: CarBadge(number: car.number ?? index + 1, colorHex: car.color, size: IconSize.small.base),
                    detail: car.hasTracker ? "Location shared" : "No one sharing yet",
                    selected: model.selectedCar?.id == car.id
                ) { model.select(car) }
            }
            carRow(
                name: "My own car", badge: CarBadge(symbol: Symbol.add, colorHex: "#8E8E93", size: IconSize.small.base),
                detail: "Shares this car’s location", selected: model.selection == .newCar
            ) { model.selectNewCar() }
        } header: {
            Text("Which car are you in?")
                .font(.title2.bold()).foregroundStyle(.primary).textCase(nil)
                .padding(.top, Spacing.s)
        }

        if model.selection == .newCar {
            Section {
                TextField("Car name", text: $model.newCarName)
                    .textInputAutocapitalization(.words)
                    .disabled(model.isJoining)
                    .accessibilityLabel("Car name")
                    .accessibilityIdentifier(AXID.Join.carNameField)
                    .onChange(of: model.newCarName) { model.newCarNameDidEdit() }
            }
        }

        if model.errorMessage != nil || model.trackerTakenResult != nil {
            Section {
                if let message = model.errorMessage {
                    InlineNote(.verbatim(message), tone: .alert, inset: 0)
                        .accessibilityIdentifier(AXID.Join.error)
                }
                if model.trackerTakenResult != nil {
                    InlineNote(
                        "You’re in. Someone else is already sharing that car’s location, so your phone won’t.",
                        systemImage: Symbol.info, inset: 0)
                }
            }
            .lobbyRow()
        }
    }

    private func carRow(name: String, badge: CarBadge, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                badge
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .wrapsAtAccessibilitySizes(lines: 2)
                    Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes()
                }
                Spacer(minLength: Spacing.s)
                if selected {
                    Image(systemName: Symbol.tick).font(.body.weight(.semibold)).foregroundStyle(Color.ikutAccent)
                        .accessibilityHidden(true)
                }
            }
        }
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
            Label("Your phone shares this car’s location, even with the screen off.", systemImage: Symbol.location)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Spacing.s)
                .accessibilityIdentifier(AXID.Join.shareNote)
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
            .accessibilityIdentifier(AXID.Join.share)
            .padding(.top, Spacing.s)
        }
    }
}
