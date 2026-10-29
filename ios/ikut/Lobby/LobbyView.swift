import FirebaseAuth
import MapKit
import SwiftUI

/// Shown after creating or joining a trip (CreateTrip.dc.html): the route card, join code with
/// QR and share, and the live list of cars. It is the trip screen's lobby layer over the one map (`TripScreenHost`), and
/// holds the trip's session; Start trip and Show map switch the screen to driving (`TripMapView`, the driving layer)
/// without a new screen. While driving, the lobby's journey, code, trip, options and Leave or End continue below the
/// convoy when its sheet is pulled up (`pulledUpContent`).
struct LobbyView: View {
    /// In a sample lobby: the driving layer Start switches to, handed what continues below its convoy when pulled up
    /// and the banner on top of its sheet.
    typealias SampleDriving = (_ continuation: @escaping (LobbyContent.JourneyHere?) -> AnyView, _ topBanner: AnyView?) -> AnyView

    let onExit: () -> Void
    /// The trip ended (by the organizer or the server): show the recap.
    var onEnded: (String) -> Void = { _ in }
    @Environment(LocationPermission.self) var location
    @Environment(TripScreenModel.self) var stage
    @Environment(\.dynamicTypeSize) var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) var codeSize: CGFloat = 30
    /// The trip's lobby model and session, made by the screen's model (`TripScreenModel.open`); a sample lobby makes
    /// its own.
    @State var model: LobbyModel
    @State var session: TripSession
    @State var routeInfo = TripRouteInfo()
    /// The main route's length in meters, for how far along a stop is in time.
    @State var routeLength: Double?
    /// A participant's own trip: their start, where they join, their distance and drive time (D26).
    @State var ownWay = OwnWayInfo()
    /// The main route as a line (for each car's join), and the towns the other cars join near.
    @State var mainLine: RouteLine?
    @State var joinTowns: JoinTowns
    /// How each car meets the main route, worked out once whenever the cars or the route change (not on each redraw).
    @State var joins: [String: LobbyContent.CarJoin] = [:]
    @State var planner: StopPlanner
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Add a stop (B6): while it is set, the sheet's content is the stop chooser and the map shows its R&Rs.
    @State var adding: AddStopModel?
    @State var showSuggestStops = false
    @State var renaming = false
    @State var renameText = ""
    @State var showChangeDestination = false
    @State var confirmLeave = false
    @State var confirmEnd = false
    @State var isWorking = false
    @State var actionError: String?
    /// Start trip with a car not sharing yet asks first (#362).
    @State var confirmStart = false
    @State var showQR = false
    /// Copy was just tapped: its label says Copied for a moment.
    @State var copied = false
    @State var copiedCount = 0
    /// The trip screen is on screen (not popped, nothing pushed over it): the sheet goes with it.
    @State var onScreen = false
    /// The join towns are being looked up (the lobby's mode, on screen).
    @State var townsOpen = false
    /// A sample lobby opens with its sheet tall.
    var sampleTall = false
    @State var mapCommand = LobbyMapCommand()
    @ScaledMetric(relativeTo: .body) var mediumHeight: CGFloat = LobbySheet.compactHeight
    @State var sheetSafeBottom: CGFloat = 0
    /// This phone opened the map; covers the gap before the startedAt write comes back.
    @State var startedHere = false
    /// Shows `model` as given: nothing is loaded, started or remembered.
    var isSample = false
    /// In a sample lobby: whether to show the organizer's card.
    var sampleOrganizer = true
    /// The car colour a sample participant's own route is drawn in.
    let sampleCarColor = "#D9480F"
    /// In a sample lobby: the driving layer Start switches to (a demo map; nil, the live one), handed what continues
    /// below its convoy when pulled up.
    var sampleDriving: LobbyView.SampleDriving?
    /// In a sample lobby: this phone shares its location (the header says so, and Pause sharing shows).
    var sampleSharing = false
    /// In a sample lobby: this person is no longer in the trip.
    var sampleLost = false
    #if DEBUG
    /// A launch state opens with one of the lobby's asks already up: `start`, `leave`, `end`, `rename`, `qr`.
    var demoAsk: String?
    #endif

    /// `trip`: the open trip's session, lobby model and planner, made once by the screen's model when the trip opened
    /// (`TripScreenModel.open`), so no redraw makes (and drops) a session with its own location manager.
    init(trip: OpenTrip, onExit: @escaping () -> Void, onEnded: @escaping (String) -> Void = { _ in }) {
        self.onExit = onExit
        self.onEnded = onEnded
        _model = State(initialValue: trip.lobby)
        _joinTowns = State(initialValue: JoinTowns.shared(for: trip.id))
        _session = State(initialValue: trip.session)
        _planner = State(initialValue: trip.planner)
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
        joinTowns: JoinTowns? = nil, adding: AddStopModel? = nil, sharing: Bool = false, lost: Bool = false,
        driving: LobbyView.SampleDriving? = nil
    ) {
        self.init(sample: model)
        sampleDriving = driving
        sampleSharing = sharing
        sampleLost = lost
        // A sample lobby never looks a town up unless the demo gives it a geocoder.
        if let joinTowns { _joinTowns = State(initialValue: joinTowns) }
        sampleTall = tall
        _planner = State(initialValue: planner)
        sampleOrganizer = organizer
        _adding = State(initialValue: adding)
        if let ownWay { _ownWay = State(initialValue: ownWay) }
    }
    #endif

    var isOrganizer: Bool { isSample ? sampleOrganizer : session.isOrganizer }

    /// Started by anyone (the session's trip), or by this phone a moment ago. A sample lobby has no session: its trip says.
    var isStarted: Bool {
        guard !isEnded else { return false }
        return (isSample ? LobbyLogic.isStarted(trip: model.trip) : session.isStarted) || startedHere
    }

    var isEnded: Bool { isSample ? model.trip?.status == .ended : session.isEnded }

    /// Organiser: Start trip, with the line above it while a car isn't sharing yet. Participant: a plain waiting line
    /// until the trip starts, then Show map (D39).
    @ViewBuilder var bottomBar: some View {
        let bar = LobbyLogic.bottomBar(
            isOrganizer: isOrganizer, tripLoaded: model.trip != nil, isMember: !session.membershipLost,
            started: isStarted, ended: isEnded,
            organizerName: LobbyLogic.organizerName(trip: model.trip, members: model.members))
        ZStack { barContent(bar) }
            .animation(Motion.quick(reduceMotion: reduceMotion), value: bar)
    }

    /// How far the bar's button hangs into the sheet's bottom safe area (`PanelSheet.barLift`).
    var barLift: CGFloat { PanelSheet.barLift(safeBottom: sheetSafeBottom) }

    @ViewBuilder func barContent(_ bar: LobbyLogic.BottomBar) -> some View {
        switch bar {
        case .none:
            EmptyView()
        case .waiting:
            Text(bar.label)
                .foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.l)
                .barActionLabel(font: .subheadline)
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
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                        .accessibilityIdentifier("lobby.waitingForCars")
                }
                Button {
                    if bar == .startTrip {
                        if LobbyContent.startConfirm(model.groupedCars) != nil { confirmStart = true } else { startTrip() }
                    } else {
                        switchMode(.showMap)
                    }
                } label: {
                    Text(bar.label).font(.headline).frame(maxWidth: .infinity)
                }
                .ikutButton(.primary, tint: .ikutAccentFill)
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

    func startTrip() {
        startedHere = true
        Task { await TripService.markStarted(tripId: model.tripId) }
        switchMode(.start)
    }

    /// Lobby and driving are modes of one screen: the sheet's content and detents change in one motion, and the
    /// layer coming on screen moves the camera (`TripScreenLogic.entryCamera`).
    func switchMode(_ event: TripScreenLogic.Event) {
        let next = TripScreenLogic.mode(after: event, from: stage.mode)
        guard next != stage.mode else { return }
        withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { stage.go(to: next) }
    }

    /// Stop edits run in the banner motion, so the List slides the rows around an inserted, removed or moved one.
    /// (A drag to reorder is animated by the List itself.)
    func addStop(_ place: StopDraft) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { planner.add(place) }
    }
    func removeStop(_ id: String) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { planner.remove(id: id) }
    }
    func moveStop(from index: Int, to destination: Int) {
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) {
            planner.move(from: IndexSet(integer: index), to: destination)
        }
    }

    var currentUserId: String? { Auth.auth().currentUser?.uid }

    /// Remembers this trip for Home's past list, with who else is in it once the members have loaded.
    func recordPastTrip() {
        guard !isSample, let trip = model.trip else { return }
        let names = model.members.keyedByID { $0.displayName }
        PastTrips.record(tripId: model.tripId, name: trip.name, destination: trip.destination.name, endedAt: trip.endedAt,
                         others: names.isEmpty ? nil : PastTrips.others(from: names, excluding: currentUserId))
    }

    /// Hands the planner what Firestore says about the trip and its stops.
    func syncPlanner() {
        guard !isSample else { return }
        planner.sync(trip: model.trip, stops: model.stops)
    }

    var canLeave: Bool { session.isLiveMember }
    /// Which rows this person gets (`LobbyContent.rows`): the organizer's edits before the start, a participant's own way in.
    var rows: LobbyContent.Rows {
        LobbyContent.rows(
            isOrganizer: isOrganizer, started: isStarted, ended: session.isEnded, isLiveMember: canLeave,
            trackingOrPaused: session.isTracking || session.isPaused || sampleSharing)
    }
    /// The Leave trip row: not the organizer before the start (they can only End it).
    var canLeaveTrip: Bool { rows.canLeave }
    var canEnd: Bool { rows.canEnd }
    /// Rename and change destination: the organizer, before the trip ends.
    var canEdit: Bool { rows.canRename }
    /// Change destination: the organizer, until the trip ends (mid-trip it rebuilds the route from where they are).
    var canChangeDestination: Bool { rows.canChangeDestination }
    /// Add, move and remove stops: the organizer, before the trip has started.
    var canEditStops: Bool { rows.canEditStops }

    /// "Kuala Lumpur to Ipoh · 205 km · 2 h 25 min", the line under the Suggest stops title.
    var suggestSummary: String {
        var parts = [[routeInfo.originName, model.trip?.destination.name].compactMap { $0 }.joined(separator: " to ")]
        if let distance = routeInfo.distance { parts.append(RouteFormat.distance(distance)) }
        if let seconds = routeInfo.travelTime { parts.append(ConvoyFormat.duration(seconds)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Pause and resume are for the phone that is broadcasting (or paused while it was).
    var canPause: Bool { rows.canPause }

    /// What the trip's layers push or present now, which the one sheet steps aside for in each mode (`TripSheetCover`).
    var covers: Set<TripSheetCover> {
        var covers = Set<TripSheetCover>()
        if showChangeDestination { covers.insert(.changeDestination) }
        if showSuggestStops { covers.insert(.suggestStops) }
        if renaming { covers.insert(.renaming) }
        if session.alwaysExplainerShowing { covers.insert(.alwaysExplainer) }
        if confirmLeave { covers.insert(.confirmLeave) }
        if confirmEnd { covers.insert(.confirmEnd) }
        if isEnded { covers.insert(.tripEnded) }
        return covers
    }
    /// The trip's reasons this view writes; the screen's own (`tripOffScreen`) it writes as it appears and goes.
    static let asks = TripSheetCover.trip.subtracting([.tripOffScreen])
    /// The one sheet is at its tall detent (the lobby's).
    var expanded: Bool { stage.sheet.size == .lobby(tall: true) }
    /// Medium or tall, through the one map (D63 C4): the camera keeps the trip above the medium sheet at either size
    /// (`LobbySheet.cover`), so the change writes the same cover and moves nothing, in this or a later update.
    func setExpanded(_ tall: Bool) {
        stage.sheetChange(in: .lobby, { stage.sheet.resize(to: .lobby(tall: tall)) }, cover: { LobbySheet.cover(compact: compact) })
    }
    var compact: CGFloat { LobbySheet.compact(scaled: mediumHeight) }

    /// What the sheet's content change runs on, and what a stop tap's camera flight uses.
    func flyTo(_ stopId: String) {
        mapCommand = mapCommand.asking(.stop(stopId))
        // The map is behind the sheet when it is tall: bring it down to the medium detent to show the stop.
        if expanded { withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { setExpanded(false) } }
    }

    var mapPins: [LobbyPin] {
        let trip = model.trip
        return LobbyMapLogic.pins(
            stops: shownStops, destinationName: trip?.destination.name, destination: trip?.destination.coordinate.coordinate,
            isOrganizer: isOrganizer, ownJoin: ownWay.joinCoordinate,
            coveredByCandidate: adding.map { model in { model.covers($0) } }) + (adding?.pins ?? [])
    }

    func openAddStop() {
        let coordinates = routeInfo.coordinates
        adding = AddStopModel(
            line: coordinates.count > 1 ? RouteLine(coordinates) : nil,
            routeSeconds: model.trip?.routeSeconds ?? routeInfo.travelTime,
            along: coordinates.count > 1 ? AlongRoute(coordinates: coordinates, seconds: routeInfo.travelTime) : nil,
            canMeet: StopListLogic.canMeet(among: planner.items), canAdd: StopListLogic.canAdd(among: planner.items),
            existing: SuggestStopsModel.existingOffsets(planner.items))
    }

    /// Back to the lobby, the map back on the whole trip.
    func closeAddStop() {
        adding = nil
        mapCommand = mapCommand.asking(.wholeTrip)
    }

    var body: some View {
        let sheetsUp = stage.sheet.up
        let inLobby = stage.mode == .lobby
        return ZStack {
            switch TripScreenLogic.layer(in: stage.mode) {
            case .home:
                // The trip is closing: Home takes the map in the same motion.
                EmptyView()
            case .lobby:
                lobbyLayer
            case .driving:
                if let sampleDriving {
                    sampleDriving({ AnyView(pulledUpContent(here: $0)) }, drivingBanner)
                } else if let map = stage.trip?.map {
                    TripMapView(
                        session: session, map: map, continuation: { AnyView(pulledUpContent(here: $0)) },
                        topBanner: drivingBanner,
                        onEnded: { onEnded(model.tripId) })
                }
            }
        }
        // The trip started from another phone: no more stop edits.
        .onChange(of: canEditStops) { _, can in if !can { adding = nil } }
        // Rule #396 (`TripScreenLogic.lobbyReads`): driving, the lobby reads the session's cars and members only while
        // the convoy sheet is pulled up and shows the lobby below the convoy.
        .onChange(of: stage.mode) { _, _ in updateListening() }
        .onChange(of: covers, initial: true) { _, covers in stage.sheet.cover(covers, among: Self.asks) }
        .onChange(of: stage.pulledUp) { _, pulledUp in
            updateListening()
            // The asks inside the pulled-up sheet went with it (a fold, a stop request, a hazard): none comes back by
            // itself at the next pull-up.
            let asks = LobbySheet.pulledUpAsks(
                .init(confirmLeave: confirmLeave, confirmEnd: confirmEnd, renaming: renaming, showQR: showQR),
                continuationShown: pulledUp || stage.mode == .lobby)
            confirmLeave = asks.confirmLeave
            confirmEnd = asks.confirmEnd
            renaming = asks.renaming
            showQR = asks.showQR
        }
        .navigationDestination(isPresented: $showChangeDestination) {
            CreateTripView(
                changingTripId: model.trip?.id, keepingStops: planner.items,
                midTrip: session.isStarted ? { [session] in try await session.rebuilder.changeDestination(to: $0) } : nil
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
            get: { BottomSheet.presents(wanted: showSuggestStops, sheetUp: sheetsUp) }, set: { showSuggestStops = $0 })) {
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
        // In the lobby's mode its asks present here, once its sheet has stepped aside; driving, the pulled-up sheet
        // presents them itself (`pulledUpContent`).
        .alert("Trip name", isPresented: Binding(
            get: { inLobby && BottomSheet.presents(wanted: renaming, sheetUp: sheetsUp) }, set: { renaming = $0 })) {
            renameActions
        }
        .onAppear {
            onScreen = true
            stage.tripLayer(of: session, onScreen: true)
            if sampleTall { setExpanded(true) }
            #if DEBUG
            // Asked a moment after the screen is up, as a tap does: the sheet is on screen first, steps aside for the ask
            // (`covers`), and the alert presents once it is gone. Set at appear, the sheet's own presentation and its
            // cover race and UIKit drops the alert.
            if let ask = demoAsk {
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    switch ask {
                    case "start": confirmStart = true
                    case "leave": confirmLeave = true
                    case "end": confirmEnd = true
                    case "rename": renameText = "Balik kampung raya"; renaming = true
                    case "qr": showQR = true
                    case "action-error": actionError = "Can’t reach the server. Check your signal and try again."
                    case "change-destination": showChangeDestination = true
                    default: break
                    }
                }
            }
            #endif
            if !isSample { session.start() }
            updateListening()
        }
        // The session keeps running while driving and when another screen is pushed on top; it stops when the
        // screen's model closes the trip (`TripScreenModel.exit`).
        .onDisappear {
            onScreen = false
            stage.tripLayer(of: session, onScreen: false)
            updateListening()
        }
        .onChange(of: session.isTracking) { _, tracking in
            guard tracking else { return }
            if session.consumeAlwaysExplainer(action: location.backgroundAction) { session.alwaysExplainerShowing = true }
        }
        .sheet(isPresented: Binding(
            get: { TripSessionLogic.explainerVisible(wanted: session.alwaysExplainerShowing, askShowing: session.askShowing, mapSheetUp: sheetsUp) },
            set: { if !$0 { session.alwaysExplainerShowing = false } }
        )) {
            // Declining is fine: the background activity session keeps tracking alive on When In Use.
            AlwaysLocationExplainerView(permission: location) { _ in session.alwaysExplainerShowing = false }
        }
        .tripExitDialogs(
            confirmLeave: Binding(get: { inLobby && BottomSheet.presents(wanted: confirmLeave, sheetUp: sheetsUp) }, set: { confirmLeave = $0 }),
            confirmEnd: Binding(get: { inLobby && BottomSheet.presents(wanted: confirmEnd, sheetUp: sheetsUp) }, set: { confirmEnd = $0 }),
            leave: leaveTrip, end: endTrip)
    }

    func leaveTrip() {
        run {
            try await session.leave()
            // Past trips from now on, marked as left: a relaunch (even offline) never reopens it, and Home shows its
            // route without reading the trip or its recap, which are members-only.
            if let trip = model.trip {
                PastTrips.record(tripId: model.tripId, name: trip.name, destination: trip.destination.name,
                                 endedAt: Date(), left: true)
                PastTripsMapService.remember(PastTripsMapLogic.route(
                    id: model.tripId, name: trip.name, destinationName: trip.destination.name,
                    destination: trip.destination.coordinate.coordinate, encodedRoute: trip.route))
            }
            onExit()
        }
    }

    /// Back to trips: the trip keeps going without this screen. Its session stops as the screen's model closes the
    /// trip (`TripScreenModel.exit`), before Home takes the map, rather than whenever the view is released.
    func backToTrips() {
        onExit()
    }
    func endTrip() { run { try await session.endTrip() } }

    /// Rename's field and buttons, in the lobby's alert and the pulled-up sheet's.
    @ViewBuilder var renameActions: some View {
        TextField("Trip name", text: $renameText)
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("renameTripField")
        Button("Cancel", role: .cancel) {}
        Button("Save") {
            let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let id = model.trip?.id else { return }
            run { try await TripService.rename(tripId: id, to: name) }
        }
    }

    /// Starts or rests the lobby's reads of the cars and members from the session (`TripScreenLogic.lobbyReads`) and
    /// the join towns, which only the lobby's own mode shows. What was last read stays on screen while they rest.
    func updateListening() {
        guard !isSample else { return }
        session.read(TripScreenLogic.lobbyReads(onScreen: onScreen, mode: stage.mode, pulledUp: stage.pulledUp), by: .lobby)
        let work = joinWork
        let towns = work == .joinsAndTowns
        if towns != townsOpen {
            townsOpen = towns
            if towns { joinTowns.open() } else { joinTowns.cancel() }
        }
        // Back in the lobby (or pulled up): catch up on the cars that changed while it wasn't asking.
        if work != .none { askJoinTowns() }
    }

    /// How much join-town work the lobby does now (`TripScreenLogic.joinWork`); a sample lobby does all of it.
    var joinWork: TripScreenLogic.JoinWork {
        isSample ? .joinsAndTowns
            : TripScreenLogic.joinWork(onScreen: onScreen, mode: stage.mode, pulledUp: stage.pulledUp)
    }

    /// The lobby's map (route, pins, the whole-trip button) and its sheet, handed to the host's one map and one sheet.
    var lobbyLayer: some View {
        LobbyMapLayer(
            route: routeInfo.coordinates, pins: mapPins, ownRoute: isOrganizer ? [] : ownWay.ownRoute,
            ownColorHex: ownCarColor, sheetCompact: compact,
            onCandidateTap: { adding?.select($0) }, command: $mapCommand)
            .onChange(of: adding?.selectedId, initial: true) { _, id in if let id { flyTo(id) } }
            .preference(key: TripSheetSpecKey.self, value: TripSheetSpec(content: AnyView(sheetContent)))
    }

    /// The lobby's content in Apple's own sheet over the map (canvas B4 medium, B5 tall): the same glass surface as the
    /// driving screen's convoy sheet, always up, the map above it touchable at medium. The header stays on top; below
    /// it the cars show at medium, and what pulling the sheet up adds (code, trip, stops, options) follows them. Start
    /// trip, the waiting line and Show map sit in its bottom bar at both heights.
    var sheetContent: some View {
        let compact = compact
        return Group {
            if let adding {
                AddStopContent(
                    model: adding, barLift: barLift, onSelect: { adding.select($0) },
                    onExpand: { withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { setExpanded(true) } },
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
        .buttonSurface(.glass)
        .padding(.top, LobbySheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheetSafeBottom = $0 }
        .sheet(isPresented: $showQR) {
            if let code = model.trip?.code { QRCodeSheet(code: code) }
        }
        .presentationDetents(TripScreenLogic.Sheet.lobby(compact: compact).detents, selection: Binding(
            get: { LobbySheet.detent(expanded: expanded, compact: compact) },
            set: { setExpanded(LobbySheet.isExpanded($0)) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: TripScreenLogic.Sheet.lobby(compact: compact).touchableUpThrough))
        .interactiveDismissDisabled()
    }

    var lobbyContent: some View {
        // The header stays put and the rows fade out under it, as they do above the bottom bar.
        Group {
            List {
                // Each hand-drawn part is one Section with one row (zero insets, clear background); the plain
                // ones (Cars, Trip, Stops) are system rows. Code, options and exit follow in later pieces (D86).
                Section {
                    statusBanner.lobbyRow()
                    if session.isPaused && !session.isEnded && !session.membershipLost {
                        PausedBanner(session: session, onError: { actionError = $0 })
                            .padding(.bottom, Spacing.xs)
                            .lobbyRow()
                    }
                }
                if let trip = model.trip {
                    if rows.ownWay {
                        Section { ownWayTile(trip).lobbyRow(top: Spacing.xs, bottom: Spacing.xs) }
                    }
                    carsSection
                    if let actionError {
                        Section {
                            InlineNote(actionError, tone: .alert)
                                .lobbyRow(top: Spacing.m)
                        }
                    }
                    Section { codeCard(trip.code).lobbyRow() }
                    tripSection(trip)
                    if showsStops { stopsSection(trip) }
                    Section { optionRows }
                } else if let message = model.errorMessage {
                    Section {
                        Text(message).font(.footnote).foregroundStyle(.red).padding(.top, Spacing.xl)
                            .lobbyRow()
                    }
                } else {
                    Section {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.hero)
                            .lobbyRow()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, Spacing.xs, for: .scrollContent)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
            .sheetBottomBar { bottomBar }
        }
        .sheetTopBar { sheetHeader }
    }

    // MARK: Header

    /// Back to trips and Share invite as round glass buttons, the trip's name under them and, under that, where it goes,
    /// when they meet and the code (canvas B4). After the start the title and line are the trip's state.
    var sheetHeader: some View {
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
            RoundGlassIconButton(systemImage: "chevron.backward", label: "Back to trips", action: backToTrips)
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
    func sharingSubtitle(_ rest: String?) -> Text {
        let lead = Text("\(Image(systemName: "location.fill")) \(LobbyContent.sharingWord)")
            .foregroundStyle(Color.ikutPositive).fontWeight(.semibold)
        guard let rest else { return lead }
        return lead + Text(" · \(rest)")
    }

    // MARK: Cars

    /// What decides the join towns: the main route, whether it starts at a meeting point, and each car's route and offset.
    var joinTownsKey: String {
        let meeting = TripSessionLogic.meetingPoint(in: model.stops) != nil
        let cars = model.groupedCars.map { "\($0.car.id ?? "")/\($0.hasTracker)/\($0.car.route?.count ?? 0)/\($0.car.mergeOffset ?? -1)" }
        return "\(mainLine?.length ?? 0)|\(meeting)|" + cars.joined(separator: ",")
    }

    /// Works out how each car meets the route (decoding routes and finding the merge: not for every redraw), then asks
    /// for the towns of the cars that join along the way.
    /// Nothing while driving folded: the session's cars listener keeps changing the cars, but no row shows them.
    func askJoinTowns() {
        let work = joinWork
        guard work != .none, let mainLine else { return }
        let meeting = TripSessionLogic.meetingPoint(in: model.stops) != nil
        var found: [String: LobbyContent.CarJoin] = [:]
        for item in model.groupedCars {
            guard let id = item.car.id else { continue }
            found[id] = LobbyContent.carJoin(of: item.car, main: mainLine, hasMeetingPoint: meeting)
        }
        joins = found
        guard work == .joinsAndTowns else { return }
        joinTowns.request(cars: model.groupedCars.filter { !isMine($0) }, joins: found, main: mainLine)
    }

    func isMine(_ item: LobbyCar) -> Bool {
        if isSample { return item.car.id == (isOrganizer ? "c1" : "c2") }
        guard let currentUserId else { return false }
        return item.members.contains { $0.id == currentUserId }
    }

    /// "Cars · 4 of 5 ready" and the cars, each with the line under it. Tapping a car does nothing (no other car's
    /// position, #361), except a participant's own row, which shows where they join when the lobby knows.
    @ViewBuilder var carsSection: some View {
        let cars = model.groupedCars
        Section {
            if cars.isEmpty { EmptyRow("No cars yet") }
            ForEach(Array(cars.enumerated()), id: \.element.id) { index, item in
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
                        .foregroundStyle(Color.primary)
                        .accessibilityHint("Shows where you join")
                } else {
                    row
                }
            }
        } header: {
            Text(LobbyContent.carsHeader(cars))
        }
    }

    func sectionLabel(_ title: String) -> some View {
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
    func ownWayTile(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
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

    /// The viewer's car colour for their own route on the map preview.
    var locationGranted: Bool { location.status == .whenInUse || location.status == .always }

    var ownCarColor: String { session.car?.color ?? sampleCarColor }

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
struct QRCodeSheet: View {
    var code: String
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: Spacing.m) {
            if let image = QRCode.image(for: LobbyLogic.joinURL(code: code)) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 260, maxHeight: 260)
                    .padding(Spacing.m)
                    .background(.white, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    .accessibilityLabel("QR code to join with code \(code)")
            }
            Text(LobbyLogic.displayCode(code))
                .font(.system(.title2, design: .monospaced).weight(.bold))
                .kerning(2)
            Text("Scan to join").font(.subheadline).foregroundStyle(Color.surfaceSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            SheetCloseButton(action: { dismiss() }).buttonSurface(.glass).padding(Spacing.m)
        }
        .presentationDetents([.medium])
    }
}
