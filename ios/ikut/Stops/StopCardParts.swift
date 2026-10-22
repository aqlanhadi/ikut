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
                closeOffset: CGSize(width: Spacing.xs, height: -Spacing.xs), closeIdentifier: "stop.card.close", closeOnGlass: true,
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
                            // Shorter and not quite clear on glass, so a half-shown row stays readable.
                            LinearGradient(
                                colors: [.black, GlassSurface.active ? .black.opacity(0.4) : .clear],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: GlassSurface.active ? 14 : 24)
                        })
            } else {
                natural
            }
            VStack(spacing: Spacing.xs) { actions }
        }
        // 20 pt on every edge: 16 would put the title inside the 38 pt corner curve. The same surface as the
        // convoy panel. No grabber and no swipe down to close: the body scrolls, so a swipe is for
        // scrolling; the close button is the way out.
        .padding(.horizontal, Spacing.block)
        .padding(.top, Spacing.block)
        .padding(.bottom, Spacing.block)
        .glassSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.card")
    }
}

/// A place row's trailing cost: "On route", or "+4 min" over "1.5 km off route".
struct StopCostText: View {
    var candidate: StopCandidate
    /// Leading-aligned under the name (accessibility sizes) instead of a trailing column.
    var stacked = false

    var body: some View {
        VStack(alignment: stacked ? .leading : .trailing, spacing: 1) {
            Text(candidate.costText).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            if let off = candidate.offRouteText {
                Text(off).font(.caption2).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .multilineTextAlignment(stacked ? .leading : .trailing)
        .fixedSize(horizontal: !stacked, vertical: false)
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
                .padding(.horizontal, large ? Spacing.l : 0)
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .surfaceButton(role, fill: background, foreground: foreground)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    /// Primary and secondary are Liquid Glass buttons on iOS 26; the rest stay flat.
    private var role: SurfaceButtonRole {
        switch style {
        case .primary: .primary
        case .secondary: .secondary
        case .positive, .ghost, .destructive: .flat
        }
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
                Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.footnote.weight(.semibold)).foregroundStyle(Color.ikutPositive)
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stop.place")
    }
}

/// One car in a stop's list: its badge, its name, and how it stands ("Agreed", "Here", "6 min away").
struct StopVoterRow: View {
    var row: StopRequestState.Row
    @Environment(\.colorScheme) private var scheme

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
                .foregroundStyle(chipText(status.color))
                .padding(.horizontal, Spacing.gap)
                .padding(.vertical, 5)
                .background(status.color.opacity(GlassSurface.active ? 0.2 : 0.14), in: Capsule())
                .background(GlassSurface.active && scheme == .dark ? Color.black.opacity(0.4) : .clear, in: Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StopLogic.voterAccessibilityLabel(row))
        .accessibilityIdentifier("stop.voter.\(row.number.map(String.init) ?? row.carId)")
    }

    /// On dark glass the chip text is lifted toward white and the chip sits on a darker base, so
    /// Agreed (green) and Waiting (gray) read clearly and apart.
    private func chipText(_ color: Color) -> Color {
        guard GlassSurface.active, scheme == .dark, #available(iOS 18, *) else { return color }
        return color.mix(with: .white, by: 0.35)
    }

    static func status(_ row: StopRequestState.Row) -> (text: String, color: Color) {
        switch row.arrival {
        case .here?: return ("Here", Color.ikutPositive)
        case .minutes(let minutes)?: return ("\(minutes) min away", Color.surfaceSecondary)
        case nil: break
        }
        switch row.status {
        case .agreed: return ("Agreed", Color.ikutPositive)
        case .waiting: return ("Waiting", Color.surfaceSecondary)
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
        .surfaceTile()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.timeline")
    }

    private func step(_ title: String, detail: String?, done: Bool) -> some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dotted")
                .font(.title3)
                .foregroundStyle(done ? Color.ikutPositive : Color.surfaceSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.semibold))
                if let detail, !detail.isEmpty { Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary) }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Buttons and tiles") {
    VStack(spacing: Spacing.s) {
        StopActionButton(title: "Ask for this stop", style: .primary, id: "p") {}
        StopActionButton(title: "Ask for this stop", style: .primary, height: 72, id: "p-big") {}
        StopActionButton(title: "Ask for this stop", style: .primary, disabled: true, id: "p-off") {}
        StopActionButton(title: "Another place", id: "s") {}
        StopActionButton(title: "You said yes", style: .positive, id: "y") {}
        StopActionButton(title: "Back", style: .ghost, height: 44, id: "g") {}
        StopActionButton(title: "Cancel the request", style: .destructive, height: 44, id: "d") {}
        HStack(spacing: Spacing.m) {
            StopReasonIcon(symbol: "fuelpump.fill")
            StopReasonIcon(symbol: "fork.knife", size: 40)
            StopReasonIcon(symbol: "toilet.fill", size: 34)
        }
        StopPlaceTile(name: "Petronas Tapah R&R", detail: "18 km · 12 min", trailing: "On route")
        StopPlaceTile(name: "Shell Gopeng, Jalan Besar off the old trunk road", detail: "31 km · 22 min", trailing: nil)
    }
    .padding(Spacing.l)
}

#Preview("Voter rows") {
    func row(_ id: String, _ n: Int, _ color: String, _ name: String, mine: Bool = false,
             _ status: StopRequestState.VoteStatus, suggestion: String? = nil,
             arrival: StopRequestState.Arrival? = nil) -> StopRequestState.Row {
        .init(carId: id, number: n, colorHex: color, name: name, isMine: mine, status: status,
              suggestion: suggestion.map { StopPlace(name: $0, coordinate: .init(latitude: 4.34, longitude: 101.2),
                                                       routeOffset: 70_000, pinnedBy: nil) },
              arrival: arrival)
    }
    let rows = [
        row("c1", 1, "#2563EB", "Aqlan’s Myvi (you)", mine: true, .agreed),
        row("c2", 2, "#D9480F", "Wyna’s X70", .waiting),
        row("c3", 3, "#0F766E", "Hafiz’s Hilux", .notNow),
        row("c4", 4, "#7C3AED", "Daniel’s City", .suggested, suggestion: "Shell Gopeng"),
        row("c5", 5, "#BE185D", "Faiz’s car", .agreed, arrival: .here),
        row("c6", 6, "#CA8A04", "Siti’s Bezza", .agreed, arrival: .minutes(6)),
    ]
    return VStack(spacing: Spacing.xs) {
        ForEach(rows) { StopVoterRow(row: $0) }
    }
    .padding(Spacing.l)
}

#if DEBUG
#Preview("Timeline") {
    VStack(spacing: Spacing.m) {
        if let asked = MapDemo.stopBoard("asker").requests.first { StopTimeline(state: asked) }
        if let pinned = MapDemo.stopBoard("pinned").requests.first { StopTimeline(state: pinned) }
    }
    .padding(Spacing.l)
}
#endif

#Preview("Frame") {
    VStack(spacing: Spacing.m) {
        StopCardFrame(title: "Asked the convoy", subtitle: "Waiting for the other cars", onClose: {}) {
            Text("The lead car pins the place once the cars have answered.").foregroundStyle(Color.surfaceSecondary)
        } actions: {}
        // Taller than the cap: the body scrolls and the actions stay put.
        StopCardFrame(title: "Another place", subtitle: nil, onClose: {}) {
            ForEach(1...8, id: \.self) { StopPlaceTile(name: "Place \($0)", detail: "\($0 * 4) km · \($0 * 3) min", trailing: nil) }
        } actions: {
            StopActionButton(title: "Back", style: .ghost, height: 44, id: "back") {}
        }
    }
    .padding(Spacing.s)
    .frame(maxHeight: .infinity, alignment: .bottom)
    .background(Color(.systemGray4))
}
