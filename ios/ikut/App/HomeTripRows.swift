import SwiftUI

// The list rows of Home's sheet (D63 B1), cut from TripsHomeView: each takes what it draws and nothing else. They sit in
// a system `List` (D86): the row's size, insets, separators and press come from the list.

/// A trip that hasn't ended: its name and where it is now.
struct HomeNowRow: View {
    let entry: PastTrips.Entry
    /// The line read for it; nil until it arrives.
    let status: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: Symbol.finish)
                .ikutGlyph(14, weight: .semibold, cap: 1.3)
                .foregroundStyle(.white)
                .iconFrame(.small)
                .background(Color.ikutAccent, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.semibold)).foregroundStyle(Color.primary)
                Text(status ?? HomeNow.fallbackStatus)
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes(lines: 2)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: Symbol.forward).font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the trip")
    }
}

/// A finished trip: its name, who was along and when it ended.
struct HomePastRow: View {
    let entry: PastTrips.Entry

    var body: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.medium)).foregroundStyle(Color.primary)
                Text(PastTrips.withPhrase(entry.others) ?? PickedTripLogic.subtitle(entry))
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes()
            }
            Spacer(minLength: Spacing.s)
            if let ended = entry.endedAt {
                Text(ended.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the trip on the map")
    }
}
