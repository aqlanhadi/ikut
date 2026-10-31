import SwiftUI

/// "Convoy stopped · 12 min" under the trip pill while the convoy's stopped phase is on (D122), drawn like the paused
/// banner. The lead car's tracker and the organizer get Continue, which ends it for everyone; everyone else reads who
/// will. Reads `session.convoyStop`; the banner slot decides when it shows.
struct StoppedBanner: View {
    let session: TripSession
    var onError: (String) -> Void
    @State private var isContinuing = false

    var body: some View {
        let lead = session.mayEndConvoyStop
        HStack(spacing: Spacing.m) {
            Image(systemName: Symbol.parking)
                .font(.title3)
                .foregroundStyle(Color.ikutAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    let minutes = ConvoyStop.minutes(since: session.convoyStop?.since, now: timeline.date)
                    Text("Convoy stopped · \(minutes) min")
                        .font(.footnote.weight(.semibold))
                }
                if !lead {
                    Text("The lead car taps Continue when everyone’s ready")
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if lead {
                Button(action: continueConvoy) {
                    Text("Continue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentText)
                        .padding(.horizontal, Spacing.l)
                        .ikutRow()
                        .background(Color.ikutAccent.fill(.tint), in: Capsule())
                        .contentShape(Capsule())
                }
                .disabled(isContinuing)
                .accessibilityIdentifier(AXID.Trip.stoppedContinue)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .background(Color.ikutAccent.fill(.tint), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.Trip.stopped)
    }

    private func continueConvoy() {
        guard !isContinuing else { return }
        isContinuing = true
        Task {
            do { try await session.continueConvoy() } catch { onError("Couldn’t reach the convoy. Try again in a moment.") }
            isContinuing = false
        }
    }
}

extension ConvoyStop {
    /// Whole minutes since the convoy stopped, at least 1 (the banner never says "0 min").
    static func minutes(since: Date?, now: Date) -> Int {
        guard let since else { return 1 }
        return max(1, Int(now.timeIntervalSince(since) / 60))
    }
}
