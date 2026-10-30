import SwiftUI

/// "Sharing paused · back on in 28 min" with a Resume button. Reads `session.isPaused`;
/// the owner decides when to show it. Failures go to `onError`, or are shown under the banner
/// when no handler is given.
struct PausedBanner: View {
    let session: TripSession
    var onError: ((String) -> Void)?
    /// Stands in for `car.pausedAt` in the moment between pausing and the car doc update arriving.
    @State private var shownAt = Date()
    @State private var isResuming = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.m) {
                Image(systemName: Symbol.paused)
                    .font(.title3)
                    .foregroundStyle(Color.ikutWarning)
                    .accessibilityHidden(true)
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(PausedBannerText.message(remaining: Self.remaining(pausedAt: session.car?.pausedAt ?? shownAt, now: timeline.date)))
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: resume) {
                    Text("Resume")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.ikutAccent)
                        .padding(.horizontal, Spacing.l)
                        .ikutRow()
                        .background(Color.ikutAccent.fill(.tint), in: Capsule())
                        .contentShape(Capsule())
                }
                .disabled(isResuming)
            }
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .background(Color.ikutWarning.fill(.tint), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    static func remaining(pausedAt: Date, now: Date) -> TimeInterval {
        pausedAt.addingTimeInterval(TripSessionLogic.pauseExpiry).timeIntervalSince(now)
    }

    private func resume() {
        guard !isResuming else { return }
        isResuming = true
        error = nil
        Task {
            do { try await session.resumeSharing() } catch {
                let message = error.localizedDescription
                if let onError { onError(message) } else { self.error = message }
            }
            isResuming = false
        }
    }
}

enum PausedBannerText {
    /// "Sharing paused · back on in 28 min". Whole minutes, rounded up, at least 1.
    static func message(remaining: TimeInterval) -> String {
        let minutes = max(1, Int((max(0, remaining) / 60).rounded(.up)))
        return "Sharing paused · back on in \(minutes) min"
    }
}

#Preview {
    Backend.configure()
    return PausedBanner(session: TripSession(tripId: "demo", userId: "u-c1"))
        .padding(Spacing.l)
}
