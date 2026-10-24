#if DEBUG
import FirebaseFirestore
import SwiftUI

/// The "who is here" card on its own (`IKUT_SCREEN=road-arrival`, `road-arrival-all`, `road-arrival-meet`; with
/// Skip, D25 5b: `road-skip` (a car 4 km short: "We'll skip this stop"), `road-skip-mine` (its car skipping:
/// "We'll stop after all"), `road-skip-others` (two cars skipping, the viewer's is not), `road-skip-lead` (the lead
/// car: three cars skipping read as a count, no button). With Leave, D25 4a: `road-leave` (lead car or organizer, "Leaving at 12:40"), `road-leave-confirm` (after tapping
/// Leave), `road-leave-other` (another car: no button), `road-leave-meet` (meeting point, "Leaving at 9:00");
/// Skip for everyone, D25 4b: `road-skip-all` (the organizer, no car at the stop yet: "Skip this stop"), `road-skip-all-confirm` (after tapping it), `road-skip-all-others` (a passenger: "Aqlan can skip this stop for everyone."), `road-skip-all-meet` (a meeting point: no skip, only Leave);
/// A car nobody shares location from, #231: `road-not-sharing` (listed, not counted);
/// RoadStops.dc.html), over the demo convoy. The clock is fixed, so the cars never go stale while it is looked at.
struct StopArrivalDemo: View {
    enum Scene { case someHere, allHere, meeting, leave, leaveConfirm, leaveOther, leaveMeeting, skip, skipMine, skipOthers, skipLead, skipAll, skipAllConfirm, skipAllOthers, skipAllMeeting, notSharing }

    var scene: Scene
    @State private var map: TripMapModel
    @State private var now = Date()
    private let stopId: String
    private let answers: [StopAnswer]

    init(_ scene: Scene) {
        self.scene = scene
        let built = Self.build(scene)
        _map = State(initialValue: built.model)
        stopId = built.stopId
        let said: [String] = switch scene {
        case .skipMine: ["c4"]
        case .skipOthers: ["c2", "c3"]
        case .skipLead: ["c2", "c3", "c4"]
        default: []
        }
        answers = said.map { StopAnswer(id: $0, answer: .skip, userId: "u-\($0)", at: nil) }
    }

    static func build(_ scene: Scene) -> (model: TripMapModel, stopId: String) {
        let now = Date()
        let model = MapDemo.model(now: now)
        let main = RouteLine(MapDemo.densify(MapDemo.mainWaypoints))
        let bidor = main.project(MapDemo.joiningWaypoints.last ?? .init(latitude: 4.1, longitude: 101.29))?.offset ?? 0
        let meets = scene == .meeting || scene == .leaveMeeting || scene == .skipAllMeeting
        let stopOffset = meets ? bidor : (main.project(.init(latitude: 4.2, longitude: 101.26))?.offset ?? 0)
        let at = main.coordinate(atOffset: stopOffset) ?? main.coordinates[0]

        func fix(_ offset: Double, joining: Bool, speed: Double = 25) -> Position {
            let c = main.coordinate(atOffset: offset) ?? at
            return Position(
                id: nil, location: GeoPoint(latitude: c.latitude, longitude: c.longitude), speed: speed, heading: 0,
                routeOffset: offset, convoyOffset: joining ? nil : offset, battery: 0.8, updatedAt: now.addingTimeInterval(-4))
        }
        var cars = model.convoy.convoy.map(\.car) + model.convoy.joining.map(\.car)
        cars.sort { ($0.number ?? 99) < ($1.number ?? 99) }
        var positions: [String: Position] = [:]
        switch scene {
        case .skipAll, .skipAllConfirm, .skipAllOthers:
            positions = ["c1": fix(stopOffset - 9_000, joining: false), "c2": fix(stopOffset - 9_100, joining: false),
                         "c4": fix(stopOffset - 10_000, joining: false), "c3": fix(stopOffset - 12_000, joining: true)]
        case .someHere, .notSharing, .leave, .leaveConfirm, .leaveOther, .skip, .skipMine, .skipOthers, .skipLead:
            positions = ["c1": fix(stopOffset, joining: false), "c2": fix(stopOffset - 80, joining: false),
                         "c4": fix(stopOffset - 4_000, joining: false), "c3": fix(stopOffset - 12_000, joining: true)]
        case .allHere:
            positions = ["c1": fix(stopOffset, joining: false), "c2": fix(stopOffset - 80, joining: false),
                         "c4": fix(stopOffset + 60, joining: false), "c3": fix(stopOffset - 30, joining: true)]
        case .meeting, .leaveMeeting, .skipAllMeeting:
            // Everyone joins: the organizer is at the meeting point, the others are still on their way in.
            for i in cars.indices where cars[i].id != "c1" { cars[i].state = .joining }
            positions = ["c1": fix(stopOffset, joining: true), "c2": fix(stopOffset - 3_000, joining: true),
                         "c4": fix(stopOffset - 9_000, joining: true), "c3": fix(stopOffset - 12_000, joining: true)]
        }
        var stop = PlannedStop(
            id: "s1", name: meets ? "Petronas Tapah Road" : "R&R Tapah",
            coordinate: GeoPoint(latitude: at.latitude, longitude: at.longitude), routeOffset: stopOffset,
            kind: meets ? .meet : .fuel, minutes: meets ? nil : 20,
            meetAt: meets ? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: now) : nil, order: 0)
        stop.id = "s1"
        let leaveScene = [.leave, .leaveConfirm, .leaveOther, .leaveMeeting].contains(scene)
        // The lead car got there at 12:20; 20 planned minutes make "Leaving at 12:40".
        if leaveScene, !meets { stop.arrivedAt = Calendar.current.date(bySettingHour: 12, minute: 20, second: 0, of: now) }
        // c4 has nobody sharing location from it: listed "Not sharing location", outside the count.
        if scene == .notSharing, let i = cars.firstIndex(where: { $0.id == "c4" }) { cars[i].trackerUserId = nil }
        model.setStops([stop])
        model.setCars(cars)
        model.tripStarted = leaveScene || [.skip, .skipMine, .skipOthers, .skipLead, .skipAll, .skipAllConfirm, .skipAllOthers, .skipAllMeeting].contains(scene)
        let viewer = scene == .leaveOther || scene == .skipAllOthers ? "c2" : [.skip, .skipMine, .skipOthers].contains(scene) ? "c4" : "c1"
        model.apply(trip: nil, myCar: cars.first { $0.id == viewer }, myCarId: viewer, positions: positions, isTracker: true)
        return (model, "s1")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color(.systemGray4).ignoresSafeArea()
            StopArrivalCard(
                model: map, stopId: stopId, frozenNow: now, isOrganizer: ![.leaveOther, .skip, .skipMine, .skipOthers, .skipAllOthers].contains(scene), leave: nil,
                skip: nil, skipAll: nil, initialAnswers: answers, onClose: {}, startConfirming: scene == .leaveConfirm,
                startConfirmingSkipAll: scene == .skipAllConfirm)
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.s)
        }
    }
}
#endif
