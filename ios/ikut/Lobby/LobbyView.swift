import FirebaseAuth
import MapKit
import SwiftUI

/// Shown after creating or joining a trip (CreateTrip.dc.html): the route card, join code with
/// QR and share, and the live list of cars. It is the trip screen's lobby layer over the one map (`TripScreenHost`), and
/// holds the trip's session; Start trip and Show map switch the screen to driving (`TripMapView`, the driving layer)
/// without a new screen. While driving, the lobby's journey, code, trip, options and Leave or End continue below the
/// convoy when its sheet is pulled up (`pulledUpContent`).
struct LobbyView: View {
    let onExit: () -> Void
    /// The trip ended (by the organizer or the server): show the recap.
    var onEnded: (String) -> Void = { _ in }
    @Environment(LocationPermission.self) private var location
    @Environment(TripMapStage.self) private var stage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var codeSize: CGFloat = 30
    @State private var model: LobbyModel
    @State private var session: TripSession
    @State private var routeInfo = TripRouteInfo()
    /// The main route's length in meters, for how far along a stop is in time.
    @State private var routeLength: Double?
    // The same switch the map applies (TripMapView): the lobby is where it moved to.
    @AppStorage("ikut.map.keepAwake") private var keepAwake = false
    @AppStorage("ikut.map.keepAwakeAnswered") private var keepAwakeAnswered = false
    /// A participant's own trip: their start, where they join, their distance and drive time (D26).
    @State private var ownWay = OwnWayInfo()
    /// The main route as a line (for each car's join), and the towns the other cars join near.
    @State private var mainLine: RouteLine?
    @State private var joinTowns: JoinTowns
    /// How each car meets the main route, worked out once whenever the cars or the route change (not on each redraw).
    @State private var joins: [String: LobbyContent.CarJoin] = [:]
    @State private var planner: StopPlanner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Add a stop (B6): while it is set, the sheet's content is the stop chooser and the map shows its R&Rs.
    @State private var adding: AddStopModel?
    @State private var showSuggestStops = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showChangeDestination = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var actionError: String?
    /// Start trip with a car not sharing yet asks first (#362).
    @State private var confirmStart = false
    @State private var showQR = false
    /// Copy was just tapped: its label says Copied for a moment.
    @State private var copied = false
    @State private var copiedCount = 0
    /// The trip screen is on screen (not popped, nothing pushed over it): the sheet goes with it.
    @State private var onScreen = false
    /// The join towns are being looked up (the lobby's mode, on screen).
    @State private var townsOpen = false
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
    /// In a sample lobby: the driving layer Start switches to (a demo map; nil, the live one), handed what continues
    /// below its convoy when pulled up.
    private var sampleDriving: ((AnyView) -> AnyView)?
    /// In a sample lobby: this phone shares its location (the header says so, and Pause sharing shows).
    private var sampleSharing = false

    init(tripId: String, onExit: @escaping () -> Void, onEnded: @escaping (String) -> Void = { _ in }) {
        self.onExit = onExit
        self.onEnded = onEnded
        _model = State(initialValue: LobbyModel(tripId: tripId))
        _joinTowns = State(initialValue: JoinTowns.shared(for: tripId))
        _session = State(initialValue: TripSession(
            tripId: tripId, userId: Auth.auth().currentUser?.uid ?? ""))
        _planner = State(initialValue: StopPlanner { plan in try await TripService.saveStops(tripId: tripId, plan: plan) })
    }

    #if DEBUG
    /// A lobby on sample data, for previews.
    init(sample model: LobbyModel) {
        onExit = {}
        _model = State(initialValue: model)
        _joinTowns = State(initialValue: JoinTowns(place: { _ in nil }))
        _session = State(initialValue: TripSession(tripId: model.tripId, userId: ""))
        _planner = State(initialValue: StopPlanner(router: DemoRoads(), delay: .milliseconds(150), origin: { nil }, save: { _ in }))
        isSample = true
    }

    /// A lobby on sample data with the planner in a given state, for previews and screenshots: `organizer` shows the
    /// organizer's card (editable) rather than a member's.
    init(
        sample model: LobbyModel, planner: StopPlanner, organizer: Bool, ownWay: OwnWayInfo? = nil, tall: Bool = false,
        joinTowns: JoinTowns? = nil, adding: AddStopModel? = nil, sharing: Bool = false,
        driving: ((AnyView) -> AnyView)? = nil
    ) {
        self.init(sample: model)
        sampleDriving = driving
        sampleSharing = sharing
        // A sample lobby never looks a town up unless the demo gives it a geocoder.
        if let joinTowns { _joinTowns = State(initialValue: joinTowns) }
        _expanded = State(initialValue: tall)
        _planner = State(initialValue: planner)
        sampleOrganizer = organizer
        _adding = State(initialValue: adding)
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

    /// Organiser: Start trip, with the line above it while a car isn't sharing yet. Participant: a plain waiting line
    /// until the trip starts, then Show map (D39).
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
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 50)
                // On a surface that hides the rows scrolling under the bar: a blurred material under the glass capsule.
                .background(.regularMaterial, in: Capsule())
                .glassSurface(.pill)
                .accessibilityIdentifier("lobbyWaiting")
                .sheetActionBar(lift: barLift)
                .transition(.opacity)
        case .startTrip, .showMap:
            VStack(spacing: Spacing.s) {
                if bar == .startTrip, let line = LobbyContent.waitingLine(model.groupedCars) {
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .accessibilityIdentifier("lobby.waitingForCars")
                }
                Button {
                    if bar == .startTrip {
                        if LobbyContent.startConfirm(model.groupedCars) != nil { confirmStart = true } else { startTrip() }
                    } else {
                        switchMode(.showMap)
                    }
                } label: {
                    Text(bar.label).font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                }
                .actionBarStyle(prominent: true)
                // An alert, not a dialog: on iOS 26 a confirmation dialog is a small popover with no Cancel (#362).
                .alert(LobbyContent.startConfirm(model.groupedCars) ?? "", isPresented: $confirmStart) {
                    Button("Start anyway") { startTrip() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(LobbyContent.startConfirmMessage)
                }
            }
            .sheetActionBar(lift: barLift)
            .transition(.opacity)
        }
    }

    private func startTrip() {
        startedHere = true
        Task { await TripService.markStarted(tripId: model.tripId) }
        switchMode(.start)
    }

    /// Lobby and driving are modes of one screen: the sheet's content and detents change in one motion, and the
    /// layer coming on screen moves the camera (`TripScreenLogic.entryCamera`).
    private func switchMode(_ event: TripScreenLogic.Event) {
        let next = TripScreenLogic.mode(after: event, from: stage.mode)
        guard next != stage.mode else { return }
        withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { stage.mode = next }
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
    /// Which rows this person gets (`LobbyContent.rows`): the organizer's edits before the start, a participant's own way in.
    private var rows: LobbyContent.Rows {
        LobbyContent.rows(
            isOrganizer: isOrganizer, started: isStarted, ended: session.isEnded, isLiveMember: canLeave,
            trackingOrPaused: session.isTracking || session.isPaused || sampleSharing)
    }
    /// The Leave trip row: not the organizer before the start (they can only End it).
    private var canLeaveTrip: Bool { rows.canLeave }
    private var canEnd: Bool { rows.canEnd }
    /// Rename and change destination: the organizer, before the trip ends.
    private var canEdit: Bool { rows.canRename }
    /// Change destination: the organizer, until the trip ends (mid-trip it rebuilds the route from where they are).
    private var canChangeDestination: Bool { rows.canChangeDestination }
    /// Add, move and remove stops: the organizer, before the trip has started.
    private var canEditStops: Bool { rows.canEditStops }

    /// "Kuala Lumpur to Ipoh · 205 km · 2 h 25 min", the line under the Suggest stops title.
    private var suggestSummary: String {
        var parts = [[routeInfo.originName, model.trip?.destination.name].compactMap { $0 }.joined(separator: " to ")]
        if let distance = routeInfo.distance { parts.append(RouteFormat.distance(distance)) }
        if let seconds = routeInfo.travelTime { parts.append(ConvoyFormat.duration(seconds)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Pause and resume are for the phone that is broadcasting (or paused while it was).
    private var canPause: Bool { rows.canPause }

    private var cover: LobbySheet.Cover {
        LobbySheet.Cover(
            changeDestination: showChangeDestination,
            suggestStops: showSuggestStops, renaming: renaming, alwaysExplainer: session.alwaysExplainerShowing,
            confirmLeave: confirmLeave, confirmEnd: confirmEnd)
    }
    private var sheetCovered: Bool { LobbySheet.isCovered(cover, lobbyOnScreen: onScreen) }
    /// Either mode's sheet is up (the lobby's, or the convoy's while driving): what the lobby presents waits for it to go.
    private var anySheetUp: Bool { sheetUp || session.mapSheetUp }
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
            isOrganizer: isOrganizer, ownJoin: ownWay.joinCoordinate,
            coveredByCandidate: adding.map { model in { model.covers($0) } }) + (adding?.pins ?? [])
    }

    private func openAddStop() {
        let coordinates = routeInfo.coordinates
        adding = AddStopModel(
            line: coordinates.count > 1 ? RouteLine(coordinates) : nil,
            routeSeconds: model.trip?.routeSeconds ?? routeInfo.travelTime,
            along: coordinates.count > 1 ? AlongRoute(coordinates: coordinates, seconds: routeInfo.travelTime) : nil,
            canMeet: StopListLogic.canMeet(among: planner.items), canAdd: StopListLogic.canAdd(among: planner.items),
            existing: SuggestStopsModel.existingOffsets(planner.items))
    }

    /// Back to the lobby, the map back on the whole trip.
    private func closeAddStop() {
        adding = nil
        mapCommand = mapCommand.asking(.wholeTrip)
    }

    var body: some View {
        ZStack {
            switch TripScreenLogic.layer(in: stage.mode) {
            case .lobby:
                lobbyLayer
            case .driving:
                if let sampleDriving {
                    sampleDriving(AnyView(pulledUpContent))
                } else {
                    TripMapView(
                        session: session, continuation: AnyView(pulledUpContent), lobbyWants: sheetCovered,
                        onEnded: { onEnded(model.tripId) })
                }
            }
        }
        // The trip started from another phone: no more stop edits.
        .onChange(of: canEditStops) { _, can in if !can { adding = nil } }
        // One listener set at a time (`TripScreenLogic.lobbyListens`): driving, the lobby listens only while the
        // convoy sheet is pulled up and shows the lobby below the convoy.
        .onChange(of: stage.mode) { _, _ in updateListening() }
        .onChange(of: stage.pulledUp) { _, _ in updateListening() }
        .navigationDestination(isPresented: $showChangeDestination) {
            CreateTripView(
                changingTripId: model.trip?.id, keepingStops: planner.items,
                midTrip: LobbyLogic.isStarted(trip: model.trip) ? { [session] in try await session.rebuilder.changeDestination(to: $0) } : nil
            ) { _ in showChangeDestination = false }
        }
        // The header (Back, the trip's name, Share) is in the sheet, so the map runs to the top of the screen.
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onChange(of: session.isEnded, initial: true) { _, ended in
            if ended { onEnded(model.tripId) }
        }
        .onChange(of: model.trip, initial: true) { _, _ in
            recordPastTrip()
            syncPlanner()
        }
        .onChange(of: model.stops) { _, _ in syncPlanner() }
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
        .onChange(of: joinTownsKey, initial: true) { _, _ in askJoinTowns() }
        .task(id: model.trip?.route) {
            guard let trip = model.trip else { return }
            let line = RouteLine(Polyline.decode(trip.route))
            mainLine = line
            routeLength = line.length
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
            get: { BottomSheet.presents(wanted: renaming, sheetUp: anySheetUp) }, set: { renaming = $0 })) {
            TextField("Trip name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let id = model.trip?.id else { return }
                run { try await TripService.rename(tripId: id, to: name) }
            }
        }
        .onAppear {
            onScreen = true
            if !isSample { session.start() }
            updateListening()
        }
        // The session keeps running while driving and when another screen is pushed on top; it stops when the trip
        // screen is popped and the session is released.
        .onDisappear {
            onScreen = false
            updateListening()
        }
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
            confirmLeave: Binding(get: { BottomSheet.presents(wanted: confirmLeave, sheetUp: anySheetUp) }, set: { confirmLeave = $0 }),
            confirmEnd: Binding(get: { BottomSheet.presents(wanted: confirmEnd, sheetUp: anySheetUp) }, set: { confirmEnd = $0 }),
            leave: { run { try await session.leave(); onExit() } },
            end: { run { try await session.endTrip() } })
    }

    /// Starts or rests the lobby's listeners (`TripScreenLogic.lobbyListens`) and the join towns, which only the lobby's
    /// own mode shows. What was last read stays on screen while they rest.
    private func updateListening() {
        guard !isSample else { return }
        if TripScreenLogic.lobbyListens(onScreen: onScreen, mode: stage.mode, pulledUp: stage.pulledUp) {
            model.start()
        } else {
            model.stop()
        }
        let towns = onScreen && stage.mode == .lobby
        guard towns != townsOpen else { return }
        townsOpen = towns
        if towns { joinTowns.open() } else { joinTowns.cancel() }
    }

    /// The lobby's map (route, pins, the whole-trip button) and its sheet, handed to the host's one map and one sheet.
    private var lobbyLayer: some View {
        LobbyMapLayer(
            route: routeInfo.coordinates, pins: mapPins, ownRoute: isOrganizer ? [] : ownWay.ownRoute,
            ownColorHex: ownCarColor, sheetCompact: compact,
            onCandidateTap: { adding?.select($0) }, command: $mapCommand)
            .onChange(of: adding?.selectedId, initial: true) { _, id in if let id { flyTo(id) } }
            .preference(key: TripSheetSpecKey.self, value: TripSheetSpec(
                presented: !sheetCovered, onDismiss: { sheetUp = false },
                content: AnyView(sheetContent
                    .onAppear { sheetUp = true }
                    // The content changing to the convoy's (driving) is not a dismissal: the lobby's sheet is gone all the same.
                    .onDisappear { sheetUp = false })))
    }

    /// The lobby's content in Apple's own sheet over the map (canvas B4 medium, B5 tall): the same glass surface as the
    /// driving screen's convoy sheet, always up, the map above it touchable at medium. The header stays on top; below
    /// it the cars show at medium, and what pulling the sheet up adds (code, trip, stops, options) follows them. Start
    /// trip, the waiting line and Show map sit in its bottom bar at both heights.
    private var sheetContent: some View {
        let compact = compact
        return Group {
            if let adding {
                AddStopContent(
                    model: adding, barLift: barLift, onSelect: { adding.select($0) },
                    onExpand: { withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { expanded = true } },
                    onBack: closeAddStop,
                    onAdd: { draft in
                        addStop(draft)
                        closeAddStop()
                    })
            } else {
                lobbyContent
            }
        }
        .environment(\.inPanelSheet, true)
        .padding(.top, LobbySheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheetSafeBottom = $0 }
        .sheet(isPresented: $showQR) {
            if let code = model.trip?.code { QRCodeSheet(code: code) }
        }
        .presentationDetents(TripScreenLogic.Sheet.lobby(compact: compact).detents, selection: Binding(
            get: { LobbySheet.detent(expanded: expanded, compact: compact) },
            set: { expanded = LobbySheet.isExpanded($0) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: TripScreenLogic.Sheet.lobby(compact: compact).touchableUpThrough))
        .interactiveDismissDisabled()
    }

    private var lobbyContent: some View {
        VStack(spacing: 0) {
            sheetHeader
            List {
                statusBanner
                    .lobbyRow()
                if session.isPaused && !session.isEnded && !session.membershipLost {
                    PausedBanner(session: session, onError: { actionError = $0 })
                        .padding(.bottom, Spacing.xs)
                        .lobbyRow()
                }
                if let trip = model.trip {
                    if rows.ownWay { ownWayTile(trip).lobbyRow(top: Spacing.xs, bottom: Spacing.xs) }
                    carsRows
                    if let actionError {
                        InlineNote(actionError, tone: .alert)
                            .padding(.top, Spacing.m)
                            .lobbyRow()
                    }
                    codeCard(trip.code).lobbyRow(top: Spacing.section)
                    tripRows(trip)
                    stopsRows(trip)
                    optionRows
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
            .contentMargins(.top, Spacing.xs, for: .scrollContent)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
            .sheetBottomBar { bottomBar }
        }
    }

    // MARK: Header

    /// Back to trips and Share invite as round glass buttons, the trip's name under them and, under that, where it goes,
    /// when they meet and the code (canvas B4). After the start the title and line are the trip's state.
    private var sheetHeader: some View {
        let trip = model.trip
        let ended = session.isEnded
        let subtitle = trip.flatMap { trip in
            LobbyContent.subtitle(
                destination: trip.destination.name,
                meetAt: TripSessionLogic.meetingPoint(in: model.stops) != nil ? shownStops.first(where: \.isMeeting)?.meetAt : nil,
                code: trip.code, started: isStarted, ended: ended, startedAt: trip.startedAt ?? trip.createdAt)
        }
        let sharing = LobbyContent.subtitleSharing(
            tracking: isSample ? sampleSharing : session.isTracking, paused: session.isPaused, started: isStarted, ended: ended)
        return SheetTopRow(
            title: trip.map { LobbyContent.headerTitle(tripName: $0.name, started: isStarted, ended: ended) } ?? "",
            subtitle: LobbyContent.subtitleWords(subtitle, sharing: sharing), subtitleIdentifier: "lobby.subtitle",
            styledSubtitle: sharing ? sharingSubtitle(subtitle) : nil
        ) {
            RoundGlassIconButton(systemImage: "chevron.backward", label: "Back to trips", action: onExit)
                .accessibilityIdentifier("lobby.back")
        } trailing: {
            if let trip {
                RoundGlassShareLink(item: LobbyLogic.shareText(code: trip.code))
                    .accessibilityIdentifier("lobby.share")
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.bottom, Spacing.xs)
    }

    /// "➤ Sharing · To Ipoh · code K7M 2QX": the arrow and Sharing in the positive green (#394).
    private func sharingSubtitle(_ rest: String?) -> Text {
        let lead = Text("\(Image(systemName: "location.fill")) \(LobbyContent.sharingWord)")
            .foregroundStyle(Color.ikutPositive).fontWeight(.semibold)
        guard let rest else { return lead }
        return lead + Text(" · \(rest)")
    }

    // MARK: Cars

    /// What decides the join towns: the main route, whether it starts at a meeting point, and each car's route and offset.
    private var joinTownsKey: String {
        let meeting = TripSessionLogic.meetingPoint(in: model.stops) != nil
        let cars = model.groupedCars.map { "\($0.car.id ?? "")/\($0.hasTracker)/\($0.car.route?.count ?? 0)/\($0.car.mergeOffset ?? -1)" }
        return "\(mainLine?.length ?? 0)|\(meeting)|" + cars.joined(separator: ",")
    }

    /// Works out how each car meets the route (decoding routes and finding the merge: not for every redraw), then asks
    /// for the towns of the cars that join along the way.
    private func askJoinTowns() {
        guard let mainLine else { return }
        let meeting = TripSessionLogic.meetingPoint(in: model.stops) != nil
        var found: [String: LobbyContent.CarJoin] = [:]
        for item in model.groupedCars {
            guard let id = item.car.id else { continue }
            found[id] = LobbyContent.carJoin(of: item.car, main: mainLine, hasMeetingPoint: meeting)
        }
        joins = found
        joinTowns.request(cars: model.groupedCars.filter { !isMine($0) }, joins: found, main: mainLine)
    }

    private func isMine(_ item: LobbyCar) -> Bool {
        if isSample { return item.car.id == (isOrganizer ? "c1" : "c2") }
        guard let currentUserId else { return false }
        return item.members.contains { $0.id == currentUserId }
    }

    /// "Cars · 4 of 5 ready" and the cars, each with the line under it. Tapping a car does nothing (no other car's
    /// position, #361), except a participant's own row, which shows where they join when the lobby knows.
    @ViewBuilder private var carsRows: some View {
        let cars = model.groupedCars
        sectionLabel(LobbyContent.carsHeader(cars)).lobbyRow(top: Spacing.s)
        VStack(spacing: 0) {
            if cars.isEmpty { EmptyRow("No cars yet") }
            ForEach(Array(cars.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                let mine = isMine(item)
                let carJoin = item.car.id.flatMap { joins[$0] } ?? LobbyContent.carJoin(
                    of: item.car, main: nil, hasMeetingPoint: false)
                let text = LobbyContent.carText(
                    item, mine: mine, viewerLeavesFromTheStart: isOrganizer || ownWay.join == .startsWithConvoy,
                    joinPlace: item.car.id.flatMap {
                        joinTowns.town(carId: $0, join: carJoin.join, mainLength: mainLine?.length ?? 0)
                    },
                    join: carJoin.join, destination: model.trip?.destination.name,
                    meeting: carJoin.meetsAtMeeting ? model.stops.first(where: \.isMeeting)?.name : nil)
                let row = CarRow(text: text, number: item.car.number ?? index + 1, colorHex: item.car.color)
                if mine, !isOrganizer, ownWay.joinCoordinate != nil {
                    Button { flyTo("join") } label: { row }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows where you join")
                } else {
                    row
                }
            }
        }
        .surfaceTile(radius: Radius.card)
        .lobbyRow()
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.surfaceSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: A participant's own way in

    /// FROM to TO, where they join the convoy, and their drive (D26).
    private func ownWayTile(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: Spacing.gap) {
            RouteEnds(from: ownWay.fromName, to: trip.destination.name)
            if let line = ownWay.joinLine {
                Text(line).font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
            routeTotal(trip, stops: shownStops)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile(radius: Radius.card)
    }

    // MARK: Tall: the code

    private func codeCard(_ code: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Text("Trip code").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
            Text(LobbyLogic.displayCode(code))
                .font(.system(size: ScaledSize.capped(codeSize, base: 36, cap: 1.5), weight: .bold, design: .monospaced))
                .kerning(5)
                // The code is one token that must stay on one line, so it shrinks rather than wraps.
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
            Text("Anyone with the code can join until the trip ends")
                .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
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
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .actionButton(.secondary, onGlass: true)
                .sensoryFeedback(.success, trigger: copiedCount)
                .accessibilityIdentifier("lobby.copyCode")
                Button { showQR = true } label: {
                    Label("QR code", systemImage: "qrcode").font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .actionButton(.secondary, onGlass: true)
                .accessibilityIdentifier("lobby.showQR")
            }
            .padding(.top, Spacing.tight)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity)
        .surfaceTile(radius: Radius.card)
    }

    // MARK: Tall: the trip

    /// Name (the organizer taps to rename) and Destination (the organizer taps to change it; a participant reads it).
    @ViewBuilder private func tripRows(_ trip: Trip) -> some View {
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

    @ViewBuilder private func tripRow(_ title: String, value: String, tappable: Bool, id: String, hint: String = "", action: @escaping () -> Void) -> some View {
        let content = HStack(spacing: Spacing.s) {
            Text(title)
            Spacer(minLength: Spacing.s)
            Text(value).foregroundStyle(Color.surfaceSecondary).lineLimit(1)
            if tappable {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 48)
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
    private var shownStops: [StopDraft] {
        canEditStops ? planner.items : model.stops.sorted { $0.order < $1.order }.map(StopDraft.init)
    }

    private var failure: StopPlanner.Failure? {
        if case .failed(let failure) = planner.status, canEditStops { return failure }
        return nil
    }

    /// The meeting point first, the stops numbered as on the map, then (the organizer, before the start) Add a stop and
    /// Suggest stops, and the route's total. Reorder and swipe to remove work on the rows as before.
    @ViewBuilder private func stopsRows(_ trip: Trip) -> some View {
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
                    .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.gap)
                    .cardSlice()
                    .lobbyRow()
            }
            if planner.queued && canEditStops {
                StopNote(tone: .warning, title: StopNoteText.queuedTitle, detail: StopNoteText.queuedDetail)
                    .padding(.horizontal, Spacing.m).padding(.bottom, Spacing.gap)
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

    private func stopAction(_ title: String, systemImage: String, caption: String?, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.m) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ikutAccent)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(title).foregroundStyle(Color.ikutAccent)
                Spacer(minLength: Spacing.s)
                if let caption {
                    Text(caption).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                }
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    // MARK: Tall: options and leaving

    /// Keep screen on, Pause or Resume sharing, and at the very end Leave trip or End trip.
    @ViewBuilder private var optionRows: some View {
        optionsTile.lobbyRow(top: Spacing.section)
        exitTile.lobbyRow(top: Spacing.m, bottom: Spacing.l)
    }

    /// Keep screen on, and Pause or Resume sharing for the phone that shares.
    @ViewBuilder private var optionsTile: some View {
        if !isSample || sampleSharing || canPause {
            VStack(spacing: 0) {
                if !isSample || sampleSharing {
                    Toggle("Keep screen on", isOn: Binding(
                        get: { ScreenAwake.preference(answered: keepAwakeAnswered, stored: keepAwake) },
                        set: { keepAwake = $0; keepAwakeAnswered = true }))
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 48)
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
    @ViewBuilder private var exitTile: some View {
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
    /// options and Leave or End (`LobbyContent.pulledUp`). The same rows as the lobby's, with the same asks, which the
    /// convoy sheet steps aside for (`lobbyWants`).
    @ViewBuilder private var pulledUpContent: some View {
        if let trip = model.trip {
            let up = LobbyContent.pulledUp(rows)
            VStack(spacing: 0) {
                ForEach(up.sections, id: \.self) { section in
                    switch section {
                    case .journey: journeyRows(trip).padding(.top, Spacing.section)
                    case .code: codeCard(trip.code).padding(.top, Spacing.section)
                    case .trip: VStack(spacing: 0) { tripRows(trip) }.padding(.top, Spacing.m)
                    case .options: optionsTile.padding(.top, Spacing.section)
                    case .exit: exitTile.padding(.top, Spacing.m)
                    }
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
            .sheet(isPresented: $showQR) { QRCodeSheet(code: trip.code) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("trip.pulledUp")
        }
    }

    /// The stops still ahead, numbered as on the map with "About … in", under one line for what is already driven
    /// ("Passed R&R Bidor · 12:31", "Left 12:05").
    private func journeyRows(_ trip: Trip) -> some View {
        let journey = LobbyContent.journey(
            model.stops, routeLength: routeLength, routeSeconds: trip.routeSeconds ?? routeInfo.travelTime,
            departedAt: trip.startedAt ?? trip.createdAt)
        let stops = model.stops.map(StopDraft.init)
        return VStack(spacing: 0) {
            sectionLabel("Journey")
            VStack(spacing: 0) {
                if let behind = journey.behind {
                    Label(behind, systemImage: "checkmark.circle")
                        .font(.subheadline)
                        .foregroundStyle(Color.surfaceSecondary)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
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
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .padding(.horizontal, Spacing.l)
                        .overlay(alignment: .top) { if journey.behind != nil { Divider() } }
                }
            }
            .surfaceTile(radius: Radius.card)
        }
    }

    private func optionButton(
        _ title: String, systemImage: String, id: String, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
        .accessibilityIdentifier(id)
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
        }
        // Trip in progress and since when, and this phone sharing before the start (#394), are the header's subtitle.
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

    @ViewBuilder
    private func stopRow(_ stop: StopDraft, text: LobbyContent.StopText, index: Int, stops: [StopDraft], lastOfCard: Bool) -> some View {
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

}

#if DEBUG
#Preview("Gathering") {
    Backend.configure()
    return NavigationStack {
        TripScreenHost { LobbyView(sample: .sample(started: false)) }
    }
    .environment(LocationPermission())
}

#Preview("On the move") {
    Backend.configure()
    return NavigationStack {
        TripScreenHost { LobbyView(sample: .sample(started: true)) }
    }
    .environment(LocationPermission())
}
#endif

/// What the participant's own-way-in task reloads on.
private struct OwnWayTaskKey: Equatable {
    var route: String?
    var carRoute: String?
    var mergeOffset: Double?
    var loaded: Bool
    var granted: Bool
    var meeting: Bool
}

/// The code's QR behind QR code: big enough to scan from another phone.
private struct QRCodeSheet: View {
    var code: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let image = QRCode.image(for: LobbyLogic.joinURL(code: code)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(Spacing.m)
                    .background(.white, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityLabel("QR code to join with code \(code)")
            }
            Text(LobbyLogic.displayCode(code))
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .kerning(2)
            Text("Scan to join").font(.subheadline).foregroundStyle(Color.surfaceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            SheetCloseButton(action: { dismiss() }, onGlass: true).padding(Spacing.m)
        }
        .presentationDetents([.medium])
    }
}
