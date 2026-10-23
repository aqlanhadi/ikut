import SwiftUI

/// The pieces of the lobby's route card that belong to stops (LobbyStops.dc.html): a stop's row with its notes,
/// the total, and the shape that makes rows of a List read as one card.

/// A row of a List drawn as a slice of the lobby's white card: `top` and `bottom` round that end.
struct CardSlice: ViewModifier {
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
                ).fill(Color.ikutCard))
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
        tone == .warning ? Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 1) : UIColor(red: 0.71, green: 0.28, blue: 0.03, alpha: 1) }) : .ikutWarning
    }

    private var fill: Color {
        tone == .warning ? Color.orange.opacity(0.18) : Color.red.opacity(0.14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(titleColor)
            Text(detail).font(.footnote).foregroundStyle(.secondary)
            if let retry {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Spacing.cozy)
                        .frame(minHeight: 36)
                        .background(Color.ikutCard, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.ikutAccent)
                .padding(.top, Spacing.xs)
                .accessibilityIdentifier("stops.retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.gap)
        .ikutSurface(fill, radius: Radius.control)
    }
}

/// One planned stop: its kind's icon, name, "Fuel · 20 min", how far along, and (for the organizer) a drag handle.
struct StopRow: View {
    var stop: StopDraft
    var editable: Bool
    var first: Bool
    /// Extra meters the road turns back on itself near this stop, when it does.
    var turnBack: Double?
    var failure: StopPlanner.Failure?
    var failed: Bool
    var onRetry: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var offsetText: String? {
        guard !failed, !stop.isMeeting || stop.routeOffset != nil, let offset = stop.routeOffset else { return nil }
        return StopFormat.along(meters: offset)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: Spacing.m) {
                Image(systemName: stop.kind.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(stop.kind.tint, in: Circle())
                    .padding(.top, typeSize.isAccessibilitySize ? Spacing.s : 0)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(stop.name).foregroundStyle(failed ? .secondary : .primary)
                    Text(StopFormat.detail(stop)).font(.footnote).foregroundStyle(.secondary)
                    if typeSize.isAccessibilitySize, let offsetText {
                        Text(offsetText).font(.system(.subheadline, design: .rounded).weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize, let offsetText {
                    Text(offsetText)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if editable {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 44)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, Spacing.l).padding(.trailing, editable ? 6 : Spacing.l).padding(.vertical, Spacing.xs)
            .frame(minHeight: 56)

            if let turnBack {
                let text = StopNoteText.turnBack(kind: stop.kind, extraMeters: turnBack)
                StopNote(tone: .warning, title: text.title, detail: text.detail)
                    .padding(.leading, 60).padding(.trailing, Spacing.m).padding(.bottom, Spacing.gap)
            }
            if let failure {
                StopNote(
                    tone: .failure, title: StopNoteText.failureTitle(failure, stopName: stop.name, destinationName: ""),
                    detail: StopNoteText.failureDetail(failure), retry: onRetry)
                    .padding(.leading, 60).padding(.trailing, Spacing.m).padding(.bottom, Spacing.gap)
            }
        }
        .overlay(alignment: .top) { if !first { Divider() } }
        .accessibilityElement(children: .combine)
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
                Text(caption).font(.caption).foregroundStyle(.secondary)
            case .notReady:
                Text("Route not ready").font(.system(.headline, design: .rounded))
                Text("The total shows once every stop has a road").font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .pending(let text):
                Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case .loading:
                ProgressView().accessibilityLabel("Getting the route")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.gap)
        .ikutSurface(Color.ikutScreen, radius: Radius.inner)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}
