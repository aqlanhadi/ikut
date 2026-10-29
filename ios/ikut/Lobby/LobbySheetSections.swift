import FirebaseAuth
import MapKit
import SwiftUI

/// The lobby's tall-sheet sections: the code card, trip rows, stops, options and leaving, and the journey
/// shown when the driving sheet is pulled up. Moved out of `LobbyView.swift` unchanged.
extension LobbyView {
    // MARK: Tall: the code

    func codeCard(_ code: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Text("Trip code").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
            Text(LobbyLogic.displayCode(code))
                .font(.ikutDisplay(scaled: codeSize, base: 36, cap: 1.5, weight: .bold, design: .monospaced))
                .kerning(5)
                // The code is one token that must stay on one line, so it shrinks rather than wraps.
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
            Text("Anyone with the code can join until the trip ends")
                .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .wrapsAtAccessibilitySizes(lines: 2)
            // Side by side at the usual sizes; stacked at accessibility sizes, where the labels need the width.
            let buttons = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.s)) : AnyLayout(HStackLayout(spacing: Spacing.s))
            buttons {
                Button {
                    UIPasteboard.general.string = code
                    copiedCount += 1
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .ikutButton(.link)
                .sensoryFeedback(.success, trigger: copiedCount)
                .accessibilityIdentifier("lobby.copyCode")
                Button { showQR = true } label: {
                    Label("QR code", systemImage: "qrcode").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .ikutButton(.link)
                .accessibilityIdentifier("lobby.showQR")
            }
            .padding(.top, Spacing.s)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity)
        .surfaceTile(radius: Radius.card)
    }

    // MARK: Tall: the trip

    /// The Trip section of the lobby's list: Name (the organizer taps to rename) and Destination (the organizer taps to
    /// change it; a participant reads it), as system rows.
    func tripSection(_ trip: Trip) -> some View {
        Section {
            systemTripRow("Name", value: trip.name, tappable: canEdit, id: "lobby.rename", hint: "Rename") {
                renameText = trip.name
                renaming = true
            }
            systemTripRow("Destination", value: trip.destination.name, tappable: canChangeDestination, id: "lobby.destination", hint: "Change destination") {
                showChangeDestination = true
            }
        } header: {
            Text("Trip")
        }
    }

    @ViewBuilder func systemTripRow(_ title: String, value: String, tappable: Bool, id: String, hint: String = "", action: @escaping () -> Void) -> some View {
        if tappable {
            Button(action: action) {
                LabeledContent(title) {
                    HStack(spacing: Spacing.s) {
                        Text(value)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                }
            }
            .foregroundStyle(Color.primary)
            .disabled(isWorking)
            .accessibilityHint(hint)
            .accessibilityIdentifier(id)
        } else {
            LabeledContent(title, value: value)
                .accessibilityElement(children: .combine)
        }
    }

    /// The same rows as cards, for the pulled-up driving sheet, which is still a ScrollView (D86: its own piece).
    @ViewBuilder func tripRows(_ trip: Trip) -> some View {
        sectionLabel("Trip").lobbyRow(top: Spacing.m)
        VStack(spacing: 0) {
            tripRow("Name", value: trip.name, tappable: canEdit, id: "lobby.rename", hint: "Rename") {
                renameText = trip.name
                renaming = true
            }
            RowDivider()
            tripRow("Destination", value: trip.destination.name, tappable: canChangeDestination, id: "lobby.destination", hint: "Change destination") {
                showChangeDestination = true
            }
        }
        .surfaceTile(radius: Radius.card)
        .lobbyRow()
    }

    @ViewBuilder func tripRow(_ title: String, value: String, tappable: Bool, id: String, hint: String = "", action: @escaping () -> Void) -> some View {
        let content = HStack(spacing: Spacing.s) {
            Text(title)
            Spacer(minLength: Spacing.s)
            Text(value).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes()
            if tappable {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.l)
        .ikutRow()
        .contentShape(Rectangle())
        if tappable {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .accessibilityHint(hint)
                .accessibilityIdentifier(id)
        } else {
            content.accessibilityElement(children: .combine)
        }
    }

    // MARK: Tall: the stops

    /// The stops as shown: the organizer's own edits while they are being built, else what the trip says.
    var shownStops: [StopDraft] {
        canEditStops ? planner.items : model.stops.sorted { $0.order < $1.order }.map(StopDraft.init)
    }

    var failure: StopPlanner.Failure? {
        if case .failed(let failure) = planner.status, canEditStops { return failure }
        return nil
    }

    /// The meeting point first, the stops numbered as on the map, then (the organizer, before the start) Add a stop and
    /// Suggest stops, and the route's total. Reorder and swipe to remove work on the rows as before.
    @ViewBuilder func stopsRows(_ trip: Trip) -> some View {
        let stops = shownStops
        let showStops = canEditStops || !stops.isEmpty
        let texts = LobbyContent.stopTexts(stops, routeLength: routeLength, routeSeconds: trip.routeSeconds ?? routeInfo.travelTime)
        if showStops {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout())
            layout {
                Text("Stops").font(.footnote.weight(.semibold)).accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                if planner.isBuilding && canEditStops {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating the route")
                        .transition(.opacity)
                } else if canEditStops, stops.count > 1 {
                    Text("Hold and drag to reorder").font(.footnote)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick(reduceMotion: reduceMotion), value: planner.isBuilding)
            .animation(Motion.quick(reduceMotion: reduceMotion), value: stops.count > 1)
            .foregroundStyle(Color.surfaceSecondary)
            .padding(.horizontal, Spacing.m)
            .lobbyRow(top: Spacing.m, bottom: Spacing.xs)

            if stops.isEmpty {
                Text("No stops yet. Add one for fuel, food or a place to meet.")
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                    .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
                    .cardSlice(top: true, bottom: !canEditStops)
                    .lobbyRow()
            }
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop, text: texts[index], index: index, stops: stops, lastOfCard: !isOrganizer && index == stops.count - 1)
            }
            .onMove(perform: canEditStops ? { planner.move(from: $0, to: $1) } : nil)
            if let failure, failure.place.stopId == nil {
                StopNote(
                    tone: .failure,
                    title: StopNoteText.failureTitle(failure, stopName: nil, destinationName: trip.destination.name),
                    detail: StopNoteText.failureDetail(failure), retry: { planner.retry() })
                    .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.s)
                    .cardSlice()
                    .lobbyRow()
            }
            if planner.queued && canEditStops {
                StopNote(tone: .warning, title: StopNoteText.queuedTitle, detail: StopNoteText.queuedDetail)
                    .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.s)
                    .cardSlice()
                    .lobbyRow()
            }
            if canEditStops {
                stopAction("Add a stop", systemImage: "plus", caption: nil, id: "stops.add") { openAddStop() }
                    .disabled(!StopListLogic.canAdd(among: stops))
                    .overlay(alignment: .top) { Divider() }
                    .cardSlice()
                    .lobbyRow()
                stopAction(
                    "Suggest stops", systemImage: "sparkles",
                    caption: LobbyContent.suggestCaption(routeSeconds: trip.routeSeconds ?? routeInfo.travelTime), id: "stops.suggest"
                ) { showSuggestStops = true }
                    .overlay(alignment: .top) { Divider() }
                    .cardSlice()
                    .lobbyRow()
            }
            if isOrganizer {
                routeTotal(trip, stops: stops)
                    .padding(.horizontal, Spacing.s)
                    .padding(.top, Spacing.xs).padding(.bottom, Spacing.s)
                    .cardSlice(bottom: true)
                    .lobbyRow()
            }
        }
    }

    func stopAction(_ title: String, systemImage: String, caption: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .ikutGlyph(14, weight: .semibold, cap: 1.3)
                    .foregroundStyle(Color.ikutAccent)
                    .iconFrame(.regular)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Color.ikutAccent)
                Spacer(minLength: Spacing.s)
                if let caption {
                    Text(caption).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                }
            }
            .padding(.horizontal, Spacing.l)
            .ikutRow()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Tall: options and leaving

    /// Keep screen on, Pause or Resume sharing, and at the very end Leave trip or End trip.
    @ViewBuilder var optionRows: some View {
        optionsTile.lobbyRow(top: Spacing.l)
        exitTile.lobbyRow(top: Spacing.m, bottom: Spacing.l)
    }

    /// Keep screen on, and Pause or Resume sharing for the phone that shares.
    @ViewBuilder var optionsTile: some View {
        if !isSample || sampleSharing || canPause {
            VStack(spacing: 0) {
                if !isSample || sampleSharing {
                    Toggle("Keep screen on", isOn: Binding(
                        get: { stage.keepScreenOn }, set: { stage.keepScreenOn = $0 }))
                        .padding(.horizontal, Spacing.l)
                        .ikutRow()
                        .accessibilityIdentifier("lobby.keepAwake")
                }
                if canPause {
                    if !isSample || sampleSharing { RowDivider() }
                    optionButton(
                        session.isPaused ? "Resume sharing" : "Pause sharing", systemImage: session.isPaused ? "play.fill" : "pause.fill",
                        id: session.isPaused ? "lobby.resume" : "lobby.pause"
                    ) { run { session.isPaused ? try await session.resumeSharing() : try await session.pauseSharing() } }
                }
            }
            .surfaceTile(radius: Radius.card)
        }
    }

    /// End trip (the organiser) and Leave trip, each behind its confirmation.
    @ViewBuilder var exitTile: some View {
        if canEnd || canLeaveTrip {
            VStack(spacing: 0) {
                if canEnd {
                    optionButton("End trip", systemImage: "flag.checkered", id: "lobby.endTrip", destructive: true) { confirmEnd = true }
                }
                if canEnd && canLeaveTrip { RowDivider() }
                if canLeaveTrip {
                    optionButton("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", id: "lobby.leaveTrip", destructive: true) {
                        confirmLeave = true
                    }
                }
            }
            .surfaceTile(radius: Radius.card)
        }
    }

    // MARK: Driving, pulled up (canvas row L)

    /// What continues below the convoy when the driving sheet is pulled up: the journey, the code, the trip, the
    /// options and Leave or End (`LobbyContent.pulledUp`). The same rows as the lobby's; Leave, End and rename present
    /// from inside the convoy sheet, which stays pulled up.
    @ViewBuilder func pulledUpContent(here: LobbyContent.JourneyHere?) -> some View {
        if let trip = model.trip {
            VStack(spacing: 0) {
                ForEach(LobbyContent.pulledUp(rows), id: \.self) { section in
                    switch section {
                    case .journey: journeyRows(trip, here: here).padding(.top, Spacing.l)
                    case .code: codeCard(trip.code).padding(.top, Spacing.l)
                    case .trip: VStack(spacing: 0) { tripRows(trip) }.padding(.top, Spacing.m)
                    case .options:
                        // A Pause, Resume, Leave or End that didn't go through says so here, above the rows.
                        if let actionError {
                            InlineNote(actionError, tone: .alert).padding(.top, Spacing.l)
                        }
                        optionsTile.padding(.top, actionError == nil ? Spacing.l : Spacing.m)
                    case .exit: exitTile.padding(.top, Spacing.m)
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
            .sheet(isPresented: $showQR) { QRCodeSheet(code: trip.code) }
            // Presented from inside the convoy sheet, which stays up pulled up: Cancel leaves it where it was.
            .tripExitDialogs(confirmLeave: $confirmLeave, confirmEnd: $confirmEnd, leave: leaveTrip, end: endTrip)
            .alert("Trip name", isPresented: $renaming) { renameActions }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trip.pulledUp")
        }
    }

    /// The stops still ahead, numbered as on the map with "About … in", under one line for what is already driven
    /// ("Passed R&R Bidor · 12:31", "Left 12:05").
    func journeyRows(_ trip: Trip, here: LobbyContent.JourneyHere?) -> some View {
        let journey = LobbyContent.journey(
            model.stops, routeLength: routeLength, routeSeconds: trip.routeSeconds ?? routeInfo.travelTime,
            departedAt: trip.startedAt ?? trip.createdAt, here: here)
        let stops = model.stops.map(StopDraft.init)
        return VStack(spacing: 0) {
            sectionLabel("Journey")
            VStack(spacing: 0) {
                if let behind = journey.behind {
                    Label(behind, systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.surfaceSecondary)
                        .ikutRow(fillWidth: true, alignment: .leading)
                        .padding(.horizontal, Spacing.l)
                        .accessibilityIdentifier("trip.journey.behind")
                }
                ForEach(Array(journey.ahead.enumerated()), id: \.element.id) { index, text in
                    if let stop = stops.first(where: { $0.id == text.id }) {
                        StopRow(stop: stop, text: text, editable: false, first: index == 0 && journey.behind == nil,
                                turnBack: nil, failure: nil, failed: false, onRetry: {})
                    }
                }
                if journey.ahead.isEmpty {
                    Text("No more stops before \(trip.destination.name)")
                        .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                        .ikutRow(fillWidth: true, alignment: .leading)
                        .padding(.horizontal, Spacing.l)
                        .overlay(alignment: .top) { if journey.behind != nil { Divider() } }
                }
            }
            .surfaceTile(radius: Radius.card)
        }
    }

    func optionButton(
        _ title: String, systemImage: String, id: String, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .ikutRow(fillWidth: true, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier(id)
    }

    func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        actionError = nil
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
            isWorking = false
        }
    }

    @ViewBuilder
    var statusBanner: some View {
        switch LobbyContent.exitBanner(ended: session.isEnded, membershipLost: session.membershipLost, tripLoaded: model.trip != nil) {
        case .ended: exitBanner("Trip ended", systemImage: "flag.checkered")
        case .noLongerInTrip: noLongerInTripBanner
        case nil: EmptyView()
        }
        // Trip in progress and since when, and this phone sharing before the start (#394), are the header's subtitle.
    }

    var noLongerInTripBanner: some View {
        exitBanner("You’re no longer in this trip", systemImage: "person.fill.xmark")
    }

    /// Driving with this person no longer in the trip: the same banner, with Back to trips, on top of the convoy sheet
    /// (there is no other way Home mid-trip, #403).
    var drivingBanner: AnyView? {
        LobbyContent.drivingBanner(
            ended: session.isEnded, membershipLost: session.membershipLost || sampleLost, tripLoaded: model.trip != nil)
            .map { _ in AnyView(noLongerInTripBanner) }
    }

    func exitBanner(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Spacing.m) {
            Label(title, systemImage: systemImage).font(.headline)
            Button(action: backToTrips) { Text("Back to trips").frame(maxWidth: .infinity) }.ikutButton(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .surfaceTile(radius: Radius.card)
        .padding(.bottom, Spacing.s)
    }

    @ViewBuilder
    func stopRow(_ stop: StopDraft, text: LobbyContent.StopText, index: Int, stops: [StopDraft], lastOfCard: Bool) -> some View {
        let failedHere = failure?.place == .stop(stop.id)
        StopRow(
            stop: stop, text: text, editable: canEditStops, first: index == 0,
            turnBack: canEditStops && !planner.isBuilding ? planner.turnBacks[stop.id] : nil,
            failure: failedHere ? failure : nil, failed: failedHere, onRetry: { planner.retry() })
            .contentShape(Rectangle())
            .onTapGesture { flyTo(stop.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows it on the map")
            .cardSlice(top: index == 0, bottom: lastOfCard)
            .lobbyRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if canEditStops {
                    Button(role: .destructive) { removeStop(stop.id) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            .accessibilityActions {
                if canEditStops {
                    if index > 0 {
                        Button("Move up") { moveStop(from: index, to: index - 1) }
                    }
                    if index < stops.count - 1 {
                        Button("Move down") { moveStop(from: index, to: index + 2) }
                    }
                    Button("Remove") { removeStop(stop.id) }
                }
            }
    }

    /// "205 km · 2 h 40 + 35 min of stops" (or "Route not ready" while a stop has no road).
    @ViewBuilder
    func routeTotal(_ trip: Trip, stops: [StopDraft]) -> some View {
        if failure != nil {
            RouteTotalLine(content: .notReady)
        } else if !isOrganizer, case .distanceOnly(let distance) = ownWay.totalState {
            RouteTotalLine(content: .total(RouteFormat.distance(distance), caption: "No drive time yet"))
        } else if !isOrganizer, case .unknown = ownWay.totalState {
            RouteTotalLine(content: .pending("Shows once your car shares where it is"))
        } else if let distance = isOrganizer ? routeInfo.distance : ownWay.distance,
            let seconds = isOrganizer ? routeInfo.travelTime : ownWay.drive?.travelTime
        {
            let road = isOrganizer ? routeInfo.roadName : ownWay.drive?.roadName
            let caption = StopListLogic.plannedMinutes(stops) > 0
                ? "Drive time and planned stops"
                : (stops.isEmpty ? (road.flatMap { $0.isEmpty ? nil : "via \($0)" } ?? "Drive time") : "Drive time")
            RouteTotalLine(
                content: .total(
                    StopFormat.total(distance: distance, driveSeconds: seconds, stopMinutes: StopListLogic.plannedMinutes(stops)),
                    caption: caption),
                dimmed: planner.isBuilding && canEditStops)
        } else {
            RouteTotalLine(content: .loading)
        }
    }
}
