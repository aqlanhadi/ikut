import SwiftUI

/// The frame of the stop card (Decision #84): header with a close button, a body that is as tall as
/// its content up to `maxBodyHeight` and scrolls past it, and the actions pinned at the bottom.
/// Opaque, with the convoy panel's inset and corner radius, because it sits on top of the panel.
struct StopCardFrame<Content: View, Actions: View>: View {
    /// The convoy list's own cap (`ConvoyPanel.maxListHeight`); the card body never grows past it.
    static var maxBodyHeight: CGFloat { 220 }

    var title: String
    var subtitle: String?
    /// The body scrolls past this height (default `maxBodyHeight`).
    var bodyCap: CGFloat = StopCardFrame.maxBodyHeight
    var onClose: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @State private var contentHeight: CGFloat = 0

    private func body(of content: Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.gap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            SheetHeader(
                title: title, subtitle: subtitle, subtitleFont: .subheadline,
                // 16 pt from the top and trailing edges: the 38 pt corner minus the button's 22 pt radius.
                closeOffset: CGSize(width: Spacing.xs, height: -Spacing.xs), closeIdentifier: "stop.card.close",
                onClose: onClose
            )
            .accessibilityAddTraits(.isHeader)
            // As tall as the content; past the cap the body scrolls. Nothing else fills the space.
            let natural = body(of: content)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            if contentHeight > bodyCap {
                ScrollView { natural }
                    .frame(height: bodyCap)
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    // The last rows fade out above the actions instead of being cut.
                    .mask(
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 14)
                        })
            } else {
                natural
            }
            VStack(spacing: Spacing.xs) { actions }
        }
        // 20 pt on every edge: 16 would put the title inside the 38 pt corner curve. The same frosted
        // material, clip and shadow as the convoy panel, and its grabber (drag down to close).
        .padding(.horizontal, Spacing.block)
        .padding(.top, Spacing.block)
        .padding(.bottom, Spacing.block)
        .overlay(alignment: .top) {
            Capsule()
                .fill(Color(.systemGray3))
                .frame(width: 36, height: 5)
                .padding(.top, Spacing.tight)
                .accessibilityHidden(true)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.card")
    }
}

/// A place row's trailing cost: "On route", or "+4 min" over "1.5 km off route".
struct StopCostText: View {
    var candidate: StopCandidate

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(candidate.costText).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            if let off = candidate.offRouteText {
                Text(off).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.trailing)
    }
}

/// One button in the card's action area. `.primary` is the main action (50 pt, or `height` when the
/// driver needs a huge one), `.secondary` a gray capsule, `.positive` the chosen answer, `.ghost` plain text.
struct StopActionButton: View {
    enum Style { case primary, secondary, positive, ghost, destructive }

    var title: String
    var style: Style = .secondary
    var height: CGFloat = 50
    var disabled = false
    var id: String
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // At accessibility sizes a long title wraps to two lines and the button grows, not truncates.
        let large = typeSize.isAccessibilitySize
        Button(action: action) {
            Text(title)
                .font(.headline)
                .lineLimit(large ? 2 : 1)
                .minimumScaleFactor(large ? 1 : 0.8)
                .multilineTextAlignment(.center)
                .padding(.vertical, large ? Spacing.s : 0)
                .frame(maxWidth: .infinity, minHeight: height)
                .foregroundStyle(foreground)
                .background(background, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    private var foreground: Color {
        switch style {
        case .primary: .white
        case .secondary: .primary
        case .positive: Color.ikutPositive
        case .ghost: Color.ikutAccent
        case .destructive: .red
        }
    }

    private var background: Color {
        switch style {
        case .primary: Color.ikutAccent
        case .secondary: Color(.systemGray5).opacity(0.7)
        case .positive: Color.green.opacity(0.16)
        case .ghost, .destructive: .clear
        }
    }
}

/// The reason's icon in an orange circle, as on the tiles.
struct StopReasonIcon: View {
    var symbol: String
    var size: CGFloat = 46

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.orange, in: Circle())
            .accessibilityHidden(true)
    }
}

/// The place with its distance and time: a pin tile, name, "18 km · 12 min", and a note ("On route").
struct StopPlaceTile: View {
    var name: String
    var detail: String
    var trailing: String?

    var body: some View {
        HStack(spacing: Spacing.m) {
            IconTile(symbol: "mappin", color: .red, size: 30, font: .footnote.weight(.bold))
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body.weight(.semibold)).lineLimit(2)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutTile()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stop.place")
    }
}

/// One car in a stop's list: its badge, its name, and how it stands ("Agreed", "Here", "6 min away").
struct StopVoterRow: View {
    var row: StopRequestState.Row

    var body: some View {
        let status = Self.status(row)
        HStack(spacing: Spacing.m) {
            CarBadge(number: row.number, colorHex: row.colorHex, size: 30)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.isMine ? "Me" : row.name).font(.body).lineLimit(1)
                if let suggestion = row.suggestion, row.arrival == nil {
                    Text("Suggests \(suggestion.name)").font(.footnote).foregroundStyle(Color.ikutWarning).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(status.text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(status.color)
                .padding(.horizontal, Spacing.gap)
                .padding(.vertical, 5)
                .background(status.color.opacity(0.14), in: Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StopLogic.voterAccessibilityLabel(row))
        .accessibilityIdentifier("stop.voter.\(row.number.map(String.init) ?? row.carId)")
    }

    static func status(_ row: StopRequestState.Row) -> (text: String, color: Color) {
        switch row.arrival {
        case .here?: return ("Here", Color.ikutPositive)
        case .minutes(let minutes)?: return ("\(minutes) min away", Color.secondary)
        case nil: break
        }
        switch row.status {
        case .agreed: return ("Agreed", Color.ikutPositive)
        case .waiting: return ("Waiting", Color.secondary)
        case .notNow: return ("Not now", Color.ikutWarning)
        case .suggested: return ("Another place", Color.ikutWarning)
        }
    }
}

/// Asked, Deciding, Lead pins the place: the asker's view of where the request stands.
struct StopTimeline: View {
    var state: StopRequestState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            step("Asked", detail: StopLogic.placeLine(state), done: true)
            step("Deciding", detail: StopLogic.decidingText(state), done: state.isPinned || state.agreedCount == state.rows.count)
            step("Lead pins the place", detail: state.isPinned ? state.place?.name : "The lead car chooses where", done: state.isPinned)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutTile()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.timeline")
    }

    private func step(_ title: String, detail: String?, done: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.title3)
                .foregroundStyle(done ? Color.ikutPositive : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
