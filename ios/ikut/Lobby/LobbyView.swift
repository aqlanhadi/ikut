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
    /// A participant's own trip: their start, where they join, their distance and drive time (D26).
    @State private var ownWay = OwnWayInfo()
    @State private var planner: StopPlanner
    @State private var showAddStop = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showChangeDestination = false
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var actionError: String?
    @State private var showMap = false
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
    private var canEnd: Bool { isOrganizer && !session.isEnded }
    /// Rename and change destination: the organizer, before the trip ends.
    private var canEdit: Bool { isOrganizer && canLeave }
    /// Change destination: the organizer, until the trip ends (mid-trip it rebuilds the route from where they are).
    private var canChangeDestination: Bool {
        LobbyLogic.canChangeDestination(canEdit: canEdit)
    }
    /// Add, move and remove stops: the organizer, before the trip has started.
    private var canEditStops: Bool { canEdit && !isStarted }
    /// Pause and resume are for the phone that is broadcasting (or paused while it was).
    private var canPause: Bool { (session.isTracking || session.isPaused) && canLeave }

    var body: some View {
        // A List, not a ScrollView of cards: the stops need its drag to reorder and swipe to remove. Each block of
        // the lobby is a row; the route card is several rows drawn as one card.
        List {
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
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let started = isStarted
            Button {
                if !started {
                    startedHere = true
                    Task { await TripService.markStarted(tripId: model.tripId) }
                }
                showMap = true
            } label: {
                Text(started ? "Back to Map" : "Start Trip").frame(maxWidth: .infinity)
            }
            .actionButton(.primary)
            .ikutBottomBar()
        }
        // The map shares this lobby's session; the lobby stays on the stack underneath it.
        .navigationDestination(isPresented: $showMap) {
            TripMapView(session: session, onExit: onExit, onEnded: { onEnded(model.tripId) })
        }
        .navigationDestination(isPresented: $showChangeDestination) {
            CreateTripView(
                changingTripId: model.trip?.id, keepingStops: planner.items,
                midTrip: LobbyLogic.isStarted(trip: model.trip) ? { [session] in try await session.rebuilder.changeDestination(to: $0) } : nil
            ) { _ in showChangeDestination = false }
        }
        .navigationTitle("Trip Lobby")
        .onChange(of: session.isEnded, initial: true) { _, ended in
            if ended { onEnded(model.tripId) }
        }
        .onChange(of: model.trip, initial: true) { _, _ in
            recordPastTrip()
            syncPlanner()
        }
        .onChange(of: model.stops) { _, _ in syncPlanner() }
        .sheet(isPresented: $showAddStop) {
            AddStopSheet(
                along: routeInfo.coordinates.count > 1
                    ? AlongRoute(coordinates: routeInfo.coordinates, seconds: routeInfo.travelTime) : nil,
                canMeet: StopListLogic.canMeet(among: planner.items),
                onAdd: { planner.add($0) })
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
                destination: CLLocationCoordinate2D(latitude: trip.destination.coordinate.latitude, longitude: trip.destination.coordinate.longitude),
                destinationName: trip.destination.name, car: car,
                meetingPoint: TripSessionLogic.meetingPoint(in: model.stops), routeSeconds: trip.routeSeconds,
                phone: { granted ? try? await RouteBuilder.currentLocation() : nil })
        }
        .alert("Trip name", isPresented: $renaming) {
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
            if canLeave || canEnd || canPause {
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
                        if canEnd {
                            Button("End trip", systemImage: "flag.checkered", role: .destructive) { confirmEnd = true }
                        }
                        if canLeave {
                            Button("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                confirmLeave = true
                            }
                        }
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
            get: { TripSessionLogic.explainerVisible(wanted: session.alwaysExplainerShowing, askShowing: session.askShowing, mapSheetUp: session.mapSheetUp) },
            set: { if !$0 { session.alwaysExplainerShowing = false } }
        )) {
            // Declining is fine: the background activity session keeps tracking alive on When In Use.
            AlwaysLocationExplainerView(permission: location) { _ in session.alwaysExplainerShowing = false }
        }
        .confirmationDialog("Leave this trip?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave trip", role: .destructive) { run { try await session.leave(); onExit() } }
        } message: {
            Text("Your phone stops sharing its location.")
        }
        .confirmationDialog("End the trip for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End trip", role: .destructive) { run { try await session.endTrip() } }
        } message: {
            Text("Everyone stops sharing their location. This can't be undone.")
        }
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
            exitBanner("You're no longer in this trip", systemImage: "person.fill.xmark")
        } else if isStarted {
            VStack(spacing: Spacing.xxs) {
                Label("Trip in progress", systemImage: "car.fill")
                    .font(.footnote.weight(.semibold))
                if let since = LobbyLogic.onTheRoadLine(startedAt: model.trip?.startedAt ?? model.trip?.createdAt) {
                    Text(since).font(.caption)
                }
            }
            .foregroundStyle(Color.ikutPositive)
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.tight)
            .background(Color.ikutPositive.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.control))
            .padding(.bottom, Spacing.xs)
            .accessibilityElement(children: .combine)
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
            Button("Back to Home", action: onExit).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.l)
        .ikutCard()
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
        routePreview(stops: stops)
            .frame(height: 104)
            .overlay(alignment: .topLeading) {
                if canEdit {
                    HStack(spacing: Spacing.tight) {
                        if canChangeDestination {
                            Button { showChangeDestination = true } label: {
                                pill("Change destination", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.plain)
                        }
                        if canEditStops {
                            Button { showAddStop = true } label: {
                                pill("Add a stop", systemImage: "plus")
                            }
                            .buttonStyle(.plain)
                            .disabled(!StopListLogic.canAdd(among: stops))
                            .accessibilityIdentifier("stops.add")
                        }
                    }
                    .padding(Spacing.gap)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isStarted {
                    StatusPill(text: "On the move", color: .ikutPositive, dot: .green)
                        .padding(Spacing.gap)
                } else if !session.isEnded {
                    StatusPill(text: "Gathering", color: .ikutWarning, dot: .orange)
                        .padding(Spacing.gap)
                }
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Radius.card, topTrailingRadius: Radius.card, style: .continuous))
            .cardSlice(top: true)
            .lobbyRow()

        VStack(alignment: .leading, spacing: Spacing.gap) {
            Text(trip.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            RouteEnds(from: isOrganizer ? routeInfo.originName : ownWay.fromName, to: trip.destination.name)
                .padding(.top, -6)
            if !isOrganizer, let line = ownWay.joinLine {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        .padding(.bottom, showStops ? 0 : Spacing.gap)
        .cardSlice()
        .lobbyRow()

        if showStops {
            let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs)) : AnyLayout(HStackLayout())
            layout {
                Text("STOPS ON THE WAY").font(.caption.weight(.semibold)).tracking(0.6).accessibilityAddTraits(.isHeader)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: Spacing.s) }
                if planner.isBuilding && canEditStops {
                    ProgressView().controlSize(.small).accessibilityLabel("Updating the route")
                } else if canEditStops, stops.count > 1 {
                    Text("Hold and drag to reorder").font(.footnote)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m).padding(.bottom, Spacing.tight)
            .cardSlice()
            .lobbyRow()

            if stops.isEmpty {
                Text("No stops yet. Tap Add a stop for petrol, lunch, or a place to meet.")
                    .font(.subheadline).foregroundStyle(.secondary)
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
            .cardSlice()
            .lobbyRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if canEditStops {
                    Button(role: .destructive) { planner.remove(id: stop.id) } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            .accessibilityActions {
                if canEditStops {
                    if index > 0 {
                        Button("Move up") { planner.move(from: IndexSet(integer: index), to: index - 1) }
                    }
                    if index < stops.count - 1 {
                        Button("Move down") { planner.move(from: IndexSet(integer: index), to: index + 2) }
                    }
                    Button("Remove") { planner.remove(id: stop.id) }
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

    private func routePreview(stops: [StopDraft]) -> some View {
        let coords = routeInfo.coordinates
        return Map(initialPosition: .automatic, interactionModes: []) {
            if coords.count > 1 {
                MapPolyline(coordinates: coords)
                    .stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                MapPolyline(coordinates: coords)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                Annotation("", coordinate: coords[0], anchor: .center) {
                    Circle().fill(.white).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color.blue, lineWidth: 3))
                }
                Annotation("", coordinate: coords[coords.count - 1], anchor: .center) {
                    Circle().fill(Color.blue).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                }
                ForEach(stops.filter { !$0.isMeeting }) { stop in
                    Annotation("", coordinate: stop.coordinate, anchor: .center) {
                        Circle().fill(Color.ikutAccent).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    }
                }
                if !isOrganizer, ownWay.ownRoute.count > 1 {
                    let own = Color.car(hex: ownCarColor)
                    MapPolyline(coordinates: ownWay.ownRoute)
                        .stroke(own, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                if !isOrganizer, let join = ownWay.joinCoordinate {
                    Annotation("", coordinate: join, anchor: .center) {
                        Circle().fill(Color.car(hex: ownCarColor)).frame(width: 12, height: 12)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                    }
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // The camera fits the route only when the map is built, so rebuild once the route loads.
        .id(coords.count + ownWay.ownRoute.count)
        .accessibilityHidden(true)
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
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.cozy)
                        .frame(minHeight: 36)
                        .background(Color.ikutAccent, in: Capsule())
                        // Drawn 36 pt tall, taps over 44.
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
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
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112)
        }
        .ikutCard()
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
        .ikutCard()
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

/// What the participant's own-way-in task reloads on.
private struct OwnWayTaskKey: Equatable {
    var route: String?
    var carRoute: String?
    var mergeOffset: Double?
    var loaded: Bool
    var granted: Bool
    var meeting: Bool
}
