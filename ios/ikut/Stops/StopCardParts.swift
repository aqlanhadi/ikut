import SwiftUI

/// One button in the card's action area, every style Apple's large size, growing with the text size
/// (or `height` when the driver needs a huge one). `.primary` is the main action, `.secondary` a gray capsule,
/// `.positive` the chosen answer, `.ghost` plain text, `.destructive` red text (a destructive button role).
struct StopActionButton: View {
    enum Style { case primary, secondary, positive, ghost, destructive }

    var title: LocalizedStringKey
    /// A small second line under the title ("Hafiz is 3 min away").
    var subtitle: LocalizedStringKey?
    var style: Style = .secondary
    /// Nil: the size `ikutButton` gives (the driving screen's big mode passes the button's total height).
    var height: CGFloat?
    var disabled = false
    var id: String
    var action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    /// What Apple's large capsule adds around its label (measured: a 50.3 pt button on a 22 pt headline), taken off a
    /// requested total so `height` is the button's whole height, not the label's minimum with the padding on top.
    static let largeExtra: CGFloat = 28

    var body: some View {
        // At accessibility sizes a long title wraps to two lines and the button grows, not truncates.
        let large = typeSize.isAccessibilitySize
        Button(role: style == .destructive ? .destructive : nil, action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(.headline)
                    .lineLimit(large ? 2 : 1)
                    .minimumScaleFactor(large ? 1 : 0.8)
                if let subtitle {
                    Text(subtitle).font(.caption).dimmed(.strong).lineLimit(large ? 2 : 1)
                }
            }
                .multilineTextAlignment(.center)
                .padding(.horizontal, large ? Spacing.l : 0)
                .frame(maxWidth: .infinity, minHeight: height.map { max($0 - Self.largeExtra, 0) })
        }
        .ikutButton(role, surface: face)
        .disabled(disabled)
        .accessibilityIdentifier(id)
    }

    /// Primary and secondary are Liquid Glass buttons on iOS 26; the rest stay flat.
    private var role: IkutButtonRole {
        switch style {
        case .primary: .primary
        case .secondary: .secondary
        case .positive, .ghost, .destructive: .flat(face)
        }
    }

    private var face: IkutButtonFace { IkutButtonFace(fill: background, foreground: foreground) }

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
        case .secondary: Color(.systemGray5).dimmed(.faded)
        case .positive: Color.green.fill(.tint)
        case .ghost, .destructive: .clear
        }
    }
}

/// The reason's icon in an orange circle, as on the tiles.
struct StopReasonIcon: View {
    var symbol: String
    var size: CGFloat = 46
    @ScaledMetric(relativeTo: .headline) private var textScale: CGFloat = 1

    var body: some View {
        let drawn = size * MarkerMetrics.scale(textScale)
        Image(systemName: symbol)
            .font(.system(size: drawn * 0.43, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: drawn, height: drawn)
            .background(Color.orange, in: Circle())
            .accessibilityHidden(true)
    }
}

/// What a passenger typed, in full, on the card.
struct StopMessageTile: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: Symbol.message)
                .font(.body)
                .foregroundStyle(Color.surfaceSecondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surfaceTile()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Message: \(text)")
        .accessibilityIdentifier(AXID.Stop.message)
    }
}

/// One car in a stop's list: its badge, its name, and how it stands ("OK" or "Waiting").
struct StopVoterRow: View {
    var row: StopRequestState.Row
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let status = Self.status(row)
        HStack(spacing: Spacing.m) {
            CarBadge(number: row.number, colorHex: row.colorHex, size: IconSize.small.base)
            Text(row.isMine ? "Me" : row.name).font(.body).wrapsAtAccessibilitySizes()
            Spacer(minLength: 4)
            Text(status.text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(chipText(status.color))
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, Spacing.xs)
                .background(status.color.opacity(GlassSurface.active ? 0.2 : 0.14), in: Capsule())
                .background(GlassSurface.active && scheme == .dark ? Color.black.opacity(0.4) : .clear, in: Capsule())
        }
        .ikutRow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StopLogic.voterAccessibilityLabel(row))
        .accessibilityIdentifier(AXID.Stop.voter(row.number.map(String.init) ?? row.carId))
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
        StopActionButton(title: "Tell the convoy", style: .primary, id: "p") {}
        StopActionButton(title: "Tell the convoy", style: .primary, height: 72, id: "p-big") {}
        StopActionButton(title: "Tell the convoy", style: .primary, disabled: true, id: "p-off") {}
        StopActionButton(title: "Cancel request", id: "s") {}
        StopActionButton(title: "You said OK", style: .positive, id: "y") {}
        StopActionButton(title: "Back", style: .ghost, id: "g") {}
        HStack(spacing: Spacing.m) {
            StopReasonIcon(symbol: Symbol.fuel)
            StopReasonIcon(symbol: Symbol.food, size: 40)
            StopReasonIcon(symbol: Symbol.toilet, size: 34)
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
        CardSheetFrame(title: "Sent to the convoy", subtitle: "Waiting for the other cars", onClose: {}) {
            Text("The cars tap OK when they see it.").foregroundStyle(Color.surfaceSecondary)
        } actions: {}
        // Taller than the cap: the body scrolls and the actions stay put.
        CardSheetFrame(title: "Wyna needs fuel", subtitle: nil, onClose: {}) {
            ForEach(1...8, id: \.self) { StopMessageTile(text: "Line \($0)") }
        } actions: {
            StopActionButton(title: "Back", style: .ghost, id: "back") {}
        }
    }
    .padding(Spacing.s)
    .frame(maxHeight: .infinity, alignment: .bottom)
    .background(Color(.systemGray4))
}
