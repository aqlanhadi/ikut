#if DEBUG
import ActivityKit
import CoreLocation
import OSLog
import SwiftUI

/// `IKUT_SCREEN=live-activity-spike` (D3 piece 0): a Debug-only button that starts a Live Activity and updates it every
/// 5 seconds, running the tracker's `CoreLocationSource` (background location, as the car's tracker phone does), so it can be watched on the Lock Screen
/// and in the Dynamic Island with the phone locked. `IKUT_AUTOSTART=1` presses the button on launch.
struct LiveActivitySpikeDemo: View {
    @State private var status = "Not started"
    @State private var ticks = 0
    @State private var activity: ActivityBox?
    @State private var tracker: CoreLocationSource?
    @State private var timer: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            Text(status).accessibilityIdentifier(AXID.Debug.liveActivityStatus)
            Button("Start live activity", action: start)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AXID.Debug.liveActivityStart)
            Button("End", action: end).buttonStyle(.bordered)
        }
        .task {
            if ProcessInfo.processInfo.environment["IKUT_AUTOSTART"] == "1" { start() }
        }
    }

    private func start() {
        guard activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { status = "Live Activities are off"; return }
        let source = CoreLocationSource()
        source.start { _ in }
        tracker = source
        do {
            activity = try ActivityBox(
                tripName: "Balik kampung", first: .init(line: "Waiting to leave", tick: 0))
            status = "Started"
        } catch {
            status = "Could not start: \(error.localizedDescription)"
            return
        }
        timer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                ticks += 1
                await activity?.update(.init(line: "Driving, \(ticks * 5) s", tick: ticks))
                status = "Updated \(ticks)"
                Logger(subsystem: "dev.aqlan.ikut", category: "spike").notice("activity updated \(ticks)")
            }
        }
    }

    private func end() {
        timer?.cancel()
        let current = activity
        activity = nil
        tracker?.stop()
        tracker = nil
        Task { await current?.end() }
        status = "Ended"
    }
}

/// ActivityKit's calls are async and not main-actor, so the activity is held where Swift 6 can pass it around.
private final class ActivityBox: @unchecked Sendable {
    private let activity: Activity<ConvoyActivityAttributes>

    init(tripName: String, first: ConvoyActivityAttributes.ContentState) throws {
        activity = try Activity.request(
            attributes: ConvoyActivityAttributes(tripName: tripName), content: .init(state: first, staleDate: nil))
    }

    func update(_ state: ConvoyActivityAttributes.ContentState) async {
        await activity.update(.init(state: state, staleDate: nil))
    }

    func end() async { await activity.end(nil, dismissalPolicy: .immediate) }
}
#endif
