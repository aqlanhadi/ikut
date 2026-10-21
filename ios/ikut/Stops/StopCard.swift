import MapKit
import Observation
import SwiftUI

/// What the stop card is showing and remembering while it is open. A new model per opening, so
/// the "Are you a passenger?" answer lasts only until the card closes.
@MainActor @Observable
final class StopCardModel {
    enum Screen: Equatable {
        /// What the board says: ask, or the open request(s).
        case home
        /// The place list for a new ask (search box, then places).
        case askPlaces
        /// The place list for another place on an open request.
        case places(eventId: String)
        /// "Are you a passenger?", before the place list on a moving phone.
        case passengerCheck
        /// The lead car or organizer is about to pin a place other than the asked one.
        case confirmPin(eventId: String, place: StopPlace)
    }

    var screen: Screen = .home
    /// The request being made: reason tiles, then the suggested place.
    let ask: RequestStopModel
    /// The places for another place on an open request.
    var suggest: RequestStopModel?
    var session = StopCardSession()
    /// The place list's search box.
    var query = ""
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
        query = ""
        screen = .places(eventId: state.eventId)
    }

    func backHome() {
        screen = .home
        suggest = nil
        query = ""
    }
}

/// The stop card, layered on top of the convoy panel. It opens only when someone taps the Pit stop
/// button, and closes by itself when the stop closes. Sending is always an explicit tap. What it shows
/// follows the board: ask (tiles, then the suggested place on a small map), the asker's timeline, a
/// request from another car, the lead car's votes and pin, at the stop, and read only while the car moves.
struct StopCard: View {
    let board: StopBoard
    let context: StopContext
    /// This phone is in a moving car (`DrivingDetector`).
    let driving: Bool
    let actions: StopRequestActions
    var onClose: () -> Void

    @State private var model: StopCardModel

    init(
        board: StopBoard, context: StopContext, driving: Bool, actions: StopRequestActions,
        service: any StopServing = StopService(), searcher: any PlaceSearching = MapKitPlaceSearcher(),
        demoScreen: String? = nil, onClose: @escaping () -> Void
    ) {
        self.board = board
        self.context = context
        self.driving = driving
        self.actions = actions
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

    var body: some View {
        screen
            .simultaneousGesture(
                DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.height > 60, abs(value.translation.width) < value.translation.height { onClose() }
                })
            .task(id: model.sentWaiting) {
                guard model.sentWaiting else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { model.sentWaiting = false }
            }
            .onChange(of: board.requests.map(\.eventId)) { _, ids in
                if !ids.isEmpty {
                    // A request is open, mine or someone's: whatever was being asked is over.
                    model.sentWaiting = false
                    model.ask.clearReason()
                    if model.screen == .askPlaces || model.screen == .passengerCheck { model.backHome() }
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
        case .askPlaces: askPlacesScreen
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
                askConfirmScreen(reason)
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

    /// The four reasons, laid out as in the Report sheet: a two column grid, icon and label in each tile.
    private var tilesScreen: some View {
        StopCardFrame(title: "Ask to stop", subtitle: nil, onClose: onClose) {
            if let missed = board.missed { missedNotice(missed) }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gap), count: 2), spacing: Spacing.gap
            ) {
                ForEach(StopReason.all) { reason in
                    Button { model.ask.choose(reason) } label: {
                        HStack(spacing: Spacing.m) {
                            Image(systemName: reason.symbol)
                                .font(.title3)
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.orange, in: Circle())
                            Text(reason.label)
                                .font(.headline)
                                .minimumScaleFactor(0.8)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Spacing.m)
                        .frame(maxWidth: .infinity, minHeight: 72)
                        .ikutTile()
                        .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reason.label)
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

    /// The suggested place on a small map, its distance and time, and one button that sends. A
    /// driving driver gets the same screen with one big button.
    private func askConfirmScreen(_ reason: StopReason) -> some View {
        let ask = model.ask
        let big = mode == .driverAsk
        return StopCardFrame(title: reason.label, subtitle: nil, onClose: onClose) {
            switch ask.search {
            case .idle, .loading:
                HStack(spacing: Spacing.gap) {
                    ProgressView()
                    Text("Finding the next good place…").foregroundStyle(.secondary)
                }
                .padding(.vertical, Spacing.section)
                .frame(maxWidth: .infinity)
            default:
                if let chosen = ask.chosen {
                    if let me = ask.myCoordinate {
                        StopMiniMap(
                            me: me, place: chosen.coordinate, symbol: reason.symbol,
                            route: StopMapFraming.routeBetween(
                                context.mainRoute, from: ask.myOffset ?? 0, to: chosen.routeOffset))
                            .id(chosen.id)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(chosen.name).font(.headline).lineLimit(2)
                            Text(chosen.whereText).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(chosen.costText).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
                    }
                    .padding(.horizontal, Spacing.xs)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("stop.suggested")
                } else {
                    note("No place found ahead. The lead car chooses where.")
                }
            }
        } actions: {
            if case .failed(let message) = ask.sending {
                Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            StopActionButton(
                title: "Ask for this stop", style: .primary, height: big ? 72 : 50,
                disabled: !ask.canSend, id: "stop.send"
            ) { send() }
            StopActionButton(
                title: "Another place", style: big ? .ghost : .secondary, height: big ? 44 : 50, id: "stop.anotherPlace"
            ) {
                if StopCardGate.needsPassengerCheck(driving: driving, session: model.session) {
                    model.screen = .passengerCheck
                } else {
                    model.query = ""
                    model.screen = .askPlaces
                }
            }
        }
    }

    /// The place list for a new ask: a search box, then places; picking one goes back to the map confirm.
    private var askPlacesScreen: some View {
        StopCardFrame(title: "Another place", subtitle: nil, onClose: onClose) {
            placeList(model.ask) { candidate in
                model.ask.picked = candidate.id
                model.screen = .home
            }
        } actions: {
            StopActionButton(title: "Back", style: .ghost, height: 44, id: "stop.back") { model.screen = .home }
        }
    }

    private var sentScreen: some View {
        StopCardFrame(title: "Asked the convoy", subtitle: "Waiting for the other cars", onClose: onClose) {
            Text("The lead car pins the place once the cars have answered.")
                .font(.subheadline).foregroundStyle(.secondary)
        } actions: {}
    }

    private func send() {
        Task {
            if await model.ask.send() {
                model.sentWaiting = true
                model.ask.clearReason()
            }
        }
    }

    // MARK: Place list (shared by asking and "Another place")

    /// The search box, then the places. `onPick` is what a tap on a place does.
    @ViewBuilder private func placeList(_ list: RequestStopModel, onPick: @escaping (StopCandidate) -> Void) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search places", text: Bindable(model).query)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { Task { await list.search(text: model.query) } }
                .accessibilityIdentifier("stop.search")
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 44)
        .ikutSurface(.quaternary, radius: Radius.control)
        switch list.search {
        case .idle, .loading:
            HStack(spacing: Spacing.gap) {
                ProgressView()
                Text("Finding the next good place…").foregroundStyle(.secondary)
            }
            .padding(.vertical, Spacing.section)
            .frame(maxWidth: .infinity)
        case .failed:
            note("Could not find places along the route. You can still ask; the lead car chooses where.")
        case .loaded where list.candidates.isEmpty:
            note("No places found ahead.")
        case .loaded:
            ForEach(list.candidates) { candidate in candidateRow(candidate, in: list, onPick: onPick) }
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

    private func candidateRow(
        _ candidate: StopCandidate, in list: RequestStopModel, onPick: @escaping (StopCandidate) -> Void
    ) -> some View {
        let selected = list.picked == candidate.id
        return Button { onPick(candidate) } label: {
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

    /// "Are you a passenger?" as a short block inside the same card: the question, and two buttons.
    private var passengerScreen: some View {
        StopCardFrame(title: "Another place", subtitle: nil, onClose: onClose) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Typing is off while the car moves.").font(.subheadline).foregroundStyle(.secondary)
                Text("Are you a passenger?").font(.title3.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stop.passengerCheck")
        } actions: {
            StopActionButton(title: "I’m a passenger", style: .primary, id: "stop.passenger") {
                model.session.confirmPassenger()
                model.query = ""
                model.screen = .askPlaces
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
                placeList(list) { list.picked = $0.id }
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
