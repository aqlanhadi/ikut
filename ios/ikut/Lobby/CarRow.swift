import SwiftUI

struct CarRow: View {
    let item: LobbyCar
    /// 1-based place in the list, used when the car has no number of its own.
    let position: Int
    let currentUserId: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            CarBadge(number: item.car.number ?? position, colorHex: item.car.color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.tight) {
                    Text(item.car.name)
                    if item.car.isLead {
                        Text("Lead")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.xxs)
                            .background(.fill.secondary, in: Capsule())
                    }
                }
                Text(people)
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.s)
            let color = item.hasTracker ? Color.ikutPositive : Color.ikutWarning
            Text(item.hasTracker ? "Tracking" : "Waiting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, Spacing.chipX)
                .padding(.vertical, 3)
                .background(color.opacity(0.14), in: Capsule())
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
    }

    private var people: String {
        LobbyLogic.peopleLine(
            members: item.members, trackerUserId: item.car.trackerUserId, currentUserId: currentUserId)
    }
}
