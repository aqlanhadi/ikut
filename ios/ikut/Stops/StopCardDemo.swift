#if DEBUG
import CoreLocation
import FirebaseFirestore
import Foundation
import SwiftUI

extension StopCardModel {
    /// The demo can open the card on a later screen (`IKUT_MAP_DEMO_CARD`): `passenger` (Are you a
    /// passenger?), `placelist` (the place list for a new ask), `askplaces` and `driverask` (a reason
    /// already chosen), `sent` (Asked the convoy), `another` (the place list for another place),
    /// `confirmpin` (the lead's confirm step). Anything else is the home screen.
    func applyDemo(_ name: String?, board: StopBoard) {
        switch name {
        case "sent": sentWaiting = true
        case "passenger":
            ask.choose(StopReason.all[0])
            screen = .passengerCheck
        case "placelist":
            ask.choose(StopReason.all[0])
            screen = .askPlaces
        case "askplaces", "driverask": ask.choose(StopReason.all[0])
        case "another": board.requests.first.map { startSuggesting(for: $0) }
        case "confirmpin":
            if let id = board.requests.first?.eventId {
                screen = .confirmPin(eventId: id, place: StopPlace(
                    name: "Petronas Bidor", coordinate: GeoPoint(latitude: 4.1, longitude: 101.29), routeOffset: 38_000,
                    pinnedBy: nil))
            }
        default: break
        }
    }
}

/// Sends nothing: the demo has no backend behind the card.
struct DemoStopService: StopServing {
    func request(type: EventType, place: StopPlace?, context: StopContext, snapshot: ReportSnapshot) async throws -> String {
        "demo-asked"
    }

    func suggest(place: StopPlace, eventId: String, canPin: Bool, context: StopContext) async throws {}
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
                    searcher: MapDemo.DemoPlaceSearcher(), demoScreen: screen, onClose: {})
                    .padding(.horizontal, Spacing.s)
                    .padding(.bottom, Spacing.s)
            }
        }
    }
}
#endif
