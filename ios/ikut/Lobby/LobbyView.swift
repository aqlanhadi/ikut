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
    @State private var model: LobbyModel
    @State private var session: TripSession
    @State private var routeInfo = TripRouteInfo()
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

    init(tripId: String, onExit: @escaping () -> Void, onEnded: @escaping (String) -> Void = { _ in }) {
        self.onExit = onExit
        self.onEnded = onEnded
        _model = State(initialValue: LobbyModel(tripId: tripId))
        _session = State(initialValue: TripSession(
            tripId: tripId, userId: Auth.auth().currentUser?.uid ?? ""))
    }

    private var isOrganizer: Bool {
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
        guard let trip = model.trip else { return }
        let names = Dictionary(model.members.compactMap { m in m.id.map { ($0, m.displayName) } }, uniquingKeysWith: { a, _ in a })
        PastTrips.record(tripId: model.tripId, name: trip.name, destination: trip.destination.name, endedAt: trip.endedAt,
                         others: names.isEmpty ? nil : PastTrips.others(from: names, excluding: currentUserId))
    }

    private var canLeave: Bool { !session.isEnded && !session.membershipLost }
    private var canEnd: Bool { isOrganizer && !session.isEnded }
    /// Rename and change destination: the organizer, before the trip ends.
    private var canEdit: Bool { isOrganizer && !session.isEnded && !session.membershipLost }
    /// Pause and resume are for the phone that is broadcasting (or paused while it was).
    private var canPause: Bool { (session.isTracking || session.isPaused) && !session.isEnded && !session.membershipLost }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                statusBanner
                if session.isPaused && !session.isEnded && !session.membershipLost {
                    PausedBanner(session: session, onError: { actionError = $0 })
                        .padding(.bottom, 4)
                }
                if let trip = model.trip {
                    tripCard(trip)
                    inviteCard(trip.code)
                        .padding(.top, 12)
                    carsHeader
                    carsCard
                    if let actionError {
                        Text(actionError)
                            .font(.footnote).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.top, 12)
                    }
                } else if let message = model.errorMessage {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.top, 20)
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Color.ikutScreen)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            let catchUp = LobbyLogic.catchUpLine(model.groupedCars)
            let started = isStarted
            Button {
                if !started {
                    startedHere = true
                    Task { await TripService.markStarted(tripId: model.tripId) }
                }
                showMap = true
            } label: {
                VStack(spacing: 0) {
                    Text(started ? "Back to Map" : "Start Trip")
                    if let catchUp, !started {
                        Text(catchUp).font(.caption).opacity(0.85)
                    }
                }
            }
            .buttonStyle(PillButtonStyle())
            .accessibilityLabel(started ? "Back to Map" : "Start Trip")
            .accessibilityHint(started ? "" : (catchUp ?? ""))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.ikutScreen)
        }
        // The map shares this lobby's session; the lobby stays on the stack underneath it.
        .navigationDestination(isPresented: $showMap) {
            TripMapView(session: session, onExit: onExit, onEnded: { onEnded(model.tripId) })
        }
        .navigationDestination(isPresented: $showChangeDestination) {
            CreateTripView(changingTripId: model.trip?.id) { _ in showChangeDestination = false }
        }
        .navigationTitle("Trip Lobby")
        .onChange(of: session.isEnded, initial: true) { _, ended in
            if ended { onEnded(model.tripId) }
        }
        .onChange(of: model.trip, initial: true) { _, _ in recordPastTrip() }
        .onChange(of: model.members, initial: true) { _, _ in recordPastTrip() }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.trip?.route) {
            if let route = model.trip?.route { await routeInfo.load(route: route) }
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
            get: { TripSessionLogic.explainerVisible(wanted: session.alwaysExplainerShowing, askShowing: session.askShowing) },
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
            VStack(spacing: 2) {
                Label("Trip in progress", systemImage: "car.fill")
                    .font(.footnote.weight(.semibold))
                if let since = LobbyLogic.onTheRoadLine(startedAt: model.trip?.startedAt ?? model.trip?.createdAt) {
                    Text(since).font(.caption)
                }
            }
            .foregroundStyle(Color.ikutPositive)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.ikutPositive.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            .padding(.bottom, 4)
            .accessibilityElement(children: .combine)
        } else if session.isTracking && !session.isPaused {
            Label("Sharing location", systemImage: "location.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ikutPositive)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.ikutPositive.opacity(0.15), in: Capsule())
                .padding(.bottom, 4)
        }
    }

    private func exitBanner(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 12) {
            Label(title, systemImage: systemImage).font(.headline)
            Button("Back to Home", action: onExit).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .ikutCard()
        .padding(.bottom, 8)
    }

    /// Route preview, name, FROM → TO and the distance, drive and road stats.
    private func tripCard(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            routePreview
                .frame(height: 104)
                .overlay(alignment: .topLeading) {
                    if canEdit {
                        Button { showChangeDestination = true } label: {
                            Label("Change destination", systemImage: "magnifyingglass")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.ikutAccent)
                                .padding(.horizontal, 11)
                                .frame(minHeight: 30)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if isStarted {
                        StatusPill(text: "On the move", color: .ikutPositive, dot: .green)
                            .padding(10)
                    } else if !session.isEnded {
                        StatusPill(text: "Gathering", color: .ikutWarning, dot: .orange)
                            .padding(10)
                    }
                }
            VStack(alignment: .leading, spacing: 10) {
                Text(trip.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                RouteEnds(from: routeInfo.originName, to: trip.destination.name)
                    .padding(.top, -6)
                StatGrid([
                    .init("Distance", routeInfo.distance.map(RouteFormat.distance)),
                    .init("Drive", routeInfo.travelTime.map(RouteFormat.shortDuration)),
                    .init("Via", routeInfo.roadName.flatMap { $0.isEmpty ? nil : $0 }),
                ], background: Color.ikutScreen)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .ikutCard()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var routePreview: some View {
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
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        // The camera fits the route only when the map is built, so rebuild once the route loads.
        .id(coords.count)
        .accessibilityHidden(true)
    }

    private func inviteCard(_ code: String) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                StatCaption("Join code")
                Text(LobbyLogic.displayCode(code))
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .kerning(2)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityLabel("Join code \(code.map(String.init).joined(separator: " "))")
                // The share sheet also offers Copy, so there's no separate copy button.
                ShareLink(item: LobbyLogic.shareText(code: code)) {
                    Label("Share invite", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(Color.ikutAccent, in: Capsule())
                }
                .padding(.top, 6)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            DashedDivider()
                .padding(.vertical, 12)

            VStack(spacing: 4) {
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
        return HStack(spacing: 10) {
            Text("CARS")
                .accessibilityAddTraits(.isHeader)
            if cars.isEmpty {
                Spacer()
            } else {
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
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var carsCard: some View {
        let cars = model.groupedCars
        return VStack(spacing: 0) {
            if cars.isEmpty {
                Text("No cars yet")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            ForEach(Array(cars.enumerated()), id: \.element.id) { index, item in
                if index > 0 { RowDivider() }
                CarRow(item: item, position: index + 1, currentUserId: currentUserId)
            }
        }
        .ikutCard()
    }
}

private struct CarRow: View {
    let item: LobbyCar
    /// 1-based place in the list, used when the car has no number of its own.
    let position: Int
    let currentUserId: String?

    var body: some View {
        HStack(spacing: 12) {
            CarBadge(number: item.car.number ?? position, colorHex: item.car.color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.car.name)
                    if item.car.isLead {
                        Text("Lead")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.fill.secondary, in: Capsule())
                    }
                }
                Text(people)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            let color = item.hasTracker ? Color.ikutPositive : Color.ikutWarning
            Text(item.hasTracker ? "Tracking" : "Waiting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    private var people: String {
        LobbyLogic.peopleLine(
            members: item.members, trackerUserId: item.car.trackerUserId, currentUserId: currentUserId)
    }
}

/// Display strings for the lobby (kept here so the logic file stays untouched).
extension LobbyLogic {
    /// "K7M2QX" shown as "K7M 2QX".
    static func displayCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// Under Start Trip while some cars have no tracker: "Daniel can catch up on the road",
    /// "Daniel and Siti can…", "3 cars can…". Nil when every car is tracked.
    static func catchUpLine(_ cars: [LobbyCar]) -> String? {
        let waiting = cars.filter { !$0.hasTracker }
        guard !waiting.isEmpty else { return nil }
        let names = waiting.map { $0.members.first?.displayName ?? $0.car.name }
        let who = switch names.count {
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: "\(names.count) cars"
        }
        return "\(who) can catch up on the road"
    }

    /// "You (organizer, tracker) · Siti", "Wyna (tracker) · 3 others", "Daniel · no tracker yet".
    static func peopleLine(members: [Member], trackerUserId: String?, currentUserId: String?) -> String {
        guard !members.isEmpty else { return "No one yet" }
        let ordered = members.filter { $0.id == currentUserId } + members.filter { $0.id != currentUserId }
        func label(_ m: Member) -> String {
            var roles: [String] = []
            if m.role == .organizer { roles.append("organizer") }
            if let id = m.id, id == trackerUserId { roles.append("tracker") }
            let name = m.id == currentUserId ? "You" : m.displayName
            return roles.isEmpty ? name : "\(name) (\(roles.joined(separator: ", ")))"
        }
        var parts: [String]
        if ordered.count <= 2 {
            parts = ordered.map(label)
        } else {
            parts = ordered.prefix(1).map(label)
            parts.append("\(ordered.count - 1) others")
        }
        if trackerUserId == nil { parts.append("no tracker yet") }
        return parts.joined(separator: " · ")
    }
}
