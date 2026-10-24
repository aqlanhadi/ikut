import Observation
import SwiftUI

/// What the stop card is showing and remembering while it is open. A new model per opening, so
/// the "Are you a passenger?" answer lasts only until the card closes.
@MainActor @Observable
final class StopCardModel {
    enum Screen: Equatable {
        /// What the board says: ask, or the open request(s).
        case home
        /// "Are you a passenger?", before the message field on a moving phone.
        case passengerCheck
        /// The message field.
        case message
    }

    var screen: Screen = .home
    /// The request being made: reason tiles, then the optional message.
    let ask: RequestStopModel
    var session = StopCardSession()
    /// Places ahead that fit what is asked, under the open request(s).
    let places = StopPlacesModel()
    /// Sent; waiting for the request to show up on the board.
    var sentWaiting = false

    init(context: StopContext, service: any StopServing) {
        ask = RequestStopModel(context: context, service: service)
    }

    func backHome() { screen = .home }
}

/// The stop card, layered on top of the convoy panel. It opens only when someone taps the Pit stop
/// button, and closes by itself when the stop closes. Sending is always an explicit tap. What it shows
/// follows the board: the four reasons, then the chosen reason with an optional message and one
/// "Tell the convoy" button; once a request is open, the request with a row per car, OK, We’ve
/// stopped and Cancel request. Every button works while the car moves; only the message field asks
/// "Are you a passenger?" first.
struct StopCard: View {
    let board: StopBoard
    let context: StopContext
    /// This phone is in a moving car (`DrivingDetector`).
    let driving: Bool
    let actions: StopRequestActions
    var onClose: () -> Void

    @State private var model: StopCardModel
    @FocusState private var messageFocused: Bool

    init(
        board: StopBoard, context: StopContext, driving: Bool, actions: StopRequestActions,
        service: any StopServing = StopService(), demoScreen: String? = nil, onClose: @escaping () -> Void
    ) {
        self.board = board
        self.context = context
        self.driving = driving
        self.actions = actions
        self.onClose = onClose
        let model = StopCardModel(context: context, service: service)
        #if DEBUG
        model.applyDemo(demoScreen)
        #endif
        _model = State(initialValue: model)
    }

    /// Buttons are big while the car moves, so they can be hit at a glance.
    private var big: Bool { driving }

    var body: some View {
        screen
            .task(id: model.sentWaiting) {
                guard model.sentWaiting else { return }
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled { model.sentWaiting = false }
            }
            .task(id: PlacesKey(needs: needs, route: context.mainRoute)) { await model.places.keepFresh(reasons: needs, context: context) }
            .onChange(of: board.requests.map(\.eventId)) { _, ids in
                guard !ids.isEmpty else { return }
                // A request is open, mine or someone's: whatever was being asked is over.
                model.sentWaiting = false
                model.ask.clearReason()
                model.backHome()
            }
    }

    /// What the places list depends on besides the front car: the reasons and the trip's route, so a rebuilt route
    /// (or one that arrives after the card opened) refreshes it.
    private struct PlacesKey: Hashable {
        var needs: [RequestNeed]
        var routeCount: Int
        var routeLength: Int
        init(needs: [RequestNeed], route: RouteLine?) {
            self.needs = needs
            routeCount = route?.coordinates.count ?? 0
            routeLength = Int(route?.length ?? 0)
        }
    }

    /// What the open requests ask for, together: one list covers every reason.
    private var needs: [RequestNeed] { board.requests.compactMap { RequestNeed($0.type) } }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .home: home
        case .passengerCheck: passengerScreen
        case .message: messageScreen
        }
    }

    @ViewBuilder private var home: some View {
        if board.requests.isEmpty {
            if model.sentWaiting {
                sentScreen
            } else if let reason = model.ask.reason {
                askScreen(reason)
            } else {
                tilesScreen
            }
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
                        .surfaceTile()
                        .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(reason.label)
                    .accessibilityIdentifier("stop.reason.\(reason.type.rawValue)")
                }
            }
        } actions: {}
    }

    /// The chosen reason, an optional message, and one button that sends. A moving phone gets the
    /// same screen with a bigger button.
    private func askScreen(_ reason: StopReason) -> some View {
        let ask = model.ask
        return StopCardFrame(title: reason.label, subtitle: "Ask the convoy to stop", onClose: onClose) {
            if let text = StopLogic.cleanedMessage(ask.message) { StopMessageTile(text: text) }
        } actions: {
            if case .failed(let message) = ask.sending {
                Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            StopActionButton(
                title: "Tell the convoy", style: .primary, height: big ? 72 : 50, disabled: !ask.canSend, id: "stop.send"
            ) { send() }
            StopActionButton(
                title: StopLogic.cleanedMessage(ask.message) == nil ? "Add a message" : "Change the message",
                style: big ? .ghost : .secondary, height: big ? 44 : 50, id: "stop.addMessage"
            ) {
                model.screen = StopCardGate.needsPassengerCheck(driving: driving, session: model.session)
                    ? .passengerCheck : .message
            }
            StopActionButton(title: "Back", style: .ghost, height: 44, id: "stop.back") { ask.clearReason() }
        }
    }

    private var sentScreen: some View {
        StopCardFrame(title: "Sent to the convoy", subtitle: "Waiting for the other cars", onClose: onClose) {
            Text("Each car taps OK when it sees your request.")
                .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
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

    /// "Are you a passenger?" as a short block inside the same card: the question, and two buttons.
    private var passengerScreen: some View {
        StopCardFrame(title: "Add a message", subtitle: nil, onClose: onClose) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Are you a passenger?").font(.title3.bold())
                Text("Only a passenger can type while the car moves.").font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stop.passengerCheck")
        } actions: {
            StopActionButton(title: "I’m a passenger", style: .primary, height: big ? 72 : 50, id: "stop.passenger") {
                model.session.confirmPassenger()
                model.screen = .message
            }
            StopActionButton(title: "I’m driving", style: .secondary, height: big ? 56 : 50, id: "stop.driving") {
                model.session.confirmDriving()
                model.backHome()
            }
        }
    }

    /// The message field: up to 280 characters, empty means no message.
    private var messageScreen: some View {
        let ask = model.ask
        return StopCardFrame(title: "Add a message", subtitle: nil, onClose: onClose) {
            TextField("Say why, in a few words", text: Bindable(ask).message, axis: .vertical)
                .lineLimit(1...4)
                .focused($messageFocused)
                .padding(Spacing.m)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .ikutSurface(.quaternary, radius: Radius.control)
                .accessibilityIdentifier("stop.messageField")
            Text("\(ask.message.count) of \(StopLogic.maxMessageLength)")
                .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
        } actions: {
            StopActionButton(title: "Done", style: .primary, id: "stop.messageDone") {
                messageFocused = false
                model.backHome()
            }
            if !ask.message.isEmpty {
                StopActionButton(title: "No message", style: .ghost, height: 44, id: "stop.messageClear") {
                    ask.message = ""
                    messageFocused = false
                    model.backHome()
                }
            }
        }
        .onAppear { messageFocused = true }
    }

    // MARK: One open request

    /// "asked 2 min ago" keeps "2 min ago" together when the line wraps at large text sizes.
    private func subtitle(_ state: StopRequestState) -> String {
        let line = state.subtitle(now: Date())
        guard let range = line.range(of: "asked ") else { return line }
        let tail = line[range.upperBound...].replacingOccurrences(of: " ", with: "\u{00A0}")
        return line[..<range.upperBound] + tail
    }

    /// The one screen for every role: the message in full, a row per car, and the buttons this
    /// viewer may press.
    private func requestScreen(_ state: StopRequestState) -> some View {
        StopCardFrame(title: state.title, subtitle: subtitle(state), onClose: onClose) {
            if let message = state.message { StopMessageTile(text: message) }
            ForEach(state.rows) { StopVoterRow(row: $0) }
            StopPlaceRows(places: model.places.places)
        } actions: {
            requestButtons(state, suffix: "", height: big ? 72 : 50, secondaryHeight: big ? 56 : 50)
        }
    }

    /// OK for a car that has not said it, We’ve stopped for the asker, the lead car and the organizer,
    /// Cancel request for the asker. The first one that applies is the main button.
    @ViewBuilder private func requestButtons(
        _ state: StopRequestState, suffix: String, height: CGFloat, secondaryHeight: CGFloat
    ) -> some View {
        let canOK = !StopLogic.viewerIsRequester(state)
        let needsOK = StopLogic.needsAnswer(state)
        if canOK {
            StopActionButton(
                title: needsOK ? "OK" : "You said OK", style: needsOK ? .primary : .positive, height: height,
                id: "stop.ok\(suffix)"
            ) {
                if needsOK { actions.ok(state.eventId) }
            }
        }
        if state.canMarkStopped {
            StopActionButton(
                title: "We’ve stopped", style: needsOK ? .secondary : .primary,
                height: needsOK ? secondaryHeight : height, id: "stop.stopped\(suffix)"
            ) { actions.close(state.eventId, .stopped) }
        }
        if state.isAuthor {
            StopActionButton(
                title: "Cancel request", style: .secondary, height: secondaryHeight, id: "stop.cancel\(suffix)"
            ) { actions.close(state.eventId, .cancelled) }
        }
    }

    // MARK: Two or more open requests

    private var multiScreen: some View {
        StopCardFrame(title: "\(board.requests.count) stops open", subtitle: nil, onClose: onClose) {
            ForEach(Array(board.requests.enumerated()), id: \.element.eventId) { index, state in
                miniRequest(state, suffix: ".\(index)")
            }
            StopPlaceRows(places: model.places.places)
        } actions: {}
    }

    private func miniRequest(_ state: StopRequestState, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                StopReasonIcon(symbol: StopLogic.reasonSymbol(state.type), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title).font(.body.weight(.semibold)).lineLimit(2)
                    Text(state.message ?? StopLogic.statusLine(state)).font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            requestButtons(state, suffix: suffix, height: big ? 56 : 44, secondaryHeight: big ? 56 : 44)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.request\(suffix)")
    }
}

#if DEBUG
// Asking: no stop open yet.
#Preview("Ask: reasons") { StopCardPreview() }
#Preview("Ask: reason chosen") { StopCardPreview(screen: "reason") }
#Preview("Ask: message typed") { StopCardPreview(screen: "typed") }
#Preview("Ask: message field") { StopCardPreview(screen: "message") }
#Preview("Ask: sent") { StopCardPreview(screen: "sent") }

// One stop open, as each car sees it.
#Preview("Asker") { StopCardPreview(scene: "asker") }
#Preview("Responder") { StopCardPreview(scene: "responder") }
#Preview("Lead") { StopCardPreview(scene: "lead") }
#Preview("Two requests") { StopCardPreview(scene: "two") }

// A moving phone.
#Preview("Driving: reason chosen") { StopCardPreview(screen: "reason", driving: true) }
#Preview("Driving: are you a passenger?") { StopCardPreview(screen: "passenger", driving: true) }
#Preview("Driving: request") { StopCardPreview(scene: "responder", driving: true) }

// The card closed: the Pit stop button on the panel.
#Preview("Pit stop button: no stop") { StopCardPreview(cardOpen: false) }
#Preview("Pit stop button: waiting for me") { StopCardPreview(scene: "two", cardOpen: false) }
#Preview("Pit stop button: one stop") { StopCardPreview(scene: "lead", cardOpen: false) }

// Accessibility sizes: the buttons wrap to two lines.
#Preview("Asker, AX3") { StopCardPreview(scene: "asker").dynamicTypeSize(.accessibility3) }
#Preview("Pit stop button: waiting for me, AX3") {
    StopCardPreview(scene: "two", cardOpen: false).dynamicTypeSize(.accessibility3)
}
#endif
