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
