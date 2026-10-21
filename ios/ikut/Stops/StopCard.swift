import Observation
import SwiftUI

/// What the stop card is showing and remembering while it is open. A new model per opening, so
/// the "Are you a passenger?" answer lasts only until the card closes.
@MainActor @Observable
final class StopCardModel {
    enum Screen: Equatable {
        /// What the board says: ask, or the open request(s).
        case home
        /// The place list for another place on an open request.
        case places(eventId: String)
        /// "Are you a passenger?", before the place list on a moving phone.
        case passengerCheck
        /// The lead car or organizer is about to pin a place other than the asked one.
        case confirmPin(eventId: String, place: StopPlace)
    }

    var screen: Screen = .home
    /// The request being made: reason tiles, then the place list.
    let ask: RequestStopModel
    /// The places for another place on an open request.
    var suggest: RequestStopModel?
    var session = StopCardSession()
    /// When the countdown sends the request; nil while it isn't counting.
    var sendAt: Date?
    /// Sent; waiting for the request to show up on the board.
    var sentWaiting = false

    private let context: StopContext
    private let service: any StopServing
    private let searcher: any PlaceSearching

    init(context: StopContext, service: any StopServing, searcher: any PlaceSearching) {
        self.context = context
        self.service = service
        self.searcher = searcher
        ask = RequestStopModel(context: context, service: service, searcher: searcher)
    }

    func startSuggesting(for state: StopRequestState) {
        suggest = RequestStopModel(context: context, existing: state, service: service, searcher: searcher)
        screen = .places(eventId: state.eventId)
    }

    func backHome() {
        screen = .home
        suggest = nil
    }
}

/// The stop card, layered on top of the convoy panel. It opens only when someone taps the Pit stop
/// button, and closes by itself when the stop closes. What it shows follows the board:
/// ask (tiles, then the places with a countdown), the asker's timeline, a request from another car,
/// the lead car's votes and pin, at the stop, and read only while the car moves.
struct StopCard: View {
    let board: StopBoard
    let context: StopContext
    /// This phone is in a moving car (`DrivingDetector`).
    let driving: Bool
    let actions: StopRequestActions
    var onClose: () -> Void

    @State private var model: StopCardModel
    /// Seconds before an ask goes out by itself.
    private let countdown: TimeInterval

    static let autoSendDelay: TimeInterval = 5

    init(
        board: StopBoard, context: StopContext, driving: Bool, actions: StopRequestActions,
        service: any StopServing = StopService(), searcher: any PlaceSearching = MapKitPlaceSearcher(),
        countdown: TimeInterval = StopCard.autoSendDelay, demoScreen: String? = nil,
        onClose: @escaping () -> Void
    ) {
        self.board = board
        self.context = context
        self.driving = driving
        self.actions = actions
        self.countdown = countdown
        self.onClose = onClose
        let model = StopCardModel(context: context, service: service, searcher: searcher)
        #if DEBUG
        model.applyDemo(demoScreen, board: board)
        #endif
        _model = State(initialValue: model)
    }

    private var mode: StopCardGate.Mode {
        StopCardGate.mode(driving: driving, session: model.session, hasOpenStop: !board.requests.isEmpty)
    }

    /// The search is done and nothing is in flight: the request goes by itself after the countdown.
    private var readyToSend: Bool {
        model.screen == .home && board.requests.isEmpty && !model.sentWaiting && model.ask.isReadyToAutoSend
    }

    var body: some View {
        screen
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.height > 60, abs(value.translation.width) < value.translation.height { onClose() }
                })
            .onChange(of: readyToSend, initial: true) { _, ready in
                model.sendAt = ready ? Date().addingTimeInterval(countdown) : nil
            }
            .onChange(of: model.ask.picked) {
                // Picking another place restarts the countdown so there's time to see it.
                if readyToSend { model.sendAt = Date().addingTimeInterval(countdown) }
            }
            .task(id: model.sendAt) {
                guard let sendAt = model.sendAt else { return }
                try? await Task.sleep(for: .seconds(max(0, sendAt.timeIntervalSinceNow)))
                guard !Task.isCancelled, model.sendAt == sendAt else { return }
                send()
            }
            .task(id: model.sentWaiting) {
                guard model.sentWaiting else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { model.sentWaiting = false }
            }
            .onChange(of: board.requests.map(\.eventId)) { _, ids in
                if !ids.isEmpty {
                    // A request is open, mine or someone's: whatever was being asked is over.
                    model.sentWaiting = false
                    model.sendAt = nil
                    model.ask.clearReason()
                }
                switch model.screen {
                case .places(let id) where !ids.contains(id): model.backHome()
                case .confirmPin(let id, _) where !ids.contains(id): model.backHome()
                default: break
                }
            }
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .home: home
        case .places(let id): placesScreen(eventId: id)
        case .passengerCheck: passengerScreen
        case .confirmPin(let id, let place): confirmPinScreen(eventId: id, place: place)
        }
    }

    @ViewBuilder private var home: some View {
        if board.requests.isEmpty {
            if model.sentWaiting {
                sentScreen
            } else if let reason = model.ask.reason {
                if mode == .driverAsk { driverConfirmScreen(reason) } else { askPlacesScreen(reason) }
            } else {
                tilesScreen
            }
        } else if mode == .readOnly {
            readOnlyScreen
        } else if board.requests.count == 1 {
            requestScreen(board.requests[0])
        } else {
            multiScreen
        }
    }

    // MARK: Ask

    private var tilesScreen: some View {
        StopCardFrame(title: "Ask to stop", subtitle: "One tap. We’ll find the next good place.", onClose: onClose) {
            if let missed = board.missed { missedNotice(missed) }
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Spacing.gap), GridItem(.flexible(), spacing: Spacing.gap)],
                spacing: Spacing.gap
            ) {
                ForEach(StopReason.all) { reason in
                    Button { model.ask.choose(reason) } label: {
                        VStack(spacing: Spacing.s) {
                            StopReasonIcon(symbol: reason.symbol, size: 44)
                            Text(reason.label).font(.headline).foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 92)
                        .ikutTile()
                        .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stop.reason.\(reason.type.rawValue)")
                }
            }
        } actions: {}
    }

    private func missedNotice(_ missed: StopRequestState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("No answer").font(.body.weight(.semibold))
            Text("Nobody pinned a place for the \(StopLogic.reasonLabel(missed.type).lowercased()) stop in 10 minutes.")
                .font(.footnote).foregroundStyle(.secondary)
            StopActionButton(title: "Ask again", style: .secondary, height: 44, id: "stop.askAgain") {
                model.ask.choose(StopReason.all.first { $0.type == missed.type } ?? StopReason.all[3])
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutTile()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.noAnswer")
    }

    private func askPlacesScreen(_ reason: StopReason) -> some View {
        StopCardFrame(title: reason.label, subtitle: "The best place is picked. Change it if you like.", onClose: onClose) {
            placeList(model.ask)
        } actions: {
            if case .failed(let message) = model.ask.sending {
                Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            countdownButton
            if model.sendAt != nil {
                StopActionButton(title: "Send now", style: .ghost, height: 44, id: "stop.send") { send() }
            }
        }
    }

    /// The main action while asking: it fills up as the countdown runs, and tapping it is Undo.
    private var countdownButton: some View {
        Button {
            if model.sendAt != nil {
                undoSend()
            } else {
                send()
            }
        } label: {
            TimelineView(.animation(minimumInterval: 0.1, paused: model.sendAt == nil)) { timeline in
                let left = model.sendAt.map { max(0, $0.timeIntervalSince(timeline.date)) }
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.ikutAccent)
                    if let left {
                        GeometryReader { proxy in
                            Capsule()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: proxy.size.width * (1 - left / countdown))
                        }
                    }
                    Group {
                        if model.ask.sending == .sending {
                            ProgressView().tint(.white)
                        } else if let left {
                            Text("Sending in \(Int(left.rounded(.up))) s · Undo")
                        } else {
                            Text("Send now")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(height: 50)
                .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .disabled(!model.ask.canSend && model.sendAt == nil)
        .accessibilityLabel(model.sendAt == nil ? "Send now" : "Undo")
        .accessibilityHint(model.sendAt == nil ? "" : "Stops the request from being sent")
        .accessibilityIdentifier("stop.countdown")
    }

    /// The driver's version: the best place read back, a huge Send now, Cancel. Never the place list.
    private func driverConfirmScreen(_ reason: StopReason) -> some View {
        let chosen = model.ask.chosen
        return StopCardFrame(
            title: chosen.map { "\(reason.label) at \($0.name)" } ?? reason.label,
            subtitle: driverSubtitle, onClose: onClose
        ) {
            HStack(spacing: Spacing.m) {
                TimelineView(.animation(minimumInterval: 0.2, paused: model.sendAt == nil)) { timeline in
                    let left = model.sendAt.map { max(0, $0.timeIntervalSince(timeline.date)) }
                    Text(left.map { "\(Int($0.rounded(.up)))" } ?? "·")
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.ikutAccent)
                        .frame(width: 56, height: 56)
                        .overlay(Circle().strokeBorder(Color.ikutAccent, lineWidth: 3))
                }
                .accessibilityIdentifier("stop.ring")
                Text(model.sendAt == nil ? "Waiting for the best place." : "Sending by itself. Tap Cancel to stop it.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if case .failed(let message) = model.ask.sending {
                Text(message).font(.footnote).foregroundStyle(.red)
            }
        } actions: {
            StopActionButton(title: "Send now", style: .primary, height: 72, disabled: !model.ask.canSend, id: "stop.send") {
                send()
            }
            StopActionButton(title: "Cancel", style: .ghost, height: 44, id: "stop.cancelAsk") { undoSend() }
            StopActionButton(title: "Choose another place", style: .ghost, height: 44, id: "stop.anotherPlace") {
                model.sendAt = nil
                model.screen = .passengerCheck
            }
        }
    }

    private var driverSubtitle: String {
        switch model.ask.search {
        case .idle, .loading: "Finding the next good place…"
        case .failed: "The lead car chooses where"
        case .loaded: model.ask.chosen.map { "\($0.whereText) · \($0.costText.lowercased())" } ?? "The lead car chooses where"
        }
    }

    private var sentScreen: some View {
        StopCardFrame(title: "Asked the convoy", subtitle: "Waiting for the other cars", onClose: onClose) {
            Text("The lead car pins the place once the cars have answered.")
                .font(.subheadline).foregroundStyle(.secondary)
        } actions: {}
    }

    private func send() {
        model.sendAt = nil
        Task {
            if await model.ask.send() {
                model.sentWaiting = true
                model.ask.clearReason()
            }
        }
    }

    private func undoSend() {
        model.sendAt = nil
        model.ask.clearReason()
    }

    // MARK: Place list (shared by asking and "Another place")

    @ViewBuilder private func placeList(_ list: RequestStopModel) -> some View {
        switch list.search {
        case .idle, .loading:
            HStack(spacing: Spacing.gap) {
                ProgressView()
                Text("Finding the next good place…").foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.section)
            .frame(maxWidth: .infinity)
        case .failed:
            note(list.existing == nil
                ? "Could not find places along the route. You can still ask; the lead car chooses where."
                : "Could not find places along the route.")
        case .loaded where list.candidates.isEmpty:
            note(list.existing == nil
                ? "No places found 15 to 25 km ahead. You can still ask; the lead car chooses where."
                : "No places found ahead.")
        case .loaded:
            Text("Ahead on the route").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs)
            ForEach(list.candidates) { candidate in candidateRow(candidate, in: list) }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ikutTile()
    }

    private func candidateRow(_ candidate: StopCandidate, in list: RequestStopModel) -> some View {
        let selected = list.picked == candidate.id
        return Button { list.picked = candidate.id } label: {
            HStack(spacing: Spacing.m) {
                IconTile(symbol: list.reason?.symbol ?? "mappin", color: .orange, size: 34, radius: Radius.iconLarge)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text(candidate.whereText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(candidate.costText).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.gap)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(candidate.name), \(candidate.whereText), \(candidate.costText)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("stop.place.\(candidate.id)")
    }

    // MARK: One open request

    @ViewBuilder private func requestScreen(_ state: StopRequestState) -> some View {
        if state.isPinned {
            pinnedScreen(state)
        } else if state.canPin && !StopLogic.viewerIsRequester(state) {
            leadScreen(state)
        } else if StopLogic.viewerIsRequester(state) {
            askerScreen(state)
        } else {
            responderScreen(state)
        }
    }

    private func subtitle(_ state: StopRequestState) -> String { state.subtitle(now: Date()) }

    private func placeTile(_ state: StopRequestState, detail: String? = nil) -> some View {
        StopPlaceTile(
            name: state.shownPlace?.name ?? "No place yet",
            detail: detail ?? StopLogic.placeLine(state).replacingOccurrences(of: (state.shownPlace?.name ?? "") + " · ", with: ""),
            trailing: nil)
    }

    private func askerScreen(_ state: StopRequestState) -> some View {
        StopCardFrame(title: state.title, subtitle: subtitle(state), onClose: onClose) {
            StopTimeline(state: state)
        } actions: {
            StopActionButton(title: "Cancel request", style: .secondary, id: "stop.cancel") {
                actions.close(state.eventId, .cancelled)
            }
        }
    }

    private func responderScreen(_ state: StopRequestState) -> some View {
        StopCardFrame(title: state.title, subtitle: subtitle(state), onClose: onClose) {
            placeTile(state, detail: placeDetail(state, note: "not pinned yet"))
            ForEach(state.rows) { StopVoterRow(row: $0) }
        } actions: {
            answerButtons(state, suffix: "")
            StopActionButton(title: "Another place", style: .secondary, id: "stop.anotherPlace") {
                model.startSuggesting(for: state)
            }
        }
    }

    /// "Yes for our car" and "Not now": the car's own answer shows as the chosen one.
    @ViewBuilder private func answerButtons(_ state: StopRequestState, suffix: String) -> some View {
        let yes = state.myAnswer == .yes
        let no = state.myAnswer == .notNow
        StopActionButton(
            title: yes ? "Said yes for our car" : "Yes for our car", style: yes ? .positive : .primary, id: "stop.yes\(suffix)"
        ) { actions.answer(state.eventId, .yes) }
        StopActionButton(
            title: "Not now", style: no ? .positive : .secondary, id: "stop.notNow\(suffix)"
        ) { actions.answer(state.eventId, .notNow) }
    }

    private func placeDetail(_ state: StopRequestState, note: String) -> String {
        [state.distanceText, state.etaText?.replacingOccurrences(of: "About ", with: ""), note]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func leadScreen(_ state: StopRequestState) -> some View {
        StopCardFrame(title: state.title, subtitle: subtitle(state), onClose: onClose) {
            if state.shownPlace != nil { placeTile(state, detail: placeDetail(state, note: "not pinned yet")) }
            ForEach(state.rows) { StopVoterRow(row: $0) }
        } actions: {
            if let proposal = state.proposal {
                StopActionButton(title: "Pin \(proposal.name)", style: .primary, id: "stop.pin") {
                    actions.pin(state.eventId, proposal)
                }
            }
            ForEach(state.alternatives) { row in
                if let suggestion = row.suggestion {
                    StopActionButton(title: "Pin \(suggestion.name)", style: .secondary, id: "stop.pinSuggested") {
                        model.screen = .confirmPin(eventId: state.eventId, place: suggestion)
                    }
                }
            }
            StopActionButton(
                title: "Another place", style: state.proposal == nil ? .primary : .secondary, id: "stop.anotherPlace"
            ) { model.startSuggesting(for: state) }
            if state.isAuthor {
                StopActionButton(title: "Cancel request", style: .ghost, height: 44, id: "stop.cancel") {
                    actions.close(state.eventId, .cancelled)
                }
            }
        }
    }

    /// Heading there, then at the stop: each car is Here or says how far it is; the lead car or
    /// organizer sends everyone on with Leave now.
    private func pinnedScreen(_ state: StopRequestState) -> some View {
        let place = state.place?.name ?? "the stop"
        let allHere = !state.rows.isEmpty && state.hereCount == state.rows.count
        let by = state.pinnedByName.map { "pinned by \($0)" } ?? "pinned by the organizer"
        return StopCardFrame(
            title: allHere ? "At \(place)" : "Heading to \(place)",
            subtitle: "\(StopLogic.reasonLabel(state.type)) stop · \(state.hereCount) of \(state.rows.count) here",
            onClose: onClose
        ) {
            StopPlaceTile(
                name: place,
                detail: [state.viewerMinutes.map { "\($0) min" }, by].compactMap { $0 }.joined(separator: " · "),
                trailing: nil)
            ForEach(state.rows) { StopVoterRow(row: $0) }
        } actions: {
            if state.canPin {
                StopActionButton(title: "Leave now", style: .primary, id: "stop.leave") {
                    actions.close(state.eventId, .left)
                }
            }
        }
    }

    // MARK: Two or more open requests

    private var multiScreen: some View {
        StopCardFrame(title: "\(board.requests.count) stops open", subtitle: "Answer each one.", onClose: onClose) {
            ForEach(Array(board.requests.enumerated()), id: \.element.eventId) { index, state in
                miniRequest(state, suffix: ".\(index)")
            }
        } actions: {}
    }

    private func miniRequest(_ state: StopRequestState, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                StopReasonIcon(symbol: StopLogic.reasonSymbol(state.type), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.body.weight(.semibold)).lineLimit(2)
                    Text(StopLogic.placeLine(state)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            if state.isPinned {
                if state.canPin {
                    StopActionButton(title: "Leave now", style: .primary, height: 44, id: "stop.leave\(suffix)") {
                        actions.close(state.eventId, .left)
                    }
                } else {
                    Text(StopLogic.statusLine(state)).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
                }
            } else if StopLogic.viewerIsRequester(state) {
                Text(StopLogic.decidingText(state)).font(.footnote).foregroundStyle(.secondary)
                StopActionButton(title: "Cancel request", style: .secondary, height: 44, id: "stop.cancel\(suffix)") {
                    actions.close(state.eventId, .cancelled)
                }
            } else if state.canPin {
                if let proposal = state.proposal {
                    StopActionButton(title: "Pin \(proposal.name)", style: .primary, height: 44, id: "stop.pin\(suffix)") {
                        actions.pin(state.eventId, proposal)
                    }
                }
            } else {
                HStack(spacing: Spacing.s) {
                    StopActionButton(
                        title: state.myAnswer == .yes ? "Said yes" : "Yes", style: state.myAnswer == .yes ? .positive : .primary,
                        height: 44, id: "stop.yes\(suffix)"
                    ) { actions.answer(state.eventId, .yes) }
                    StopActionButton(
                        title: "Not now", style: state.myAnswer == .notNow ? .positive : .secondary, height: 44,
                        id: "stop.notNow\(suffix)"
                    ) { actions.answer(state.eventId, .notNow) }
                }
            }
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutTile()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.request\(suffix)")
    }

    // MARK: Driving

    /// While the car moves: status, place and time, nothing to change. A passenger can say so.
    private var readOnlyScreen: some View {
        let single = board.requests.count == 1 ? board.requests[0] : nil
        return StopCardFrame(
            title: single?.title ?? "\(board.requests.count) stops open",
            subtitle: single.map(StopLogic.statusLine), onClose: onClose
        ) {
            ForEach(board.requests, id: \.eventId) { state in
                StopPlaceTile(
                    name: state.shownPlace?.name ?? "No place yet",
                    detail: board.requests.count == 1
                        ? placeDetail(state, note: state.isPinned ? "pinned" : "not pinned yet")
                        : "\(state.title) · \(StopLogic.statusLine(state))",
                    trailing: nil)
            }
            Text("Stop and park to change anything.").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("stop.readOnlyNote")
        } actions: {
            StopActionButton(title: "I’m a passenger", style: .secondary, id: "stop.passenger") {
                model.session.confirmPassenger()
            }
        }
    }

    private var passengerScreen: some View {
        StopCardFrame(title: "Search places", subtitle: "This phone is moving", onClose: onClose) {
            StopPassengerCheck()
        } actions: {
            StopActionButton(title: "I’m a passenger", style: .primary, height: 60, id: "stop.passenger") {
                model.session.confirmPassenger()
                model.screen = .home
            }
            StopActionButton(title: "I’m driving", style: .secondary, id: "stop.driving") {
                model.session.confirmDriving()
                model.screen = .home
            }
        }
    }

    // MARK: Another place

    @ViewBuilder private func placesScreen(eventId: String) -> some View {
        if let state = board.requests.first(where: { $0.eventId == eventId }), let list = model.suggest {
            StopCardFrame(
                title: "Another place",
                subtitle: state.canPin ? "Pick the place to pin." : "Pick a place ahead. The lead car pins the final stop.",
                onClose: onClose
            ) {
                placeList(list)
            } actions: {
                if case .failed(let message) = list.sending {
                    Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                StopActionButton(
                    title: list.sendLabel, style: .primary, disabled: !list.canSend, id: "stop.sendPlace"
                ) { choose(list, for: state) }
                StopActionButton(title: "Back", style: .ghost, height: 44, id: "stop.back") { model.backHome() }
            }
        } else {
            Color.clear.frame(height: 0).onAppear { model.backHome() }
        }
    }

    private func choose(_ list: RequestStopModel, for state: StopRequestState) {
        guard let place = list.chosen?.place else { return }
        if state.canPin {
            if place.name == state.proposal?.name {
                actions.pin(state.eventId, place)
                model.backHome()
            } else {
                model.screen = .confirmPin(eventId: state.eventId, place: place)
            }
        } else {
            Task {
                if await list.send() { model.backHome() }
            }
        }
    }

    /// "Pin Petronas Bidor?" with the cost, and the line the asker gets.
    @ViewBuilder private func confirmPinScreen(eventId: String, place: StopPlace) -> some View {
        if let state = board.requests.first(where: { $0.eventId == eventId }) {
            let lead = state.rows.first { $0.isMine }.map { StopLogic.ownerName(fromCarName: $0.name.replacingOccurrences(of: " (you)", with: "")) } ?? "The lead car"
            let distance = state.viewerOffset.map { place.routeOffset - $0 }
            let cost = distance.map { d in
                d < 0
                    ? "Passed \(ConvoyFormat.distance(-d)) back · you turn back"
                    : "\(ConvoyFormat.distance(d)) ahead · \(StopLogic.minutes(forMeters: d)) min"
            }
            StopCardFrame(title: "Pin \(place.name)?", subtitle: cost, onClose: onClose) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    StatCaption("What \(state.requesterName) sees")
                    Text("“\(StopLogic.chosenLine(leadName: lead, place: place, state: state))”")
                        .font(.subheadline.weight(.semibold))
                }
                .padding(Spacing.cozy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ikutTile()
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stop.confirmLine")
            } actions: {
                HStack(spacing: Spacing.s) {
                    StopActionButton(title: "Cancel", style: .secondary, id: "stop.confirmCancel") { model.backHome() }
                    StopActionButton(title: "Pin it", style: .primary, id: "stop.confirmPin") {
                        actions.pin(eventId, place)
                        model.backHome()
                    }
                }
            }
        } else {
            Color.clear.frame(height: 0).onAppear { model.backHome() }
        }
    }
}
