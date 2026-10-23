import FirebaseAuth
import SwiftUI

/// The pinned part of Home's sheet when a past trip is picked (design/project/HomePicked.dc.html):
/// back, name, "To Ipoh · 31 Mar 2026", Share, then the stats line, the timeline item the map is
/// showing (with an X), or loading / couldn't load.
struct PickedTripHeader: View {
    var picked: PickedTrip
    var onBack: () -> Void
    var onShowWholeTrip: () -> Void

    var body: some View {
        let model = picked.model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.gap) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(Color(.tertiarySystemFill), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to trips")
                VStack(alignment: .leading, spacing: 1) {
                    Text(picked.title)
                        .font(.title2.bold()).lineLimit(2)
                        .accessibilityAddTraits(.isHeader)
                    Text(picked.subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let recap = model.recap {
                    ShareLink(item: RecapContent.shareText(recap)) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .background(Color(.tertiarySystemFill), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share recap")
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .padding(.top, Spacing.xxs)

            if model.recap != nil {
                if let item = picked.selectedItem {
                    selectedCard(item)
                } else if let line = picked.statsLine {
                    Text(line)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.gap)
                }
            } else if let message = model.errorMessage {
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.gap)
                Button("Try again") { Task { await model.retry(myUserId: Auth.auth().currentUser?.uid) } }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.ikutAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .contentShape(Capsule())
                    .padding(.top, Spacing.m)
            } else {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Loading the recap")
                }
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.m)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// The tapped timeline item, standing in for the stats line.
    private func selectedCard(_ item: RecapTimelineItem) -> some View {
        HStack(spacing: Spacing.m) {
            RecapEventDot(kind: item.kind, symbol: item.symbol, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text([RecapLogic.clock(item.time), item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: onShowWholeTrip) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show the whole trip")
        }
        .padding(.leading, Spacing.m).padding(.trailing, Spacing.s).padding(.vertical, Spacing.gap)
        .ikutCard(radius: 18)
        .padding(.top, Spacing.m)
    }
}

/// What scrolls under the pinned header when the sheet is pulled up: the recap's stat card, awards and
/// timeline, the same content the end-of-trip screen shows.
struct PickedTripBody: View {
    @Bindable var picked: PickedTrip
    var onSelect: (RecapTimelineItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recap = picked.model.recap, let snapshot = picked.model.snapshot {
                RecapContent(recap: recap, snapshot: snapshot, layout: .sheet, filter: $picked.filter, onSelect: onSelect)
            }
        }
    }
}
