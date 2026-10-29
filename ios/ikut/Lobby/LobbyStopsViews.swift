import SwiftUI

/// The pieces of the lobby's route card that belong to stops (LobbyStops.dc.html): a stop's row with its notes,
/// the total, and the shape that makes rows of a List read as one card.

/// A row of a List drawn as a slice of the lobby's white card: `top` and `bottom` round that end.
struct CardSlice: ViewModifier {
    @Environment(\.inPanelSheet) private var inSheet
    var top = false
    var bottom = false

    func body(content: Content) -> some View {
        let r = Radius.card
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: top ? r : 0, bottomLeadingRadius: bottom ? r : 0,
                    bottomTrailingRadius: bottom ? r : 0, topTrailingRadius: top ? r : 0, style: .continuous
                ).fill(inSheet && GlassSurface.active ? Color.surfaceTileFill : Color.ikutCard))
    }
}

extension View {
    func cardSlice(top: Bool = false, bottom: Bool = false) -> some View {
        modifier(CardSlice(top: top, bottom: bottom))
    }

    /// A List row that is one block of the lobby on the screen color, with the screen's side margins.
    func lobbyRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: Spacing.l, bottom: bottom, trailing: Spacing.l))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// What is wrong with a stop's road, drawn under the stop.
struct StopNote: View {
    enum Tone { case warning, failure }
    var tone: Tone
    var title: String
    var detail: String
    var retry: (() -> Void)?

    private var titleColor: Color {
        Color.ikutWarning
    }

    private var fill: Color {
        tone == .warning ? Color.orange.fill(.tint) : Color.red.fill(.tint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary)
            if let retry {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 36)
                        .background(Color.ikutCard, in: Capsule())
                        // Drawn 36 pt tall, taps over 44.
                        .padding(.vertical, Spacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ikutAccent)
                .padding(.top, Spacing.xs)
                .accessibilityIdentifier("stops.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
        .ikutSurface(fill, radius: Radius.inner)
    }
}

/// One planned stop: its number as on the map's pin (a person symbol for the meeting point, which takes none), its
/// name with the line under it ("About 1 h 35 min in · stay 20 min"), and for the organizer a drag handle.
struct StopRow: View {
    /// A note sits under the stop's name, past its icon (44) and the gap: 60.
    private static let noteIndent: CGFloat = 60
    var stop: StopDraft
    var text: LobbyContent.StopText
    var editable: Bool
    var first: Bool
    /// Extra meters the road turns back on itself near this stop, when it does.
    var turnBack: Double?
    var failure: StopPlanner.Failure?
    var failed: Bool
    var onRetry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: Spacing.m) {
                badge
                    .padding(.top, typeSize.isAccessibilitySize ? Spacing.s : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.name).foregroundStyle(failed ? .secondary : .primary)
                    Text(failed ? StopFormat.detail(stop) : text.detail).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if editable {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(Color.surfaceSecondary)
                        .padding(.horizontal, Spacing.s)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, Spacing.l).padding(.trailing, editable ? 6 : Spacing.l).padding(.vertical, Spacing.xs)
            .ikutRow()

            if let turnBack {
                let text = StopNoteText.turnBack(kind: stop.kind, extraMeters: turnBack)
                StopNote(tone: .warning, title: text.title, detail: text.detail)
                    .padding(.leading, Self.noteIndent).padding(.trailing, Spacing.m).padding(.bottom, Spacing.s)
            }
            if let failure {
                StopNote(
                    tone: .failure, title: StopNoteText.failureTitle(failure, stopName: stop.name, destinationName: ""),
                    detail: StopNoteText.failureDetail(failure), retry: onRetry)
                    .padding(.leading, Self.noteIndent).padding(.trailing, Spacing.m).padding(.bottom, Spacing.s)
            }
        }
        .overlay(alignment: .top) { if !first { Divider() } }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var badge: some View {
        if let number = text.number {
            Text("\(number)")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .iconFrame(.regular)
                .background(Color.ikutAccent, in: Circle())
        } else {
            Image(systemName: stop.kind.symbol)
                .ikutGlyph(14, weight: .semibold, cap: 1.3)
                .foregroundStyle(.white)
                .iconFrame(.regular)
                .background(stop.kind.tint, in: Circle())
        }
    }
}

/// The one line under the stops: "205 km · 2 h 40 + 35 min of stops", or why there is none.
struct RouteTotalLine: View {
    enum Content {
        case total(String, caption: String)
        case notReady
        case loading
        /// Nothing to total yet, and why: one quiet line.
        case pending(String)
    }
    var content: Content
    var dimmed = false

    var body: some View {
        VStack(spacing: Spacing.xxs) {
            switch content {
            case .total(let line, let caption):
                Text(line).font(.system(.headline, design: .rounded)).monospacedDigit().multilineTextAlignment(.center)
                Text(caption).font(.caption).foregroundStyle(Color.surfaceSecondary)
            case .notReady:
                Text("Route not ready").font(.system(.headline, design: .rounded))
                Text("The total shows once every stop has a road").font(.caption).foregroundStyle(Color.surfaceSecondary)
                    .multilineTextAlignment(.center)
            case .pending(let text):
                Text(text).font(.subheadline).foregroundStyle(Color.surfaceSecondary).multilineTextAlignment(.center)
            case .loading:
                ProgressView().accessibilityLabel("Getting the route")
            }
        }
        // Not a tappable row: a tile that keeps one height whether it shows the total or a spinner.
        .ikutRow(fillWidth: true)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .innerTile(radius: Radius.inner)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}
