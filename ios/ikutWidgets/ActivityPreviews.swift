#if DEBUG
import SwiftUI
import WidgetKit

/// Xcode previews of every widget view (D3): the Lock Screen card and the Dynamic Island (compact, minimal, expanded)
/// stepping through every state the app shows, and the track on its own. The states come from
/// `LiveActivitySamples` (`ConvoyActivityLogic.state` on the same sample convoy as the `IKUT_SCREEN=live-activity-*`
/// launch states), so a preview is the real state. Debug builds only.
///
/// Open this file, show the canvas, and pick a preview by name: "Lock Screen", "Island compact", "Island minimal",
/// "Island expanded" (use the state stepper under the canvas for each state, in the order of
/// `LiveActivitySamples.names`), and "Track: cars", "Track: hazard", "Track: stop ring", "Track: dimmed".
/// The previews can't mark a state stale, so "not-updating" shows the greyed look only in "Track: dimmed" (the card
/// greys the same way when `isStale` is true).
private enum Samples {
    static let attributes = ConvoyActivityAttributes(tripId: "preview")
    static func state(_ name: String) -> ConvoyActivityAttributes.ContentState { LiveActivitySamples.state(name).state }
}

#Preview("Lock Screen", as: .content, using: Samples.attributes) {
    ConvoyLiveActivity()
} contentStates: {
    for name in LiveActivitySamples.names { Samples.state(name) }
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: Samples.attributes) {
    ConvoyLiveActivity()
} contentStates: {
    for name in LiveActivitySamples.names { Samples.state(name) }
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: Samples.attributes) {
    ConvoyLiveActivity()
} contentStates: {
    for name in LiveActivitySamples.names { Samples.state(name) }
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: Samples.attributes) {
    ConvoyLiveActivity()
} contentStates: {
    for name in LiveActivitySamples.names { Samples.state(name) }
}

/// The track on the card's own background and width (366 pt card less its margins), one state per preview.
private struct TrackSheet: View {
    let state: ConvoyActivityAttributes.ContentState
    var dimmed = false

    var body: some View {
        ActivityTrack(state: state, dimmed: dimmed)
            .padding(ActivitySize.cardInsets)
            .frame(width: 366)
            .background(ActivityPalette.trackGap)
    }
}

/// Eight cars, my car in the middle, no stop ring: the spacing and the rings at their busiest.
private func busyTrack() -> ConvoyActivityAttributes.ContentState {
    var state = Samples.state("in-convoy")
    let colours = ["#D9480F", "#7C3AED", "#0D9488", "#2563EB", "#C2255C", "#E67700", "#1971C2", "#2F9E44"]
    let places = [0.08, 0.2, 0.33, 0.5, 0.62, 0.74, 0.86, 0.95]
    state.cars = zip(places, colours).map { ConvoyActivityAttributes.CarMark(at: $0, color: $1, isMine: $0 == 0.5) }
    state.stopRing = nil
    return state
}

#Preview("Track: cars") {
    VStack(spacing: 16) {
        TrackSheet(state: Samples.state("in-convoy"))
        TrackSheet(state: busyTrack())
    }
}

#Preview("Track: hazard") {
    TrackSheet(state: Samples.state("hazard"))
}

#Preview("Track: stop ring") {
    TrackSheet(state: Samples.state("in-convoy"))
}

#Preview("Track: dimmed") {
    TrackSheet(state: Samples.state("in-convoy"), dimmed: true)
}
#endif
