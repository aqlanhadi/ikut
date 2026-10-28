import SwiftUI

/// What the driving map's camera does when something changes what the map can see (D67): the convoy sheet folding or
/// unfolding, the stop card opening, a banner or pill arriving or leaving under the trip pill, or the camera's own
/// target moving. One decision per update, taken on all of it together (`TripMapView` watches `Inputs` as one value),
/// so two changes in the same frame make one move, and that move rides on the motion of whatever caused it, started
/// in the same frame, instead of a 0.8 s glide of its own that finishes after the cause has settled.
enum CameraInsetMove {
    /// What the camera aims at and what covers the map above and below.
    struct Inputs: Equatable {
        var target: CameraTarget?
        /// What covers the map, from its top and bottom edges: the banners above, the sheet and card below.
        var top: CGFloat
        var bottom: CGFloat
    }

    /// What covers the map and changed. The sheet (or the stop card) wins over a banner when both changed.
    enum Cause: Equatable, Sendable { case none, sheet, banner }

    /// One camera move to make: `targetChanged` is the aim itself moving (a follow step, a mode); `cause` is the
    /// cover that changed, if any.
    struct Plan: Equatable, Sendable {
        var targetChanged: Bool
        var cause: Cause
    }

    /// How the move is made.
    enum Action: Equatable, Sendable {
        /// A short move on the cause's motion (`animation`).
        case nudge(Cause)
        /// A paced flight is in the air and its landing should move a little: land there, in the time it has left.
        case retarget
        /// A flight is in the air and the aim itself moved a little: wait for the landing.
        case hold
        /// A paced move (`CameraPace`), taking over whatever flies.
        case fly
    }

    /// My car counts as comfortably in view while it is inside this middle share of the visible strip.
    static let comfort: CGFloat = 0.6

    /// Whether `new` needs a camera move after `old`, and which. `frameHeight`: the map's height, which `top` and `bottom`
    /// are measured in. `aimedTop`: the top cover the camera was last aimed with; a banner that came
    /// without a move left the car where it was, so this is where the car is in the strip.
    static func plan(old: Inputs, new: Inputs, frameHeight: CGFloat, aimedTop: CGFloat) -> Plan? {
        guard let target = new.target else { return nil }
        let targetChanged = old.target != new.target
        let sheetChanged = old.bottom != new.bottom
        let bannerChanged = old.top != new.top
        let cause: Cause = sheetChanged ? .sheet : bannerChanged ? .banner : .none
        guard targetChanged || cause != .none else { return nil }
        // A banner alone, with my car still comfortably in view: the road stays where it is.
        if !targetChanged, cause == .banner, case .follow = target,
           carIsComfortable(aimedTop: aimedTop, top: new.top, bottom: new.bottom, frameHeight: frameHeight) {
            return nil
        }
        return Plan(targetChanged: targetChanged, cause: cause)
    }

    /// Whether my car, aimed at the middle of the strip below `aimedTop` and above `bottom`, sits in the middle
    /// `comfort` of the strip below `top`.
    static func carIsComfortable(aimedTop: CGFloat, top: CGFloat, bottom: CGFloat, frameHeight: CGFloat) -> Bool {
        let end = frameHeight - bottom
        let visible = end - top
        guard visible > 0 else { return false }
        let carY = (aimedTop + end) / 2
        let margin = visible * (1 - comfort) / 2
        return carY >= top + margin && carY <= end - margin
    }

    /// How `plan` is carried out. `paced`: what `CameraPace.decide` says about the move; `flying`: a flight is in the
    /// air. A move the aim itself makes that is more than a nudge is a flight, whatever else changed. The cover
    /// alone never asks for a flight: it is a nudge on the cover's own motion, or, while a flight is in the air, a
    /// change of where that flight lands.
    static func action(_ plan: Plan, paced: CameraPace.Decision, flying: Bool) -> Action {
        if plan.targetChanged {
            switch paced {
            case .fly: return .fly
            case .hold: return plan.cause == .none ? .hold : .retarget
            case .nudge: return .nudge(plan.cause)
            }
        }
        return flying ? .retarget : .nudge(plan.cause)
    }

    /// Whether a change of aim is a step of the same view (following my car on, the convoy's frame moving with its
    /// cars), which glides linearly over the time between fixes (D70), rather than a change of mode.
    static func isStep(from old: CameraTarget?, to new: CameraTarget?) -> Bool {
        switch (old, new) {
        case (.follow?, .follow?), (.fit?, .fit?): true
        default: false
        }
    }

    /// The camera's motion for a nudge: the sheet's or the banner's own (`Motion`), so the camera and what moved it
    /// end together; for the aim itself moving, the linear follow glide over `step` seconds when it is a step
    /// (`FollowGlide`), else the short camera glide; a jump with Reduce Motion, as every camera move.
    static func animation(_ cause: Cause, reduceMotion: Bool, step: TimeInterval? = nil) -> Animation? {
        switch cause {
        case .none:
            if let step { return Motion.follow(interval: step, reduceMotion: reduceMotion) }
            return DrivingGlance.cameraAnimation(reduceMotion: reduceMotion)
        case .sheet: return reduceMotion ? nil : Motion.sheet(reduceMotion: false)
        case .banner: return reduceMotion ? nil : Motion.banner(reduceMotion: false)
        }
    }
}

#if DEBUG
import os

/// `IKUT_CAMERA_LOG=1` (Debug): one line per camera move on the driving map to the `camera` log category, for checking
/// a drive: why, what was done, and from where to where. `log stream --predicate 'category == "camera"'` shows them.
enum CameraMoveLog {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "camera")
    private static let on = ProcessInfo.processInfo.environment["IKUT_CAMERA_LOG"] != nil

    static func note(_ text: String) {
        guard on else { return }
        log.notice("camera note: \(text)")
    }

    static func record(inputs: CameraInsetMove.Inputs, plan: CameraInsetMove.Plan?) {
        guard on else { return }
        log.notice("camera inputs: top \(Int(inputs.top)) bottom \(Int(inputs.bottom)) -> \(plan == nil ? "no move" : "move")")
    }

    static func record(plan: CameraInsetMove.Plan, action: CameraInsetMove.Action, from: CameraView?, to: CameraView) {
        guard on else { return }
        func text(_ v: CameraView?) -> String {
            v.map { String(format: "%.5f,%.5f span %.5f", $0.latitude, $0.longitude, $0.latitudeSpan) } ?? "unseen"
        }
        log.notice("camera move: target \(plan.targetChanged) cover \(String(describing: plan.cause)) -> \(String(describing: action)); \(text(from)) -> \(text(to))")
    }
}
#endif
