#if DEBUG
import CoreLocation
import FirebaseFirestore
import Foundation

extension StopCardModel {
    /// The demo can open the card on a later screen (`IKUT_MAP_DEMO_CARD`): `passenger` (Are you a
    /// passenger?), `askplaces` and `driverask` (a reason already chosen), `another` (the place list
    /// for another place), `confirmpin` (the lead's confirm step). Anything else is the home screen.
    func applyDemo(_ name: String?, board: StopBoard) {
        switch name {
        case "passenger": screen = .passengerCheck
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
#endif
