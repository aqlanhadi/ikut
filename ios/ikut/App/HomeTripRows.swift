import SwiftUI

// The list rows of Home's sheet (D63 B1), cut from TripsHomeView: each takes what it draws and nothing else.

/// "Now" or "Past trips" above a group.
struct HomeSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.surfaceSecondary)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A group of rows on a tile, a divider between them; tapping one opens it.
struct HomeTripGroup<Row: View>: View {
    let entries: [PastTrips.Entry]
    let open: (PastTrips.Entry) -> Void
    @ViewBuilder let row: (PastTrips.Entry) -> Row

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { RowDivider() }
                Button { open(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
            }
        }
        .surfaceTile(radius: Radius.inner)
    }
}

/// A trip that hasn't ended: its name and where it is now.
struct HomeNowRow: View {
    let entry: PastTrips.Entry
    /// The line read for it; nil until it arrives.
    let status: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "flag.checkered")
                .ikutGlyph(14, weight: .semibold, cap: 1.3)
                .foregroundStyle(.white)
                .iconFrame(.small)
                .background(Color.ikutAccent, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(status ?? HomeNow.fallbackStatus)
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes(lines: 2)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
        }
        .padding(.horizontal, Spacing.m)
        .ikutRow()
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
                Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(PastTrips.withPhrase(entry.others) ?? PickedTripLogic.subtitle(entry))
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).wrapsAtAccessibilitySizes()
            }
            Spacer(minLength: Spacing.s)
            if let ended = entry.endedAt {
                Text(ended.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .padding(.horizontal, Spacing.m)
        .ikutRow()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the trip on the map")
    }
}
