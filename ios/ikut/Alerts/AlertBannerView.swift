import SwiftUI

/// In-app banner for the current alert. Overlay it at the top of the map; it hides itself when
/// there is no alert and when the alert times out.
struct AlertBannerView: View {
    var center: AlertCenter
    /// Categories not to show right now, e.g. a stop request while its own card is up. The alert
    /// stays current in the center (and still times out); only the banner is held back.
    var hiding: Set<EventCategory> = []
    /// One alert shown elsewhere (the approach alert and its pill).
    var hidingAlertId: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: TripAlert? {
        guard let alert = center.current, !hiding.contains(alert.category), alert.id != hidingAlertId else { return nil }
        return alert
    }

    var body: some View {
        // Zero-height container: always in the hierarchy so the insertion/removal transition runs,
        // and it adds no stack spacing while empty.
        ZStack(alignment: .top) {
            if let alert = shown {
                banner(alert)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.82), value: shown)
    }

    private func banner(_ alert: TripAlert) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol(alert.category))
                .font(.title3.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(tint(alert.severity), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(alert.body).font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { center.dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func symbol(_ category: EventCategory) -> String {
        switch category {
        case .hazard: "exclamationmark.triangle.fill"
        case .condition: "cloud.rain.fill"
        case .stopRequest: "pause.circle.fill"
        case .status: "car.fill"
        case .message: "text.bubble.fill"
        }
    }

    private func tint(_ severity: Severity) -> Color {
        switch severity {
        case .high: .orange
        case .medium: .yellow
        case .low: .white
        }
    }
}
