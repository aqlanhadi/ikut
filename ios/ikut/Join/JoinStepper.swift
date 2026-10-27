import CoreLocation
import MapKit
import Observation
import SwiftUI

/// The steps of joining a trip in Home's sheet (D58): the code (H3), then which car (H4). The name (H1) and the location
/// ask (H2) join them in front when this person still needs them.
enum JoinStep: Int, Equatable {
    case code, car
}

/// What Home's sheet is asked to open Join with: a code from a link or QR (nil when typed in the sheet).
struct JoinStart: Equatable {
    var code: String?
}

/// Which steps a person sees, what each says and when it can go on, as plain values so they can be tested.
enum JoinSteps {
    /// The steps this person will see, in order. The step indicator counts these and nothing else.
    static func sequence() -> [JoinStep] { [.code, .car] }

    static func indicator(_ step: JoinStep) -> String {
        let steps = sequence()
        return "Step \((steps.firstIndex(of: step) ?? 0) + 1) of \(steps.count)"
    }

    static func title(_ step: JoinStep) -> String {
        switch step {
        case .code: "Join a trip"
        case .car: "Your car"
        }
    }

    /// The step after `step`, or nil on the last (which joins).
    static func next(after step: JoinStep) -> JoinStep? {
        let steps = sequence()
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return nil }
        return steps[index + 1]
    }

    /// The step before `step`, or nil on the first (where Back is Close).
    static func previous(before step: JoinStep) -> JoinStep? {
        let steps = sequence()
        guard let index = steps.firstIndex(of: step), index > 0 else { return nil }
        return steps[index - 1]
    }

    /// "To Ipoh · 4 cars in".
    static func toLine(_ preview: TripPreview) -> String {
        let count = preview.cars.count
        return "To \(preview.destinationName) · \(count) \(count == 1 ? "car" : "cars") in"
    }

    /// "Meets at Petronas Jalan Duta · 1 stop": the meeting point, then how many other stops. Nil without either.
    static func meetLine(_ preview: TripPreview) -> String? {
        let meeting = preview.stops.first { $0.kind == .meet }
        let others = preview.stops.filter { $0.kind != .meet }.count
        let stops = others == 0 ? nil : "\(others) \(others == 1 ? "stop" : "stops")"
        switch (meeting, stops) {
        case (let meeting?, let stops?): return "Meets at \(meeting.name) · \(stops)"
        case (let meeting?, nil): return "Meets at \(meeting.name)"
        case (nil, let stops?): return stops
        case (nil, nil): return nil
        }
    }

    /// What the map behind the card draws for a found code: where the trip ends, and the stops once the trip's preview
    /// carries their places. Never anyone's start or route origin (the preview has none to give).
    static func map(for preview: TripPreview?) -> TripMapInput {
        guard let preview, let end = preview.destinationCoordinate else { return TripMapInput(showsUser: true) }
        let pin = LobbyPin(id: "join-destination", kind: .destination, name: preview.destinationName,
                           latitude: end.latitude, longitude: end.longitude)
        return TripMapInput(showsUser: true, pins: [pin])
    }

    /// The camera for a found code: the destination above the sheet, like the pin at the top of Where to?'s list.
    static func region(for preview: TripPreview?, bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        guard let end = preview?.destinationCoordinate else { return nil }
        return PickedTripLogic.focus(on: end.coordinate, span: 0.2, bottomObscured: bottomObscured, topObscured: topObscured)
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
    private(set) var step: JoinStep = .code

    init(model: JoinModel) { self.model = model }

    /// A code from a link or QR lands on the code step with the code filled in (and looked up on `start`).
    convenience init(displayName: String, code: String? = nil, api: any JoinAPI = LiveJoinAPI()) {
        self.init(model: JoinModel(displayName: displayName, initialCode: code, api: api))
    }

    var title: String { JoinSteps.title(step) }
    var indicator: String { JoinSteps.indicator(step) }

    /// The code step goes on once the trip is found; the car step is the join itself.
    var canContinue: Bool {
        switch step {
        case .code: model.preview != nil && !model.isLoadingPreview
        case .car: model.canJoin
        }
    }

    func goNext() {
        guard canContinue, let next = JoinSteps.next(after: step) else { return }
        step = next
    }

    /// Back one step; false on the first, where the sheet closes instead.
    @discardableResult func goBack() -> Bool {
        guard !model.isJoining, let previous = JoinSteps.previous(before: step) else { return false }
        step = previous
        return true
    }

    /// Jumps to a step (demo launch states).
    func show(_ step: JoinStep) { self.step = step }

    var mapInput: TripMapInput { JoinSteps.map(for: model.preview) }
}
