import FirebaseAuth
import SwiftUI

/// The pinned part of Home's sheet when a past trip is picked (design/project/HomePicked.dc.html):
/// back, name, "To Ipoh · 31 Mar 2026", Share, then the stats line, the timeline item the map is
/// showing (with an X), or loading / couldn't load.
struct PickedTripHeader: View {
    var picked: PickedTrip
    var onBack: () -> Void
    var onShowWholeTrip: () -> Void
    @ScaledMetric(relativeTo: .body) private var buttonSide = SheetButtonSize.hit
    /// Holds Share's place while the recap loads, so the title doesn't shift when it arrives.
    private var placeholderSide: CGFloat { SheetButtonSize.capped(buttonSide, base: SheetButtonSize.hit) }

    var body: some View {
        let model = picked.model
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.s) {
                RoundGlassIconButton(systemImage: Symbol.back, label: "Back to trips", style: .quiet, action: onBack)
                VStack(alignment: .leading, spacing: 1) {
                    Text(picked.title)
                        .font(.title2.bold()).wrapsAtAccessibilitySizes(lines: 2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(picked.subtitle).font(.footnote).foregroundStyle(.secondary).wrapsAtAccessibilitySizes(lines: 2).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let recap = model.recap {
                    ShareLink(item: RecapContent.shareText(recap)) {
                        RoundIconSymbol(systemImage: Symbol.share, glyph: .callout.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share recap")
                } else {
                    Color.clear.frame(width: placeholderSide, height: placeholderSide)
                }
            }
            .padding(.top, Spacing.xxs)

            if picked.isLeft {
                // A trip left early: its route only, and why there is no recap. Nothing to retry.
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(PickedTripLogic.leftTitle).font(.subheadline.weight(.semibold))
                    Text(PickedTripLogic.leftLine).font(.footnote).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.s)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.Home.pickedLeft)
            } else if model.recap != nil {
                if let item = picked.selectedItem {
                    selectedCard(item)
                } else if let line = picked.statsLine {
                    Text(line)
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.s)
                }
            } else if let message = model.errorMessage {
                Text(message)
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.xxs).padding(.top, Spacing.s)
                Button("Try again") { Task { await model.retry(myUserId: Auth.auth().currentUser?.uid) } }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentText)
                    .ikutRow(fillWidth: true)
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
                Text(item.title).font(.subheadline.weight(.semibold)).wrapsAtAccessibilitySizes(lines: 2).fixedSize(horizontal: false, vertical: true)
                Text([RecapLogic.clock(item.time), item.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).wrapsAtAccessibilitySizes(lines: 2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            RoundGlassIconButton(systemImage: Symbol.close, label: "Show the whole trip", style: .bare, action: onShowWholeTrip)
        }
        .padding(.leading, Spacing.m).padding(.trailing, Spacing.s).padding(.vertical, Spacing.s)
        .ikutCard(radius: 18)
        .padding(.top, Spacing.m)
    }
}

/// What scrolls under the pinned header when the sheet is pulled up: the recap's stat tiles, awards and
/// timeline as list sections (the host wraps them in an inset-grouped `List`), the same content the end-of-trip screen shows.
struct PickedTripBody: View {
    @Bindable var picked: PickedTrip
    var onSelect: (RecapTimelineItem) -> Void

    var body: some View {
        if !picked.isLeft, let recap = picked.model.recap, let snapshot = picked.model.snapshot {
            RecapContent(recap: recap, snapshot: snapshot, layout: .sheet, filter: $picked.filter, onSelect: onSelect)
        }
    }
}
