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

    /// The inputs from the one map (D63 C4), as the driving layer measured them: what covers it (`cover`: the banner
    /// stack from the layer's top, the sheet from the bottom) in a layer `layerHeight` tall starting `above` below the
    /// map's top, shrunk together when they would leave less than `MapObscuredInsets.minimumVisible`, and the top
    /// counted from the map's own top edge (`MapSpace.layerHeight`, `MapSpace.above`).
    static func inputs(target: CameraTarget?, layerHeight: CGFloat, above: CGFloat, cover: MapCover) -> Inputs {
        let insets = MapObscuredInsets.insets(mapHeight: layerHeight, top: cover.top, bottom: cover.bottom)
        return Inputs(target: target, top: insets.top + above, bottom: insets.bottom)
    }

    /// The change to act on for `new`, from the last inputs acted on (`handled`): nil when those are `new` already (the
    /// sheet's own change moved the camera in its transaction, and the watcher now sees the same inputs), the first
    /// look (`new` twice) before any. Watching from the last handled rather than the last seen keeps D67's one
    /// decision per update for whatever else changed meanwhile, such as a banner in the same update.
    static func unhandled(_ handled: Inputs?, _ new: Inputs) -> (old: Inputs, new: Inputs)? {
        guard let handled else { return (new, new) }
        return handled == new ? nil : (handled, new)
    }

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

/// The driving camera's bookkeeping of the inputs it has acted on (D63 C4), shared by the convoy sheet's own resize and
/// the D67 watcher, so a move made inside the resize is not made again when the watcher sees the same inputs.
struct CameraInputsWatch: Equatable {
    private(set) var handled: CameraInsetMove.Inputs?

    /// The change to act on for `new` (`CameraInsetMove.unhandled`), marked handled; nil when there is none.
    mutating func take(_ new: CameraInsetMove.Inputs) -> (old: CameraInsetMove.Inputs, new: CameraInsetMove.Inputs)? {
        guard let change = CameraInsetMove.unhandled(handled, new) else { return nil }
        handled = new
        return change
    }

    /// A fold, unfold or pull-up of the convoy sheet: the resize and the cover it leaves (`cover`), in one call on the
    /// screen (`TripScreenModel.sheetChange`); when that changed what the camera keeps clear, the change of `inputs` the
    /// camera must decide on now, marked handled. The caller keeps this watch, then acts on the change, still inside
    /// its one sheet motion. Nil: nothing for the camera (or driving is not on screen).
    @MainActor
    mutating func resize(_ screen: TripScreenModel, to shown: PanelSheet.Shown, cover: () -> MapCover,
                         inputs: () -> CameraInsetMove.Inputs) -> (old: CameraInsetMove.Inputs, new: CameraInsetMove.Inputs)? {
        var change: (old: CameraInsetMove.Inputs, new: CameraInsetMove.Inputs)?
        screen.sheetChange(in: .driving, { screen.sheet.resize(to: .driving(shown)) }, cover: cover,
                           aim: { _ in change = take(inputs()) })
        return change
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

    /// A move on the one camera, from any mode (Home's and the lobby's have no plan of their own to log).
    static func step(_ kind: String, mode: TripScreenMode, to view: CameraView?) {
        guard on else { return }
        let to = view.map { String(format: "%.5f,%.5f span %.5f", $0.latitude, $0.longitude, $0.latitudeSpan) } ?? "?"
        log.notice("camera step: \(String(describing: mode)) \(kind) -> \(to)")
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
