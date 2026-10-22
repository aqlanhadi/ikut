#if DEBUG
import Foundation
import SwiftUI

extension StopCardModel {
    /// The demo can open the card on a later screen (`IKUT_MAP_DEMO_CARD`): `reason` (Fuel chosen),
    /// `typed` (Fuel chosen, with a message), `passenger` (Are you a passenger?), `message` (the message
    /// field) and `sent` (Informed the convoy). Anything else is the home screen.
    func applyDemo(_ name: String?) {
        switch name {
        case "sent": sentWaiting = true
        case "reason": ask.choose(StopReason.all[0])
        case "typed":
            ask.choose(StopReason.all[0])
            ask.message = "Low on fuel, next R&R please"
        case "passenger":
            ask.choose(StopReason.all[0])
            screen = .passengerCheck
        case "message":
            ask.choose(StopReason.all[0])
            ask.message = "Low on fuel, next R&R please"
            screen = .message
        default: break
        }
    }
}

/// Sends nothing: the demo has no backend behind the card.
struct DemoStopService: StopServing {
    func request(type: EventType, message: String?, context: StopContext, snapshot: ReportSnapshot) async throws -> String {
        "demo-asked"
    }
}

/// The stop card on the demo trip, seen from Aqlan's car (car 1, the lead), for previews: `scene`
/// is a `MapDemo.stopBoard` scene (nil for no open stop), `screen` a demo screen (see `applyDemo`).
/// With `cardOpen` false it shows what the map shows instead: the collapsed convoy panel, whose Pit
/// stop button tells how the board stands.
struct StopCardPreview: View {
    var scene: String?
    var screen: String?
    var driving = false
    var cardOpen = true

    /// Held here: the context's closures keep only a weak reference to it.
    @State private var map = MapDemo.model()

    var body: some View {
        let board = scene.map { MapDemo.stopBoard($0) } ?? .empty
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            if !cardOpen {
                ConvoyPanel(
                    model: map, expanded: .constant(false), canReport: true,
                    stopButton: StopLogic.buttonContent(for: board), onReport: {}, onStop: {})
            } else if let context = map.stopContext(tripId: "demo", userId: "u-c1", isOrganizer: false) {
                StopCard(
                    board: board, context: context, driving: driving, actions: .none, service: DemoStopService(),
                    demoScreen: screen, onClose: {})
                    .padding(.horizontal, Spacing.s)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}
#endif
