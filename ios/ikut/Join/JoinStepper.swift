import CoreLocation
import MapKit
import Observation
import SwiftUI

/// The steps of joining a trip in Home's sheet (D58): the name (H1) and the location ask (H2) when this person still
/// needs them, then the code (H3) and which car (H4).
enum JoinStep: Int, Equatable, CaseIterable {
    case name, location, code, car
}

/// What Home's sheet is asked to open Join with: a code from a link or QR (nil when typed in the sheet).
struct JoinStart: Equatable {
    var code: String?
}

/// Which steps this person sees: the name only without one, the location ask only while iOS hasn't been asked.
struct JoinPlan: Equatable {
    var needsName = false
    var needsLocation = false

    var steps: [JoinStep] {
        (needsName ? [.name] : []) + (needsLocation ? [.location] : []) + [.code, .car]
    }
}

/// Which steps a person sees, what each says and when it can go on, as plain values so they can be tested.
enum JoinSteps {
    static func plan(hasName: Bool, location: LocationAccess.Status) -> JoinPlan {
        JoinPlan(needsName: !hasName, needsLocation: location == .notDetermined)
    }

    /// Whether the join sheet can take location itself: not yet asked, or already good enough. A denied or approximate
    /// location still goes through Home's settings prompt first.
    static func sheetHostsLocation(status: LocationAccess.Status, accuracy: LocationAccess.Accuracy) -> Bool {
        status == .notDetermined || accuracy == .full && status != .denied
    }

    /// The steps this person will see, in order. The step indicator counts these and nothing else.
    static func sequence(_ plan: JoinPlan = JoinPlan()) -> [JoinStep] { plan.steps }

    static func indicator(_ step: JoinStep, plan: JoinPlan = JoinPlan()) -> String {
        let steps = sequence(plan)
        return "Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)"
    }

    static func title(_ step: JoinStep) -> String {
        switch step {
        case .name: "Welcome to ikut"
        case .location: "Location"
        case .code: "Join a trip"
        case .car: "Your car"
        }
    }

    /// The step after `step`, or nil on the last (which joins).
    static func next(after step: JoinStep, plan: JoinPlan = JoinPlan()) -> JoinStep? {
        let steps = sequence(plan)
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// The step before `step`, or nil on the first (where Back is Close). The name and the location ask are done once
    /// answered (the account exists, iOS has asked), so Back never returns to them.
    static func previous(before step: JoinStep, plan: JoinPlan = JoinPlan()) -> JoinStep? {
        let steps = sequence(plan)
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        let before = steps[index - 1]
        return before == .name || before == .location ? nil : before
    }

    /// "To Ipoh · Aqlan organises · 4 cars in"; without the organiser (an older server) "To Ipoh · 4 cars in".
    static func toLine(_ preview: TripPreview) -> String {
        let count = preview.cars.count
        var parts = ["To \(preview.destinationName)"]
        if let organizer = preview.organizerName { parts.append("\(organizer) organises") }
        parts.append("\(count) \(count == 1 ? "car" : "cars") in")
        return parts.joined(separator: " · ")
    }

    /// "Meets at Petronas Jalan Duta, 12:00 · 1 stop": the meeting point (and its time), then how many other stops.
    static func meetLine(_ preview: TripPreview, timeZone: TimeZone = .current) -> String? {
        let meeting = preview.stops.first { $0.kind == .meet }
        let others = preview.stops.filter { $0.kind != .meet }.count
        let stops = others == 0 ? nil : "\(others) \(others == 1 ? "stop" : "stops")"
        switch (meeting, stops) {
        case (let meeting?, let stops?): return "Meets at \(meetingText(meeting, timeZone: timeZone)) · \(stops)"
        case (let meeting?, nil): return "Meets at \(meetingText(meeting, timeZone: timeZone))"
        case (nil, let stops?): return stops
        case (nil, nil): return nil
        }
    }

    private static func meetingText(_ stop: PreviewStop, timeZone: TimeZone) -> String {
        guard let at = stop.meetAt else { return stop.name }
        return "\(stop.name), \(StopFormat.clock(at, timeZone: timeZone))"
    }

    /// The route the map draws, decoded; empty when the server sent none (older server, or a line under 6 km).
    static func route(_ preview: TripPreview?) -> [CLLocationCoordinate2D] {
        guard let encoded = preview?.route else { return [] }
        let line = Polyline.decode(encoded)
        return line.count > 1 ? line : []
    }

    /// What the card says about the map: the route and stops when a route is drawn, else just where the trip ends.
    static func mapCaption(_ preview: TripPreview) -> String {
        route(preview).isEmpty
            ? "The map shows where the trip ends. Nobody’s start is shown."
            : "The map shows the route and stops. Nobody’s start is shown."
    }

    /// What the map behind the card draws for a found code: where the trip ends, the stops that have a place, and the
    /// route when the server sent one. Never anyone's start: the route is cut to begin at the meeting point or well in.
    static func map(for preview: TripPreview?) -> TripMapInput {
        guard let preview else { return TripMapInput(showsUser: true) }
        var pins: [LobbyPin] = []
        var number = 0
        for (index, stop) in preview.stops.enumerated() {
            guard let place = stop.coordinate else { continue }
            let kind: LobbyPin.Kind
            if stop.kind == .meet {
                kind = .meeting
            } else {
                number += 1
                kind = .stop(number: number)
            }
            pins.append(LobbyPin(id: "join-stop-\(index)", kind: kind, name: stop.name,
                                 latitude: place.latitude, longitude: place.longitude))
        }
        if let end = preview.destinationCoordinate {
            pins.append(LobbyPin(id: "join-destination", kind: .destination, name: preview.destinationName,
                                 latitude: end.latitude, longitude: end.longitude))
        }
        return TripMapInput(showsUser: true, route: route(preview), pins: pins)
    }

    /// The camera for a found code: the whole route above the sheet when there is one, else the destination, like the
    /// pin at the top of Where to?'s list.
    static func region(for preview: TripPreview?, bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        guard let preview else { return nil }
        let line = route(preview)
        if let end = preview.destinationCoordinate, line.count > 1 {
            let fitted = PastTripRoute(
                id: preview.tripId, name: preview.name, destinationName: preview.destinationName,
                destinationLatitude: end.latitude, destinationLongitude: end.longitude,
                points: line.map { [$0.latitude, $0.longitude] })
            if let region = PickedTripLogic.fit(fitted, bottomObscured: bottomObscured, topObscured: topObscured) { return region }
        }
        guard let end = preview.destinationCoordinate else { return nil }
        return PickedTripLogic.focus(on: end.coordinate, span: 0.2, bottomObscured: bottomObscured, topObscured: topObscured)
    }

    /// What the car step shows about sharing once a car is picked, always pinned above Join (never in the scrolling list):
    /// nothing before a pick, a switch for someone else's car, a line for my own.
    enum Sharing: Equatable { case none, switchRow, ownCar }

    static func sharing(selectedCar: PreviewCar?, ownCar: Bool) -> Sharing {
        if selectedCar != nil { return .switchRow }
        return ownCar ? .ownCar : .none
    }

    /// The main button of the car step: "Join Aqlan’s Myvi as Nurul", "Join in my own car as Nurul", or plain
    /// "Join trip" before a car is picked.
    static func joinLabel(car: PreviewCar?, ownCar: Bool, firstName: String) -> String {
        let suffix = firstName.isEmpty ? "" : " as \(firstName)"
        if let car { return "Join \(car.name)\(suffix)" }
        if ownCar { return "Join in my own car\(suffix)" }
        return "Join trip"
    }
}

/// Joining over Home's map: the model of the code and the car, and the step the sheet is on.
@Observable @MainActor
final class JoinStepper {
    let model: JoinModel
    let plan: JoinPlan
    private(set) var step: JoinStep

    init(model: JoinModel, plan: JoinPlan = JoinPlan()) {
        self.model = model
        self.plan = plan
        step = plan.steps.first ?? .code
    }

    /// A code from a link or QR is filled in on the code step (looked up once the name, if asked for, is in).
    convenience init(displayName: String, code: String? = nil, plan: JoinPlan = JoinPlan(), api: any JoinAPI = LiveJoinAPI()) {
        self.init(model: JoinModel(displayName: displayName, initialCode: code, api: api), plan: plan)
    }

    /// What Home does for a join request (a link, a QR code or the Join row): the steps this person needs, with the code
    /// filled in. The lookup starts at once, or once the name is given (the server wants a signed-in person).
    static func begin(_ start: JoinStart, displayName: String, plan: JoinPlan = JoinPlan(),
                      api: any JoinAPI = LiveJoinAPI()) -> JoinStepper {
        let stepper = JoinStepper(displayName: displayName, code: start.code, plan: plan, api: api)
        if !plan.needsName { stepper.model.start() }
        return stepper
    }

    /// A second join request (another link) replaces the steps, except mid-join or once joined.
    static func shouldReplace(_ current: JoinStepper?) -> Bool {
        guard let current else { return true }
        return !current.model.isJoining && current.model.trackerTakenResult == nil
    }

    var title: String { JoinSteps.title(step) }
    var indicator: String { JoinSteps.indicator(step, plan: plan) }
    var canGoBack: Bool { JoinSteps.previous(before: step, plan: plan) != nil }

    /// The name goes on once valid, the location ask always, the code step once the trip is found, and the car step is
    /// the join itself.
    var canContinue: Bool {
        switch step {
        case .name: model.nameIsValid
        case .location: true
        case .code: model.preview != nil && !model.isLoadingPreview
        case .car: model.canJoin
        }
    }

    func goNext() {
        guard canContinue, let next = JoinSteps.next(after: step, plan: plan) else { return }
        // Signed in by now, so the trip can be looked up.
        if step == .name { model.start() }
        step = next
    }

    /// Back one step; false on the first, where the sheet closes instead.
    @discardableResult func goBack() -> Bool {
        guard !model.isJoining, let previous = JoinSteps.previous(before: step, plan: plan) else { return false }
        step = previous
        return true
    }

    /// Jumps to a step (demo launch states).
    func show(_ step: JoinStep) { self.step = step }

    var mapInput: TripMapInput { JoinSteps.map(for: model.preview) }
}
