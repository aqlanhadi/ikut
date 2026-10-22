import SwiftUI

/// The frame of the stop card (Decision #84): header with a close button, a body that is as tall as
/// its content up to `maxBodyHeight` and scrolls past it, and the actions fixed at the bottom.
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
                ScrollView { natural.padding(.bottom, GlassSurface.active ? 14 : 24) }
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

/// What a passenger typed, in full, on the card.
struct StopMessageTile: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: "text.bubble.fill")
                .font(.body)
                .foregroundStyle(Color.surfaceSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.cozy)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message: \(text)")
        .accessibilityIdentifier("stop.message")
    }
}

/// One car in a stop's list: its badge, its name, and how it stands ("OK" or "Waiting").
struct StopVoterRow: View {
    var row: StopRequestState.Row
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let status = Self.status(row)
        HStack(spacing: Spacing.m) {
            CarBadge(number: row.number, colorHex: row.colorHex, size: 30)
            Text(row.isMine ? "Me" : row.name).font(.body).lineLimit(1)
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
    /// OK (green) and Waiting (gray) read clearly and apart.
    private func chipText(_ color: Color) -> Color {
        guard GlassSurface.active, scheme == .dark, #available(iOS 18, *) else { return color }
        return color.mix(with: .white, by: 0.35)
    }

    static func status(_ row: StopRequestState.Row) -> (text: String, color: Color) {
        switch row.status {
        case .ok: ("OK", Color.ikutPositive)
        case .waiting: ("Waiting", Color.surfaceSecondary)
        }
    }
}

#Preview("Buttons and tiles") {
    VStack(spacing: Spacing.s) {
        StopActionButton(title: "Inform the convoy", style: .primary, id: "p") {}
        StopActionButton(title: "Inform the convoy", style: .primary, height: 72, id: "p-big") {}
        StopActionButton(title: "Inform the convoy", style: .primary, disabled: true, id: "p-off") {}
        StopActionButton(title: "Cancel request", id: "s") {}
        StopActionButton(title: "You said OK", style: .positive, id: "y") {}
        StopActionButton(title: "Back", style: .ghost, height: 44, id: "g") {}
        HStack(spacing: Spacing.m) {
            StopReasonIcon(symbol: "fuelpump.fill")
            StopReasonIcon(symbol: "fork.knife", size: 40)
            StopReasonIcon(symbol: "toilet.fill", size: 34)
        }
        StopMessageTile(text: "Low on fuel, next R&R please")
    }
    .padding(Spacing.l)
}

#Preview("Voter rows") {
    func row(_ id: String, _ n: Int, _ color: String, _ name: String, mine: Bool = false,
             _ status: StopRequestState.VoteStatus) -> StopRequestState.Row {
        .init(carId: id, number: n, colorHex: color, name: name, isMine: mine, status: status)
    }
    let rows = [
        row("c1", 1, "#2563EB", "Aqlan’s Myvi (you)", mine: true, .ok),
        row("c2", 2, "#D9480F", "Wyna’s X70", .waiting),
        row("c3", 3, "#0F766E", "Hafiz’s Hilux", .ok),
    ]
    return VStack(spacing: Spacing.xs) {
        ForEach(rows) { StopVoterRow(row: $0) }
    }
    .padding(Spacing.l)
}

#Preview("Frame") {
    VStack(spacing: Spacing.m) {
        StopCardFrame(title: "Informed the convoy", subtitle: "Waiting for the other cars", onClose: {}) {
            Text("The cars tap OK when they see it.").foregroundStyle(Color.surfaceSecondary)
        } actions: {}
        // Taller than the cap: the body scrolls and the actions stay put.
        StopCardFrame(title: "Wyna needs fuel", subtitle: nil, onClose: {}) {
            ForEach(1...8, id: \.self) { StopMessageTile(text: "Line \($0)") }
        } actions: {
            StopActionButton(title: "Back", style: .ghost, height: 44, id: "back") {}
        }
    }
    .padding(Spacing.s)
    .frame(maxHeight: .infinity, alignment: .bottom)
    .background(Color(.systemGray4))
}
