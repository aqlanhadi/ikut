#if DEBUG
import OSLog
import SwiftUI

/// `IKUT_SCREEN=live-activity-<state>` (D3 piece 2a): starts a real Live Activity with that state's canned content, so
/// it can be looked at on the Lock Screen, in the Dynamic Island (compact, minimal, expanded) and on a CarPlay or Watch
/// card. The content is made by `ConvoyActivityLogic.state` from a sample convoy, so the states are the real ones.
/// Names: waiting, waiting-organiser, joining, joining-destination, parked-ahead, heads-up, in-convoy, last-leg,
/// at-stop, hazard, hazard-no-distance, stop-request, after-ok, my-request, stopped, stopped-lead, paused,
/// not-updating, arrived, ended.
struct LiveActivityDemo: View {
    let name: String
    @State private var status = "Not started"
    @State private var client: ActivityKitClient?

    var body: some View {
        VStack(spacing: Spacing.l) {
            Text(name).font(.headline)
            Text(status).accessibilityIdentifier(AXID.Debug.liveActivityStatus)
            Button("Show on the Lock Screen", action: start)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AXID.Debug.liveActivityStart)
            Button("End", action: end).buttonStyle(.bordered)
        }
        .task { start() }
    }

    private func start() {
        end()
        let client = ActivityKitClient(tripId: "demo-\(name)")
        guard client.isEnabled else { status = "Live Activities are off for ikut"; return }
        let (state, staleDate) = LiveActivitySamples.state(name)
        do {
            try client.start(tripId: "demo-\(name)", state: state, staleDate: staleDate)
            self.client = client
            status = "Started: \(state.kind.rawValue)"
            Logger(subsystem: "dev.aqlan.ikut", category: "liveActivityDemo").notice("\(status, privacy: .public)")
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            Logger(subsystem: "dev.aqlan.ikut", category: "liveActivityDemo").notice("\(status, privacy: .public)")
        }
    }

    private func end() {
        client?.end(final: nil, dismissAfter: nil)
        client = nil
    }
}
#endif
