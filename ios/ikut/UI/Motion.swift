import MapKit
import SwiftUI

/// The app's named animations, so everything moves the same way. Every one takes `reduceMotion`
/// (`@Environment(\.accessibilityReduceMotion)`) and returns the Reduce Motion form itself, so a caller can't forget it:
/// a 0.2 s fade, or `nil` (no animation, a jump) for the camera. Pass the result to `withAnimation` / `.animation`.
enum Motion {
    /// The Reduce Motion form: a short ease, opacity changes only.
    static let reduced = Animation.easeInOut(duration: 0.2)

    /// Anything that moves with a sheet's detent: a fold's cross-fade, a card swap, Home's content swap. Smooth, 0.4 s.
    static func sheet(reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : .smooth(duration: 0.4) }

    /// Banners, pills and the toast coming and going; list inserts and removals. Snappy, 0.3 s.
    static func banner(reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : .snappy(duration: 0.3) }

    /// Fades of controls (Follow / Fit), small value and text changes. Ease out, 0.2 s.
    static func quick(reduceMotion: Bool) -> Animation? { reduceMotion ? reduced : .easeOut(duration: 0.2) }

    /// Camera moves a person asked for (Follow, Fit, a recap step, a picked trip). Smooth, 0.6 s; `nil` (a jump) with
    /// Reduce Motion.
    static func camera(reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .smooth(duration: 0.6) }

    /// Tracking my car and moving other cars between location fixes: linear over `interval` seconds, so the glide
    /// ends as the next fix arrives. With Reduce Motion the fade.
    static func follow(interval: TimeInterval, reduceMotion: Bool) -> Animation? {
        reduceMotion ? reduced : .linear(duration: max(interval, 0.05))
    }
}

// MARK: - Camera pace (D57)

/// A view of the map, as much as pacing needs: where its middle is and how tall it is in degrees of latitude.
struct CameraView: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Degrees of latitude from the view's top to its bottom.
    var latitudeSpan: Double

    init(latitude: Double, longitude: Double, latitudeSpan: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeSpan = latitudeSpan
    }

    init(region: MKCoordinateRegion) {
        self.init(latitude: region.center.latitude, longitude: region.center.longitude, latitudeSpan: region.span.latitudeDelta)
    }

    /// A camera `distance` meters up, `latitudePerMeter` degrees of the view's height per meter of distance (read off
    /// the map); before the map has been read, about a degree per 111 km of distance.
    init(center: CLLocationCoordinate2D, distance: Double, latitudePerMeter: Double = 0) {
        let perMeter = latitudePerMeter > 0 ? latitudePerMeter : 1 / 111_000
        self.init(latitude: center.latitude, longitude: center.longitude, latitudeSpan: distance * perMeter)
    }

    /// The region this view shows on a portrait phone (`CameraPace.aspect` wide for its height).
    var region: MKCoordinateRegion {
        let cosLat = max(cos(latitude * .pi / 180), 0.01)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: min(latitudeSpan, 170),
                                   longitudeDelta: min(latitudeSpan * CameraPace.aspect / cosLat, 350)))
    }
}

/// How every camera move on the one map is paced, so a person can follow it. The time comes from how far the camera
/// travels, in screen widths at the wider of the two views, and how much it zooms, in halvings of the view's height:
///
///     duration = 0.35 s + 0.3 s × log2(1 + widths) + 0.15 s × |log2(span ratio)|, clamped to 0.5…1.6 s
///
/// A long hop (the target more than 1.5 widths away, or a zoom of 3 halvings or more) pulls out to a view with both
/// ends in it, travels there, and settles in: two legs, each paced the same way (Apple Maps' fly). When one view
/// already has the other's middle in it (your street in the country) the pull-out is left out: one straight zoom. With Reduce Motion every move is one
/// 0.3 s ease, no pull-out.
enum CameraPace {
    /// The shortest and longest leg, seconds.
    static let minimum: TimeInterval = 0.5
    static let maximum: TimeInterval = 1.6
    /// Every move with Reduce Motion.
    static let reduced: TimeInterval = 0.3
    /// A portrait phone's width for its height (402 × 874 pt).
    static let aspect = 0.46
    static let base: TimeInterval = 0.35
    static let perWidth: TimeInterval = 0.3
    static let perHalving: TimeInterval = 0.15
    /// Past these a move is a long hop.
    static let longWidths = 1.5
    static let longHalvings = 3.0
    /// The pull-out view keeps both ends this far in from its edges (1.4 = a fifth of the view each side).
    static let peakMargin = 1.4
    /// A pull-out that would move less than this is left out.
    static let skipWidths = 0.25
    static let skipHalvings = 0.3
    /// Under these a change is a nudge (a follow step; a re-centre for the sheet, up to a quarter of the view tall, 0.54
    /// widths): it never takes over a flight.
    static let nudgeWidths = 0.6
    static let nudgeHalvings = 0.5

    enum Curve: Equatable, Sendable {
        /// A short hop.
        case glide
        /// The first leg of a long hop: out, and across.
        case pullOut
        /// The last leg of a long hop, or a straight zoom: in, slowing as it lands.
        case settle
        /// Reduce Motion.
        case reduced
    }

    struct Leg: Equatable, Sendable {
        var to: CameraView
        var duration: TimeInterval
        var curve: Curve
    }

    /// How far the middle moves, in screen widths of the wider view.
    static func travel(from: CameraView, to: CameraView) -> Double {
        let cosLat = max(cos((from.latitude + to.latitude) / 2 * .pi / 180), 0.01)
        let dLat = to.latitude - from.latitude
        let dLon = (to.longitude - from.longitude) * cosLat
        let width = max(from.latitudeSpan, to.latitudeSpan, 1e-9) * aspect
        return (dLat * dLat + dLon * dLon).squareRoot() / width
    }

    /// How much the view grows or shrinks, in halvings (or doublings) of its height.
    static func zoom(from: CameraView, to: CameraView) -> Double {
        abs(log2(max(to.latitudeSpan, 1e-9) / max(from.latitudeSpan, 1e-9)))
    }

    /// One leg's time: the formula above, clamped to `minimum`…`maximum`.
    static func duration(from: CameraView, to: CameraView) -> TimeInterval {
        let raw = base + perWidth * log2(1 + travel(from: from, to: to)) + perHalving * zoom(from: from, to: to)
        return min(max(raw, minimum), maximum)
    }

    static func isLong(from: CameraView, to: CameraView) -> Bool {
        travel(from: from, to: to) > longWidths || zoom(from: from, to: to) >= longHalvings
    }

    /// Too small a change to pace as a move of its own: a follow step, a re-centre.
    static func isSmallAdjustment(from: CameraView, to: CameraView) -> Bool {
        travel(from: from, to: to) < nudgeWidths && zoom(from: from, to: to) < nudgeHalvings
    }

    /// What a move to `to` does now. `flyingTo`: the paced flight in the air (nil when none, or once the person has
    /// taken the map); `seen`: the camera as last drawn. A nudge of the flight's landing waits for it (`hold`); a
    /// nudge of a camera at rest keeps the short follow glide (`nudge`); anything else is paced and takes over
    /// (`fly`). `reaim`: the same target re-aimed once the map's scale is known, held unless it is off by a whole
    /// width or halving, so the first flight after launch isn't started again.
    static func decide(flyingTo: CameraView?, seen: CameraView?, to: CameraView, reaim: Bool = false) -> Decision {
        if let flyingTo {
            if reaim, travel(from: flyingTo, to: to) < 1, zoom(from: flyingTo, to: to) < 1 { return .hold }
            return isSmallAdjustment(from: flyingTo, to: to) ? .hold : .fly
        }
        if let seen, isSmallAdjustment(from: seen, to: to) { return .nudge }
        return .fly
    }

    enum Decision: Equatable, Sendable { case nudge, hold, fly }

    /// A nudge applied without pacing (a held refit): the shortest glide, or the Reduce Motion ease.
    static func nudgeAnimation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: reduced) : .smooth(duration: minimum)
    }

    /// The pull-out: halfway between, tall enough to have both middles a margin in from its edges, and never closer
    /// than either end.
    static func peak(from: CameraView, to: CameraView) -> CameraView {
        let cosLat = max(cos((from.latitude + to.latitude) / 2 * .pi / 180), 0.01)
        let dLat = abs(to.latitude - from.latitude)
        let dLon = abs(to.longitude - from.longitude) * cosLat
        let span = max(from.latitudeSpan, to.latitudeSpan, dLat * peakMargin, dLon * peakMargin / aspect)
        return CameraView(latitude: (from.latitude + to.latitude) / 2, longitude: (from.longitude + to.longitude) / 2,
                          latitudeSpan: min(span, 170))
    }

    /// Whether the closer view's middle is already inside the wider view: then the long hop is one straight zoom (in
    /// or out), with nothing to pull out to.
    static func nests(_ a: CameraView, _ b: CameraView) -> Bool {
        let (wide, close) = a.latitudeSpan >= b.latitudeSpan ? (a, b) : (b, a)
        let cosLat = max(cos(wide.latitude * .pi / 180), 0.01)
        return abs(close.latitude - wide.latitude) <= wide.latitudeSpan / 2
            && abs(close.longitude - wide.longitude) * cosLat <= wide.latitudeSpan * aspect / 2
    }

    /// The legs from `from` (nil when the map hasn't reported a camera yet) to `to`; the last leg ends on `to`.
    static func legs(from: CameraView?, to: CameraView, reduceMotion: Bool) -> [Leg] {
        if reduceMotion { return [Leg(to: to, duration: reduced, curve: .reduced)] }
        guard let from else { return [Leg(to: to, duration: minimum, curve: .glide)] }
        guard isLong(from: from, to: to) else { return [Leg(to: to, duration: duration(from: from, to: to), curve: .glide)] }
        let top = peak(from: from, to: to)
        if nests(from, to) || (travel(from: from, to: top) < skipWidths && zoom(from: from, to: top) < skipHalvings) {
            return [Leg(to: to, duration: duration(from: from, to: to), curve: .settle)]
        }
        return [Leg(to: top, duration: duration(from: from, to: top), curve: .pullOut),
                Leg(to: to, duration: duration(from: top, to: to), curve: .settle)]
    }

    /// The animation a leg runs on. The pull-out eases in and out, so the camera rests a moment at the top while the
    /// tiles there load; the settle starts briskly and lands softly.
    static func animation(_ leg: Leg) -> Animation {
        switch leg.curve {
        case .glide: .smooth(duration: leg.duration)
        case .pullOut: .easeInOut(duration: leg.duration)
        case .settle: .timingCurve(0.3, 0, 0.2, 1, duration: leg.duration)
        case .reduced: .easeInOut(duration: leg.duration)
        }
    }
}

/// Runs one camera move at a time, leg after leg (`CameraPace`). A new move takes over the one in flight: its next
/// leg never runs, and MapKit carries the camera on from wherever it is. A nudge during a flight (`hold`) waits for
/// the landing instead of cutting it short (`CameraPace.decide`). A placement without animation (`cancel`) or a
/// gesture (`continues` turning false) ends the flight where it is, at once.
@MainActor
final class CameraFlight {
    /// The view the flight in progress lands on; nil when nothing is flying, and from the moment the person takes
    /// the map (`continues` false), so a move asked for after a pan always runs.
    var destination: CameraView? {
        guard let flyingTo, continues() else { return nil }
        return flyingTo
    }
    private var flyingTo: CameraView?
    private var continues: @MainActor () -> Bool = { true }
    private var task: Task<Void, Never>?
    private var held: (() -> Void)?
    private let timeScale: Double

    /// `timeScale` shortens every leg (tests).
    init(timeScale: Double = 1) { self.timeScale = timeScale }

    var isFlying: Bool { destination != nil }

    /// Flies to `position` (which shows `view`) from `from`. The first leg is set at once, in the caller's
    /// transaction; the rest follow each other's end. `continues` is asked before each later leg (false: the person
    /// has taken the map, stop).
    func fly(to position: MapCameraPosition, view: CameraView, from: CameraView?, reduceMotion: Bool,
             continues: @escaping @MainActor () -> Bool = { true },
             set: @escaping @MainActor (MapCameraPosition) -> Void) {
        cancel()
        let legs = CameraPace.legs(from: from, to: view, reduceMotion: reduceMotion)
        func target(of index: Int) -> MapCameraPosition {
            index == legs.count - 1 ? position : .region(legs[index].to.region)
        }
        flyingTo = view
        self.continues = continues
        withAnimation(CameraPace.animation(legs[0])) { set(target(of: 0)) }
        let scale = timeScale
        task = Task { [weak self] in
            for index in legs.indices {
                try? await Task.sleep(for: .seconds(legs[index].duration * scale))
                guard !Task.isCancelled else { return }
                guard continues() else { self?.cancel(); return }
                if index + 1 < legs.count {
                    withAnimation(CameraPace.animation(legs[index + 1])) { set(target(of: index + 1)) }
                }
            }
            self?.land()
        }
    }

    /// Runs `apply` once the flight lands (the latest one only), or now when nothing is flying (or the person has
    /// taken the map).
    func hold(_ apply: @escaping () -> Void) {
        if isFlying { held = apply } else { apply() }
    }

    /// Ends the flight where it is, dropping its later legs and anything held.
    func cancel() {
        task?.cancel()
        task = nil
        flyingTo = nil
        continues = { true }
        held = nil
    }

    private func land() {
        let apply = held
        task = nil
        flyingTo = nil
        continues = { true }
        held = nil
        apply?()
    }
}
