import FirebaseAuth
import MapKit
import SwiftUI

/// The lobby's sheet sections: the banners, code, trip, stops, options and leaving, and the journey shown when the
/// driving sheet is pulled up. The lobby's list and the pulled-up driving sheet's list are made of the same ones.
extension LobbyView {
    // MARK: Tall: banners, code, options and leaving, as system Sections

    /// "Trip ended" / "You're no longer in this trip" with Back to trips as a row, and the paused banner (which stays
    /// our own tinted view in a clear row: a plain row would lose the warning colour and the Resume pill).
    @ViewBuilder var bannerSections: some View {
        switch LobbyContent.exitBanner(ended: session.isEnded, membershipLost: session.membershipLost || sampleLost, tripLoaded: model.trip != nil) {
        case .ended: bannerSection("Trip ended", systemImage: Symbol.finish)
        case .noLongerInTrip: bannerSection("You’re no longer in this trip", systemImage: Symbol.removedFromTrip)
        case nil: EmptyView()
        }
        if session.isPaused && !session.isEnded && !session.membershipLost {
            Section {
                PausedBanner(session: session, onError: { actionError = $0 }).lobbyRow()
            }
        }
    }

    func bannerSection(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Section {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(title)
            }
            .font(.headline)
            .accessibilityElement(children: .combine)
            Button(action: backToTrips) { Text("Back to trips").frame(maxWidth: .infinity) }
        }
    }

    /// The same two rows with nothing to touch or find: for laying out, out of sight, what the banner takes.
    func bannerMeasure(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Section {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.headline)
            .hidden()
            Text("Back to trips").frame(maxWidth: .infinity).hidden()
        }
    }

    /// The code large on its own row, Copy and QR code as rows under it, the explanation as the footer.
    func codeSection(_ code: String) -> some View {
        Section {
            Text(LobbyLogic.displayCode(code))
                .font(.ikutDisplay(scaled: codeSize, base: 36, cap: 1.5, weight: .bold, design: .monospaced))
                .kerning(5)
                // The code is one token that must stay on one line, so it shrinks rather than wraps.
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
            // Copy and QR code side by side in one row (stacked at accessibility sizes, where the labels need the width):
            // two rows of their own made the section a third taller.
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
                    HStack(spacing: Spacing.s) {
                        Image(systemName: copied ? Symbol.tick : Symbol.copy).accessibilityHidden(true)
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .ikutButton(.link)
                .sensoryFeedback(.success, trigger: copiedCount)
                .accessibilityIdentifier(AXID.Lobby.copyCode)
                Button { showQR = true } label: {
                    HStack(spacing: Spacing.s) {
                        Image(systemName: Symbol.qrCode).accessibilityHidden(true)
                        Text("QR code")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .ikutButton(.link)
                .accessibilityIdentifier(AXID.Lobby.showQR)
            }
        } header: {
            Text("Trip code")
        } footer: {
            Text("Anyone with the code can join until the trip ends")
        }
    }

    /// Keep screen on (a Toggle) and Pause or Resume sharing, for the phone that shares.
    @ViewBuilder var optionsSection: some View {
        if !isSample || sampleSharing || canPause {
            Section {
                if !isSample || sampleSharing {
                    Toggle("Keep screen on", isOn: Binding(
                        get: { stage.keepScreenOn }, set: { stage.keepScreenOn = $0 }))
                        .accessibilityIdentifier(AXID.Lobby.keepAwake)
                }
                if canPause {
                    listOption(
                        session.isPaused ? "Resume sharing" : "Pause sharing", systemImage: session.isPaused ? Symbol.play : Symbol.pause,
                        id: session.isPaused ? AXID.Lobby.resume : AXID.Lobby.pause
                    ) { run { session.isPaused ? try await session.resumeSharing() : try await session.pauseSharing() } }
                }
            }
        }
    }

    /// End trip (the organiser) and Leave trip as destructive rows, each behind its confirmation.
    @ViewBuilder var exitSection: some View {
        if canEnd || canLeaveTrip {
            Section {
                if canEnd {
                    listOption("End trip", systemImage: Symbol.finish, id: AXID.Lobby.endTrip, destructive: true) { confirmEnd = true }
                }
                if canLeaveTrip {
                    listOption("Leave trip", systemImage: Symbol.leaveTrip, id: AXID.Lobby.leaveTrip, destructive: true) {
                        confirmLeave = true
                    }
                }
            }
        }
    }

    func listOption(_ title: LocalizedStringKey, systemImage: String, id: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage).accessibilityHidden(true)
                Text(title)
            }
        }
        .foregroundStyle(destructive ? Color.red : Color.primary)
        .disabled(isWorking)
        .accessibilityIdentifier(id)
    }

    // MARK: Tall: the trip

    /// The Trip section of the lobby's list: Name (the organizer taps to rename) and Destination (the organizer taps to
    /// change it; a participant reads it), as system rows.
    func tripSection(_ trip: Trip) -> some View {
        Section {
            systemTripRow("Name", value: trip.name, tappable: canEdit, id: AXID.Lobby.rename, hint: "Rename") {
                renameText = trip.name
                renaming = true
            }
            systemTripRow("Destination", value: trip.destination.name, tappable: canChangeDestination, id: AXID.Lobby.destination, hint: "Change destination") {
                showChangeDestination = true
            }
        } header: {
            Text("Trip")
        }
    }

    @ViewBuilder func systemTripRow(_ title: LocalizedStringKey, value: String, tappable: Bool, id: String, hint: String = "", action: @escaping () -> Void) -> some View {
        if tappable {
            Button(action: action) {
                LabeledContent(title) {
                    HStack(spacing: Spacing.s) {
                        Text(value)
                        Image(systemName: Symbol.forward).font(.footnote.weight(.semibold)).accessibilityHidden(true)
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

    // MARK: Tall: the stops

    /// The stops as shown: the organizer's own edits while they are being built, else what the trip says.
    var shownStops: [StopDraft] {
        canEditStops ? planner.items : model.stops.sorted { $0.order < $1.order }.map(StopDraft.init)
    }

    var failure: StopPlanner.Failure? {
        if case .failed(let failure) = planner.status, canEditStops { return failure }
        return nil
    }

    /// Whether the lobby shows a Stops section at all: the organizer always, a participant once there is a stop.
    var showsStops: Bool { canEditStops || !shownStops.isEmpty }

    /// The Stops section of the lobby's list: the meeting point first, the stops numbered as on the map, then (the
    /// organizer, before the start) Add a stop and Suggest stops, and the route's total, all as system rows. Reorder
    /// (`onMove`) and swipe to remove work on the rows as before.
    func stopsSection(_ trip: Trip) -> some View {
        let stops = shownStops
        let texts = LobbyContent.stopTexts(stops, routeLength: routeLength, routeSeconds: trip.routeSeconds ?? routeInfo.travelTime)
        return Section {
            if stops.isEmpty {
                Text("No stops yet. Add one for fuel, food or a place to meet.")
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop, text: texts[index], index: index, stops: stops)
            }
            .onMove(perform: canEditStops ? { planner.move(from: $0, to: $1) } : nil)
            if let failure, failure.place.stopId == nil {
                StopNote(
                    tone: .failure,
                    title: StopNoteText.failureTitle(failure, stopName: nil, destinationName: trip.destination.name),
                    detail: StopNoteText.failureDetail(failure), retry: { planner.retry() })
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
            }
            if planner.queued && canEditStops {
                StopNote(tone: .warning, title: StopNoteText.queuedTitle, detail: StopNoteText.queuedDetail)
                    .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.m, bottom: Spacing.xs, trailing: Spacing.m))
            }
            if canEditStops {
                stopAction("Add a stop", systemImage: Symbol.add, caption: nil, id: AXID.Stops.add) { openAddStop() }
                    .disabled(!StopListLogic.canAdd(among: stops))
                stopAction(
                    "Suggest stops", systemImage: Symbol.suggest,
                    caption: LobbyContent.suggestCaption(routeSeconds: trip.routeSeconds ?? routeInfo.travelTime), id: AXID.Stops.suggest
                ) { showSuggestStops = true }
            }
            if isOrganizer {
                routeTotal(trip, stops: stops)
            }
        } header: {
            stopsHeader(stops)
        }
    }

    /// "Stops", with the spinner while the route updates or the reorder hint beside it.
    func stopsHeader(_ stops: [StopDraft]) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout())
        return layout {
            Text("Stops").accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
            if planner.isBuilding && canEditStops {
                ProgressView().controlSize(.small).accessibilityLabel("Updating the route")
                    .transition(.opacity)
            } else if canEditStops, stops.count > 1 {
                Text("Hold and drag to reorder").textCase(nil)
                    .transition(.opacity)
            }
        }
        .animation(Motion.quick(reduceMotion: reduceMotion), value: planner.isBuilding)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: stops.count > 1)
    }

    func stopAction(_ title: LocalizedStringKey, systemImage: String, caption: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .ikutGlyph(14, weight: .semibold, cap: 1.3)
                    .iconFrame(.regular)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: Spacing.s)
                if let caption {
                    Text(caption).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                }
            }
        }
        .foregroundStyle(Color.ikutAccent)
        .accessibilityIdentifier(id)
    }

    // MARK: Driving, pulled up (canvas row L)

    /// A Pause, Resume, Leave or End that didn't go through says so in a section of its own, above the options.
    @ViewBuilder var actionErrorSection: some View {
        if let actionError {
            Section {
                InlineNote(.verbatim(actionError), tone: .alert).lobbyRow(top: Spacing.m)
            }
        }
    }

    /// What continues below the convoy when the driving sheet is pulled up: the journey, the code, the trip, the
    /// options and Leave or End (`LobbyContent.pulledUp`), as the same system sections the lobby's list is made of.
    /// They go into the driving sheet's own `List` (`TripMapView.panelSheet`), under the convoy panel.
    @ViewBuilder func pulledUpSections(here: LobbyContent.JourneyHere?) -> some View {
        if let trip = model.trip {
            ForEach(LobbyContent.pulledUp(rows), id: \.self) { section in
                switch section {
                case .journey: journeySection(trip, here: here)
                case .code: codeSection(trip.code)
                case .trip: tripSection(trip)
                case .options:
                    actionErrorSection
                    optionsSection
                case .exit: exitSection
                }
            }
        }
    }

    var pulledUp: PulledUpSheet {
        PulledUpSheet(sections: { AnyView(pulledUpSections(here: $0)) }, asks: pulledUpAsks)
    }

    /// What presents from inside the convoy sheet, which stays pulled up when one is cancelled: the QR code, the Leave and
    /// End confirmations and the rename, put on the sheet's list.
    func pulledUpAsks(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .sheet(isPresented: $showQR) { if let code = model.trip?.code { QRCodeSheet(code: code) } }
                .tripExitDialogs(confirmLeave: $confirmLeave, confirmEnd: $confirmEnd, leave: leaveTrip, end: endTrip)
                .alert("Trip name", isPresented: $renaming) { renameActions })
    }

    /// The stops still ahead, numbered as on the map with "About … in", under one line for what is already driven
    /// ("Passed R&R Bidor · 12:31", "Left 12:05").
    func journeySection(_ trip: Trip, here: LobbyContent.JourneyHere?) -> some View {
        let journey = LobbyContent.journey(
            model.stops, routeLength: routeLength, routeSeconds: trip.routeSeconds ?? routeInfo.travelTime,
            departedAt: trip.startedAt ?? trip.createdAt, here: here)
        let stops = model.stops.map(StopDraft.init)
        return Section {
            if let behind = journey.behind {
                Label(behind, systemImage: Symbol.tickCircle)
                    .font(.subheadline)
                    .foregroundStyle(Color.surfaceSecondary)
                    .accessibilityIdentifier(AXID.Trip.journeyBehind)
            }
            ForEach(journey.ahead) { text in
                if let stop = stops.first(where: { $0.id == text.id }) {
                    StopRow(stop: stop, text: text, editable: false, turnBack: nil, failure: nil, failed: false, onRetry: {})
                }
            }
            if journey.ahead.isEmpty {
                Text("No more stops before \(trip.destination.name)")
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
        } header: {
            Text("Journey")
        }
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

    /// Driving with this person no longer in the trip: the lobby's banner section, with Back to trips, on top of the
    /// convoy sheet (there is no other way Home mid-trip, #403).
    var drivingBanner: DrivingBanner? {
        LobbyContent.drivingBanner(
            ended: session.isEnded, membershipLost: session.membershipLost || sampleLost, tripLoaded: model.trip != nil)
            .map { _ in
                DrivingBanner(
                    rows: AnyView(bannerSection("You’re no longer in this trip", systemImage: Symbol.removedFromTrip)),
                    measure: AnyView(bannerMeasure("You’re no longer in this trip", systemImage: Symbol.removedFromTrip)))
            }
    }

    @ViewBuilder
    func stopRow(_ stop: StopDraft, text: LobbyContent.StopText, index: Int, stops: [StopDraft]) -> some View {
        let failedHere = failure?.place == .stop(stop.id)
        StopRow(
            stop: stop, text: text, editable: canEditStops,
            turnBack: canEditStops && !planner.isBuilding ? planner.turnBacks[stop.id] : nil,
            failure: failedHere ? failure : nil, failed: failedHere, onRetry: { planner.retry() })
            .contentShape(Rectangle())
            .onTapGesture { flyTo(stop.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows it on the map")
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if canEditStops {
                    Button(role: .destructive) { removeStop(stop.id) } label: {
                        Label("Remove", systemImage: Symbol.delete)
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
