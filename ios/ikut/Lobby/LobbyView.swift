import FirebaseAuth
import MapKit
import SwiftUI

/// Shown after creating or joining a trip (CreateTrip.dc.html): the route card, join code with
/// QR and share, and the live list of cars.
struct LobbyView: View {
    let onExit: () -> Void
    /// The trip ended (by the organizer or the server): show the recap.
    var onEnded: (String) -> Void = { _ in }
    @Environment(LocationPermission.self) private var location
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var codeSize: CGFloat = 30
    @State private var model: LobbyModel
    @State private var session: TripSession
    @State private var routeInfo = TripRouteInfo()
    // The same switch the map applies (TripMapView): the lobby is where it moved to.
    @AppStorage("ikut.map.keepAwake") private var keepAwake = false
    @AppStorage("ikut.map.keepAwakeAnswered") private var keepAwakeAnswered = false
    /// A participant's own trip: their start, where they join, their distance and drive time (D26).
    @State private var ownWay = OwnWayInfo()
    @State private var planner: StopPlanner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAddStop = false
    @State private var showSuggestStops = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showChangeDestination = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var showMap = false
    /// The lobby is on screen (not popped): the sheet is presented from it, so it goes with it.
    @State private var onScreen = false
    /// The lobby's sheet is up (it reports its own appear and dismiss); what else is presented waits for it to go.
    @State private var sheetUp = false
    /// The sheet is at its tall detent.
    @State private var expanded = false
    @State private var mapCommand = LobbyMapCommand()
    @ScaledMetric(relativeTo: .body) private var mediumHeight: CGFloat = LobbySheet.compactHeight
    @State private var sheetSafeBottom: CGFloat = 0
    /// This phone opened the map; covers the gap before the startedAt write comes back.
    @State private var startedHere = false
    /// Shows `model` as given: nothing is loaded, started or remembered.
    private var isSample = false
    /// In a sample lobby: whether to show the organizer's card.
    private var sampleOrganizer = true
    /// The car colour a sample participant's own route is drawn in.
    private let sampleCarColor = "#D9480F"

    init(tripId: String, onExit: @escaping () -> Void, onEnded: @escaping (String) -> Void = { _ in }) {
        self.onExit = onExit
        self.onEnded = onEnded
        _model = State(initialValue: LobbyModel(tripId: tripId))
        _session = State(initialValue: TripSession(
            tripId: tripId, userId: Auth.auth().currentUser?.uid ?? ""))
        _planner = State(initialValue: StopPlanner { plan in try await TripService.saveStops(tripId: tripId, plan: plan) })
    }

    #if DEBUG
    /// A lobby on sample data, for previews.
    init(sample model: LobbyModel) {
        onExit = {}
        _model = State(initialValue: model)
        _session = State(initialValue: TripSession(tripId: model.tripId, userId: ""))
        _planner = State(initialValue: StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in }))
        isSample = true
    }

    /// A lobby on sample data with the planner in a given state, for previews and screenshots: `organizer` shows the
    /// organizer's card (editable) rather than a member's.
    init(sample model: LobbyModel, planner: StopPlanner, organizer: Bool, ownWay: OwnWayInfo? = nil) {
        self.init(sample: model)
        _planner = State(initialValue: planner)
        sampleOrganizer = organizer
        if let ownWay { _ownWay = State(initialValue: ownWay) }
    }
    #endif

    private var isOrganizer: Bool {
        if isSample { return sampleOrganizer }
        guard let trip = model.trip else { return false }
        return trip.organizerId == Auth.auth().currentUser?.uid
    }

    /// Started by anyone (trip doc / cars), or by this phone a moment ago.
    private var isStarted: Bool {
        !session.isEnded && (LobbyLogic.isStarted(trip: model.trip) || startedHere)
    }

    /// Organiser: Start trip. Participant: a plain waiting line until the trip starts, then Show map (D39).
    @ViewBuilder private var bottomBar: some View {
        let bar = LobbyLogic.bottomBar(
            isOrganizer: isOrganizer, tripLoaded: model.trip != nil, isMember: !session.membershipLost,
            started: isStarted, ended: session.isEnded || model.trip?.status == .ended,
            organizerName: LobbyLogic.organizerName(trip: model.trip, members: model.members))
        ZStack { barContent(bar) }
            .animation(Motion.quick(reduceMotion: reduceMotion), value: bar)
    }

    /// How far the bar's button hangs into the sheet's bottom safe area (`PanelSheet.barLift`).
    private var barLift: CGFloat { PanelSheet.barLift(safeBottom: sheetSafeBottom) }

    @ViewBuilder private func barContent(_ bar: LobbyLogic.BottomBar) -> some View {
        switch bar {
        case .none:
            EmptyView()
        case .waiting:
            Text(bar.label)
                .font(.subheadline)
                .foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .accessibilityIdentifier("lobbyWaiting")
                .sheetActionBar(lift: barLift)
                .transition(.opacity)
        case .startTrip, .showMap:
            Button {
                if bar == .startTrip {
                    startedHere = true
                    Task { await TripService.markStarted(tripId: model.tripId) }
                }
                showMap = true
            } label: {
                Text(bar.label).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
            }
            .actionBarStyle(prominent: true)
            .sheetActionBar(lift: barLift)
            .transition(.opacity)
        }
    }

    /// Stop edits run in the banner motion, so the List slides the rows around an inserted, removed or moved one.
    /// (A drag to reorder is animated by the List itself.)
    private func addStop(_ place: StopDraft) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { planner.add(place) }
    }
    private func removeStop(_ id: String) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { planner.remove(id: id) }
    }
    private func moveStop(from index: Int, to destination: Int) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) {
            planner.move(from: IndexSet(integer: index), to: destination)
        }
    }

    private var currentUserId: String? { Auth.auth().currentUser?.uid }

    /// Remembers this trip for Home's past list, with who else is in it once the members have loaded.
    private func recordPastTrip() {
        guard !isSample, let trip = model.trip else { return }
        let names = model.members.keyedByID { $0.displayName }
        PastTrips.record(tripId: model.tripId, name: trip.name, destination: trip.destination.name, endedAt: trip.endedAt,
                         others: names.isEmpty ? nil : PastTrips.others(from: names, excluding: currentUserId))
    }

    /// Hands the planner what Firestore says about the trip and its stops.
    private func syncPlanner() {
        guard !isSample else { return }
        planner.sync(trip: model.trip, stops: model.stops)
    }

    private var canLeave: Bool { session.isLiveMember }
    /// The Leave trip menu item: not the organizer before the start (they can only End it).
    private var canLeaveTrip: Bool {
        LobbyLogic.canLeaveTrip(isOrganizer: isOrganizer, started: isStarted, isLiveMember: canLeave)
    }
    private var canEnd: Bool { isOrganizer && !session.isEnded }
    /// Rename and change destination: the organizer, before the trip ends.
    private var canEdit: Bool { isOrganizer && canLeave }
    /// Change destination: the organizer, until the trip ends (mid-trip it rebuilds the route from where they are).
    private var canChangeDestination: Bool {
        LobbyLogic.canChangeDestination(canEdit: canEdit)
    }
    /// Add, move and remove stops: the organizer, before the trip has started.
    private var canEditStops: Bool { canEdit && !isStarted }

    /// "Kuala Lumpur to Ipoh · 205 km · 2 h 25 min", the line under the Suggest stops title.
    private var suggestSummary: String {
        var parts = [[routeInfo.originName, model.trip?.destination.name].compactMap { $0 }.joined(separator: " to ")]
        if let distance = routeInfo.distance { parts.append(RouteFormat.distance(distance)) }
        if let seconds = routeInfo.travelTime { parts.append(ConvoyFormat.duration(seconds)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Pause and resume are for the phone that is broadcasting (or paused while it was).
    private var canPause: Bool { (session.isTracking || session.isPaused) && canLeave }

    private var cover: LobbySheet.Cover {
        LobbySheet.Cover(
            tripMap: showMap, changeDestination: showChangeDestination, addStop: showAddStop,
            suggestStops: showSuggestStops, renaming: renaming, alwaysExplainer: session.alwaysExplainerShowing,
            confirmLeave: confirmLeave, confirmEnd: confirmEnd)
    }
    private var sheetCovered: Bool { LobbySheet.isCovered(cover, lobbyOnScreen: onScreen) }
    private var compact: CGFloat { LobbySheet.compact(scaled: mediumHeight) }

    /// What the sheet's content change runs on, and what a stop tap's camera flight uses.
    private func flyTo(_ stopId: String) {
        mapCommand = mapCommand.asking(.stop(stopId))
        // The map is behind the sheet when it is tall: bring it down to the medium detent to show the stop.
        if expanded { withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { expanded = false } }
    }

    private var mapPins: [LobbyPin] {
        let trip = model.trip
        return LobbyMapLogic.pins(
            stops: shownStops, destinationName: trip?.destination.name, destination: trip?.destination.coordinate.coordinate,
            isOrganizer: isOrganizer, ownJoin: ownWay.joinCoordinate)
    }

    var body: some View {
        LobbyMapView(
            route: routeInfo.coordinates, pins: mapPins, ownRoute: isOrganizer ? [] : ownWay.ownRoute,
            ownColorHex: ownCarColor, sheetCompact: compact, command: $mapCommand)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .sheet(isPresented: Binding(get: { !sheetCovered }, set: { _ in }), onDismiss: { sheetUp = false }) {
                sheetContent.onAppear { sheetUp = true }
            }
        .navigationDestination(isPresented: $showMap) {
            TripMapView(session: session, onExit: onExit, onEnded: { onEnded(model.tripId) })
        }
        .navigationDestination(isPresented: $showChangeDestination) {
            CreateTripView(
                changingTripId: model.trip?.id, keepingStops: planner.items,
                midTrip: LobbyLogic.isStarted(trip: model.trip) ? { [session] in try await session.rebuilder.changeDestination(to: $0) } : nil
            ) { _ in showChangeDestination = false }
        }
        .navigationTitle(LobbyLogic.title(started: isStarted, ended: session.isEnded))
        .lobbySubtitle(
            title: LobbyLogic.title(started: isStarted, ended: session.isEnded),
            subtitle: isStarted ? LobbyLogic.sinceLine(startedAt: model.trip?.startedAt ?? model.trip?.createdAt) : nil)
        .onChange(of: session.isEnded, initial: true) { _, ended in
            if ended { onEnded(model.tripId) }
        }
        .onChange(of: model.trip, initial: true) { _, _ in
            recordPastTrip()
            syncPlanner()
        }
        .onChange(of: model.stops) { _, _ in syncPlanner() }
        .sheet(isPresented: Binding(
            get: { BottomSheet.presents(wanted: showAddStop, sheetUp: sheetUp) }, set: { showAddStop = $0 })) {
            AddStopSheet(
                along: routeInfo.coordinates.count > 1
                    ? AlongRoute(coordinates: routeInfo.coordinates, seconds: routeInfo.travelTime) : nil,
                canMeet: StopListLogic.canMeet(among: planner.items),
                onAdd: { addStop($0) })
        }
        .sheet(isPresented: Binding(
            get: { BottomSheet.presents(wanted: showSuggestStops, sheetUp: sheetUp) }, set: { showSuggestStops = $0 })) {
            SuggestStopsSheet(
                model: SuggestStopsModel(
                    line: routeInfo.coordinates.count > 1 ? RouteLine(routeInfo.coordinates) : nil,
                    routeSeconds: routeInfo.travelTime,
                    existing: SuggestStopsModel.existingOffsets(planner.items)),
                summary: suggestSummary,
                canAdd: { StopListLogic.canAdd(among: planner.items) },
                onAdd: { addStop($0) })
        }
        .onChange(of: model.members, initial: true) { _, _ in recordPastTrip() }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.trip?.route) {
            guard let trip = model.trip else { return }
            await routeInfo.load(
                route: trip.route, routeSeconds: trip.routeSeconds, needsRoadName: model.stops.isEmpty, ownTrip: !isOrganizer)
        }
        // A participant's own way in, once their car doc has loaded (its route arrives from the car's tracker).
        .task(id: OwnWayTaskKey(route: model.trip?.route, carRoute: session.car?.route, mergeOffset: session.car?.mergeOffset, loaded: session.car != nil, granted: locationGranted,
            meeting: TripSessionLogic.meetingPoint(in: model.stops) != nil)) {
            guard !isSample, !isOrganizer, let trip = model.trip, let car = session.car else { return }
            let granted = locationGranted
            await ownWay.load(
                main: RouteLine(Polyline.decode(trip.route)),
                destination: trip.destination.coordinate.coordinate,
                destinationName: trip.destination.name, car: car,
                meetingPoint: TripSessionLogic.meetingPoint(in: model.stops), routeSeconds: trip.routeSeconds,
                phone: { granted ? try? await RouteBuilder.currentLocation() : nil })
        }
        .alert("Trip name", isPresented: Binding(
            get: { BottomSheet.presents(wanted: renaming, sheetUp: sheetUp) }, set: { renaming = $0 })) {
            TextField("Trip name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let id = model.trip?.id else { return }
                run { try await TripService.rename(tripId: id, to: name) }
            }
        }
        .toolbar {
            if canEdit, let trip = model.trip {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        renameText = trip.name
                        renaming = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Rename trip")
                }
            }
            if canLeaveTrip || canEnd || canPause || !isSample {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if canPause {
                            if session.isPaused {
                                Button("Resume sharing", systemImage: "play.fill") {
                                    run { try await session.resumeSharing() }
                                }
                            } else {
                                Button("Pause sharing", systemImage: "pause.fill") {
                                    run { try await session.pauseSharing() }
                                }
                            }
                        }
                        if !isSample {
                            Toggle("Keep screen on", systemImage: "sun.max", isOn: Binding(
                                get: { ScreenAwake.preference(answered: keepAwakeAnswered, stored: keepAwake) },
                                set: { keepAwake = $0; keepAwakeAnswered = true }))
                        }
                        TripExitMenu(canEnd: canEnd, canLeave: canLeaveTrip, confirmEnd: $confirmEnd, confirmLeave: $confirmLeave)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .disabled(isWorking)
                    .accessibilityLabel("Trip options")
                }
            }
        }
        .onAppear {
            guard !isSample else { return }
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
            if session.consumeAlwaysExplainer(action: action) { session.alwaysExplainerShowing = true }
        }
        .sheet(isPresented: Binding(
            get: { TripSessionLogic.explainerVisible(wanted: session.alwaysExplainerShowing, askShowing: session.askShowing, mapSheetUp: session.mapSheetUp || sheetUp) },
            set: { if !$0 { session.alwaysExplainerShowing = false } }
        )) {
            // Declining is fine: the background activity session keeps tracking alive on When In Use.
            AlwaysLocationExplainerView(permission: location) { _ in session.alwaysExplainerShowing = false }
        }
        .tripExitDialogs(
            confirmLeave: Binding(get: { BottomSheet.presents(wanted: confirmLeave, sheetUp: sheetUp) }, set: { confirmLeave = $0 }),
            confirmEnd: Binding(get: { BottomSheet.presents(wanted: confirmEnd, sheetUp: sheetUp) }, set: { confirmEnd = $0 }),
            leave: { run { try await session.leave(); onExit() } },
            end: { run { try await session.endTrip() } })
    }

    /// The lobby's content in Apple's own sheet over the map (canvas B4 medium, B5 tall): the same glass surface as the
    /// driving screen's convoy sheet, always up, the map above it touchable at medium. Start trip, the waiting line and
    /// Show map sit in its bottom bar at both heights.
    private var sheetContent: some View {
        let compact = compact
        return List {
            statusBanner
                .lobbyRow()
            if session.isPaused && !session.isEnded && !session.membershipLost {
                PausedBanner(session: session, onError: { actionError = $0 })
                    .padding(.bottom, Spacing.xs)
                    .lobbyRow()
            }
            if let trip = model.trip {
                tripCardRows(trip)
                inviteCard(trip.code)
                    .padding(.top, Spacing.m)
                    .lobbyRow()
                carsHeader
                    .lobbyRow()
                carsCard
                    .lobbyRow()
                if let actionError {
                    InlineNote(actionError, tone: .alert)
                        .padding(.top, Spacing.m)
                        .lobbyRow()
                }
            } else if let message = model.errorMessage {
                Text(message).font(.footnote).foregroundStyle(.red).padding(.top, Spacing.block)
                    .lobbyRow()
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    .lobbyRow()
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .listRowSpacing(0)
        .environment(\.defaultMinListRowHeight, 1)
        .contentMargins(.top, Spacing.m, for: .scrollContent)
        .contentMargins(.bottom, Spacing.l, for: .scrollContent)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .environment(\.inPanelSheet, true)
        .padding(.top, LobbySheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheetSafeBottom = $0 }
        .presentationDetents(LobbySheet.detents(compact: compact), selection: Binding(
            get: { LobbySheet.detent(expanded: expanded, compact: compact) },
            set: { expanded = LobbySheet.isExpanded($0) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: LobbySheet.medium(compact)))
        .interactiveDismissDisabled()
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
            exitBanner("You’re no longer in this trip", systemImage: "person.fill.xmark")
        } else if isStarted {
            // Trip in progress and since when are the header now (`lobbySubtitle`).
            EmptyView()
        } else if session.isTracking && !session.isPaused {
            Label("Sharing location", systemImage: "location.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ikutPositive)
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.tight)
                .background(Color.ikutPositive.opacity(0.15), in: Capsule())
                .padding(.bottom, Spacing.xs)
        }
    }

    private func exitBanner(_ title: String, systemImage: String) -> some View {
        VStack(spacing: Spacing.m) {
            Label(title, systemImage: systemImage).font(.headline)
            Button("Back to trips", action: onExit).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .surfaceTile(radius: Radius.card)
        .padding(.bottom, Spacing.s)
    }

    /// The stops as shown: the organizer's own edits while they are being built, else what the trip says.
    private var shownStops: [StopDraft] {
        canEditStops ? planner.items : model.stops.sorted { $0.order < $1.order }.map(StopDraft.init)
    }

    private var failure: StopPlanner.Failure? {
        if case .failed(let failure) = planner.status, canEditStops { return failure }
        return nil
    }

    /// Route preview, name, FROM → TO, the stops, and the total: rows of one white card.
    @ViewBuilder
    private func tripCardRows(_ trip: Trip) -> some View {
        let stops = shownStops
        let showStops = canEditStops || !stops.isEmpty
        let hasPills = canEdit && (canChangeDestination || canEditStops)
        if canEdit, canChangeDestination || canEditStops {
            VStack(alignment: .leading, spacing: 0) {
                if canChangeDestination {
                    Button { showChangeDestination = true } label: {
                        pill("Change destination", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
                if canEditStops {
                    HStack(spacing: Spacing.tight) {
                        Button { showAddStop = true } label: {
                            pill("Add a stop", systemImage: "plus")
                        }
                        .buttonStyle(.plain)
                        .disabled(!StopListLogic.canAdd(among: stops))
                        .accessibilityIdentifier("stops.add")
                        Button { showSuggestStops = true } label: {
                            pill("Suggest stops", systemImage: "sparkles")
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("stops.suggest")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.gap)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .cardSlice(top: true)
            .lobbyRow()
        }

        VStack(alignment: .leading, spacing: Spacing.gap) {
            HStack(alignment: .firstTextBaseline) {
                Text(trip.name)
                    .font(.subheadline)
                    .foregroundStyle(Color.surfaceSecondary)
                Spacer(minLength: Spacing.s)
                if isStarted {
                    StatusPill(text: "On the move", color: .ikutPositive, dot: .green)
                } else if !session.isEnded {
                    StatusPill(text: "Gathering", color: .ikutWarning, dot: .orange)
                }
            }
            RouteEnds(from: isOrganizer ? routeInfo.originName : ownWay.fromName, to: trip.destination.name)
                .padding(.top, -6)
            if !isOrganizer, let line = ownWay.joinLine {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(Color.surfaceSecondary)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .padding(.bottom, showStops ? 0 : Spacing.gap)
        .cardSlice(top: !hasPills)
        .lobbyRow()

        if showStops {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout())
            layout {
                Text("Stops on the way").font(.caption.weight(.semibold)).tracking(0.6).textCase(.uppercase).accessibilityAddTraits(.isHeader)
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
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m).padding(.bottom, Spacing.tight)
            .cardSlice()
            .lobbyRow()

            if stops.isEmpty {
                Text("No stops yet. Add one for fuel, food or a place to meet.")
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                    .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
                    .cardSlice()
                    .lobbyRow()
            }
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                stopRow(stop, index: index, stops: stops)
            }
            .onMove(perform: canEditStops ? { planner.move(from: $0, to: $1) } : nil)
            if let failure, failure.place.stopId == nil {
                StopNote(
                    tone: .failure,
                    title: StopNoteText.failureTitle(failure, stopName: nil, destinationName: trip.destination.name),
                    detail: StopNoteText.failureDetail(failure), retry: { planner.retry() })
                    .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.gap)
                    .cardSlice()
                    .lobbyRow()
            }
        }

        if planner.queued && canEditStops {
            StopNote(tone: .warning, title: StopNoteText.queuedTitle, detail: StopNoteText.queuedDetail)
                .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.gap)
                .cardSlice()
                .lobbyRow()
        }

        routeTotal(trip, stops: stops)
            .padding(.horizontal, Spacing.l)
            .padding(.top, showStops ? Spacing.gap : 0).padding(.bottom, Spacing.cozy)
            .cardSlice(bottom: true)
            .lobbyRow()
    }

    private func pill(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .background(.regularMaterial, in: Capsule())
            // Drawn 30 pt tall, taps over 44 (HIG: a hit region of at least 44 x 44 pt).
            .padding(.vertical, 7)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func stopRow(_ stop: StopDraft, index: Int, stops: [StopDraft]) -> some View {
        let failedHere = failure?.place == .stop(stop.id)
        StopRow(
            stop: stop, editable: canEditStops, first: index == 0,
            turnBack: canEditStops && !planner.isBuilding ? planner.turnBacks[stop.id] : nil,
            failure: failedHere ? failure : nil, failed: failedHere, onRetry: { planner.retry() })
            .contentShape(Rectangle())
            .onTapGesture { flyTo(stop.id) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows it on the map")
            .cardSlice()
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
    private func routeTotal(_ trip: Trip, stops: [StopDraft]) -> some View {
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

    /// The viewer's car colour for their own route on the map preview.
    private var locationGranted: Bool { location.status == .whenInUse || location.status == .always }

    private var ownCarColor: String { session.car?.color ?? sampleCarColor }

    private func inviteCard(_ code: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                StatCaption("Join code")
                Text(LobbyLogic.displayCode(code))
                    .font(.system(size: ScaledSize.capped(codeSize, base: 30, cap: 1.5), weight: .bold, design: .monospaced))
                    .kerning(2)
                    // The code is one token that must stay on one line, so it shrinks rather than wraps.
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
                // The share sheet also offers Copy, so there's no separate copy button.
                ShareLink(item: LobbyLogic.shareText(code: code)) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.tight)
                        .frame(minHeight: 36)
                }
                .surfaceButton(.primary, fill: .ikutAccent, foreground: .white)
                .padding(.top, Spacing.tight)
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)

            DashedDivider()
                .padding(.vertical, Spacing.m)

            VStack(spacing: Spacing.xs) {
                if let image = QRCode.image(for: LobbyLogic.joinURL(code: code)) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .accessibilityLabel("QR code to join with code \(code)")
                }
                Text("Scan to join")
                    .font(.caption2)
                    .foregroundStyle(Color.surfaceSecondary)
            }
            .frame(width: 112)
        }
        .surfaceTile(radius: Radius.card)
    }

    /// "CARS", one bar segment per car (green once tracking), then "3 of 4 ready".
    private var carsHeader: some View {
        let cars = model.groupedCars
        let ready = cars.filter(\.hasTracker).count
        return CardHeader("Cars") {
            if !cars.isEmpty {
                HStack(spacing: 3) {
                    ForEach(cars) { car in
                        Capsule()
                            .fill(car.hasTracker ? Color.green : Color.orange)
                            .frame(height: 4)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
                Text("\(ready) of \(cars.count) ready")
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(ready == cars.count ? Color.ikutPositive : Color.ikutWarning)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var carsCard: some View {
        let cars = model.groupedCars
        return VStack(spacing: 0) {
            if cars.isEmpty {
                EmptyRow("No cars yet")
            }
            ForEach(Array(cars.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                CarRow(item: item, position: index + 1, currentUserId: currentUserId)
            }
        }
        .surfaceTile(radius: Radius.card)
    }
}

#if DEBUG
#Preview("Gathering") {
    Backend.configure()
    return NavigationStack {
        LobbyView(sample: .sample(started: false))
    }
    .environment(LocationPermission())
}

#Preview("On the move") {
    Backend.configure()
    return NavigationStack {
        LobbyView(sample: .sample(started: true))
    }
    .environment(LocationPermission())
}
#endif

private extension View {
    /// The line under the lobby's title ("Since 9:35 PM"): the navigation subtitle on iOS 26, before that a
    /// two-line title in the bar's middle.
    @ViewBuilder func lobbySubtitle(title: String, subtitle: String?) -> some View {
        if #available(iOS 26, *) {
            navigationSubtitle(subtitle ?? "")
        } else {
            toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(title).font(.headline)
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.surfaceSecondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
            }
        }
    }
}

/// What the participant's own-way-in task reloads on.
private struct OwnWayTaskKey: Equatable {
    var route: String?
    var carRoute: String?
    var mergeOffset: Double?
    var loaded: Bool
    var granted: Bool
    var meeting: Bool
}
