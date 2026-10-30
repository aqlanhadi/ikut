import SwiftUI
import UIKit

/// Shared look from the design canvas: grouped background, 24 pt inset cards,
/// 50 pt pill buttons and the #0071E3 accent. All colors adapt to dark mode.
extension Color {
    // ikutAccent, ikutPositive ("Tracking" and other positive status text), ikutWarning ("Waiting" status text) are
    // Color Sets in Assets.xcassets/Colors (D87).
    static let ikutScreen = Color(.systemGroupedBackground)
    static let ikutCard = Color(.secondarySystemGroupedBackground)
}

/// The spacing scale. Margins, padding and stack gaps use these instead of literals.
/// `l` is the screen margin and the card's side padding; `s`/`m` are the usual gaps between rows and between
/// tiles in a grid; `xl` is the gap above a closing action group or a long section.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    /// The side margin of a full-screen introduction (Welcome, the Always-location explainer) and the gap above a
    /// screen's first content: a deliberate big gap.
    static let hero: CGFloat = 32
}

/// Continuous corner radii from the design canvas.
enum Radius {
    /// Small icon square (a role icon, a stop's flag, an icon in a list row).
    static let icon: CGFloat = 8
    /// The stats strip inside the lobby card, code boxes, warning banners, a selectable car tile.
    static let inner: CGFloat = 16
    /// Inset grouped cards, tiles inside sheets, the dark banner and the Recap map header card.
    static let card: CGFloat = 24
}

extension View {
    /// Fills the view with `fill` in a continuous rounded rectangle.
    func ikutSurface(_ fill: some ShapeStyle, radius: CGFloat) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// White (secondary grouped) inset card with 24 pt continuous corners.
    func ikutCard(radius: CGFloat = Radius.card) -> some View {
        ikutSurface(Color.ikutCard, radius: radius)
    }

    /// Gray tile for use on a sheet's own background (report options, stop reasons, the pinned place).
    func ikutTile(radius: CGFloat = Radius.card) -> some View {
        ikutSurface(Color(.secondarySystemBackground), radius: radius)
    }

    /// Bottom action area: 16 pt side margins, 8 pt above and below, on the screen color.
    /// Put on the pill inside a bottom `safeAreaInset`.
    func ikutBottomBar() -> some View {
        padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
            .background(Color.ikutScreen)
    }
}

/// Small uppercase caption above a card, or above a group of tiles (`inset: Spacing.xs`).
/// `content` sits after the title, e.g. the lobby's progress bar and "3 of 4 ready".
struct CardHeader<Content: View>: View {
    var title: String
    var inset: CGFloat
    var top: CGFloat
    var bottom: CGFloat
    var content: Content

    init(
        _ title: String, inset: CGFloat = Spacing.l, top: CGFloat = Spacing.l, bottom: CGFloat = Spacing.s,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.inset = inset
        self.top = top
        self.bottom = bottom
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Text(title).textCase(.uppercase).accessibilityAddTraits(.isHeader)
            content
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
        .padding(.top, top)
        .padding(.bottom, bottom)
    }
}

extension CardHeader where Content == EmptyView {
    init(_ title: String, inset: CGFloat = Spacing.l, top: CGFloat = Spacing.l, bottom: CGFloat = Spacing.s) {
        self.init(title, inset: inset, top: top, bottom: bottom) { EmptyView() }
    }
}

/// Hairline between rows inside a card.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, Spacing.l)
    }
}

/// The round "x" at the top trailing corner of a sheet, in the system's size: Liquid Glass on a glass surface
/// (`buttonSurface`, as `ikutButton` follows it), else the bordered circle.
struct SheetCloseButton: View {
    var action: () -> Void
    @Environment(\.buttonSurface) private var surface

    var body: some View {
        RoundGlassIconButton(systemImage: Symbol.close, label: "Close", style: surface == .glass ? .glass : .quiet, action: action)
    }
}

/// The round "x" on a screen's top corner, over a map or a scrolling page: the system's bordered circle on a material.
struct MapCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: Symbol.close) }
            .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large).tint(.primary)
            .background(.regularMaterial, in: Circle())
            .accessibilityLabel("Close")
    }
}

/// Sheet title with its one-line explanation and the close button.
struct SheetHeader: View {
    var title: String
    var subtitle: String?
    var subtitleFont: Font = .footnote
    /// Moves the close button, for a card whose corners are rounder than a sheet's.
    var closeOffset: CGSize = .zero
    var closeIdentifier: String?
    var closeOnGlass = false
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.title2.bold())
                if let subtitle { Text(subtitle).font(subtitleFont)
                    .foregroundStyle(closeOnGlass ? Color.surfaceSecondary : Color.secondary) }
            }
            // Without a subtitle the title sits level with the middle of the 44 pt close button.
            .frame(minHeight: subtitle == nil ? 44 : nil, alignment: .leading)
            Spacer(minLength: 0)
            SheetCloseButton(action: onClose)
                .offset(closeOffset)
                .accessibilityIdentifier(closeIdentifier ?? AXID.Sheet.close)
        }
    }
}

/// One footnote line under a card or field: a hint (secondary) or a message that needs attention (red).
/// Inset to line up with the text inside cards.
struct InlineNote: View {
    enum Tone { case hint, alert }
    var text: String
    var systemImage: String?
    var tone: Tone
    var inset: CGFloat

    init(_ text: String, systemImage: String? = nil, tone: Tone = .hint, inset: CGFloat = Spacing.l) {
        self.text = text
        self.systemImage = systemImage
        self.tone = tone
        self.inset = inset
    }

    var body: some View {
        Group {
            if let systemImage { Label(text, systemImage: systemImage) } else { Text(text) }
        }
        .font(.footnote)
        .foregroundStyle(tone == .alert ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, inset)
    }
}

/// Centered one-line message in place of a card's rows: "No cars yet".
struct EmptyRow: View {
    var text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 58)
    }
}

/// Colored rounded square with a white symbol: the stop flag, the role icon.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: IconSize
    var radius: CGFloat = Radius.icon
    var font: Font = .footnote.weight(.semibold)

    var body: some View {
        Image(systemName: symbol)
            .font(font)
            .foregroundStyle(.white)
            .iconFrame(size)
            .background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
}

#Preview("Colors") {
    let swatches: [(String, Color)] = [
        ("ikutAccent", .ikutAccent), ("ikutPositive", .ikutPositive), ("ikutWarning", .ikutWarning),
        ("ikutScreen", .ikutScreen), ("ikutCard", .ikutCard),
    ]
    VStack(spacing: Spacing.s) {
        ForEach(swatches, id: \.0) { name, color in
            HStack(spacing: Spacing.m) {
                RoundedRectangle(cornerRadius: Radius.icon, style: .continuous)
                    .fill(color)
                    .overlay(RoundedRectangle(cornerRadius: Radius.icon, style: .continuous).strokeBorder(.quaternary))
                    .frame(width: 44, height: 44)
                Text(name).font(.body.monospaced())
                Spacer()
            }
        }
    }
    .padding(Spacing.l)
}

#Preview("Buttons") {
    VStack(spacing: Spacing.m) {
        Button { } label: { Text("Start trip").frame(maxWidth: .infinity) }.ikutButton(.primary)
        Button { } label: { Text("Start trip").frame(maxWidth: .infinity) }.ikutButton(.primary).disabled(true)
        HStack(spacing: Spacing.s) {
            Button { } label: { Text("Share").frame(maxWidth: .infinity) }.ikutButton(.primary)
            Button { } label: { Text("Done").frame(maxWidth: .infinity) }.ikutButton(.secondary)
        }
        Button { } label: { Text("Join a trip").frame(maxWidth: .infinity) }.ikutButton(.link)
        HStack(spacing: Spacing.s) {
            Button { } label: { Text("Not now").frame(maxWidth: .infinity) }.ikutButton(.secondary)
            Button { } label: { Text("Add").frame(maxWidth: .infinity) }.ikutButton(.primary)
        }
        .buttonSurface(.glass)
    }
    .padding(Spacing.l)
    .frame(maxHeight: .infinity)
    .background(Color.ikutScreen)
}

#Preview("Cards and notes") {
    @MainActor func row(_ text: String) -> some View {
        Text(text).ikutRow(fillWidth: true, alignment: .leading).padding(.horizontal, Spacing.l)
    }
    return ScrollView {
        VStack(spacing: 0) {
            CardHeader("Cars")
            VStack(spacing: 0) {
                row("Aqlan’s Myvi")
                RowDivider()
                row("Wyna’s X70")
            }
            .ikutCard()
            InlineNote("Everyone in the trip sees this name.").padding(.top, Spacing.s)
            CardHeader("Ready") {
                ProgressView(value: 0.75).frame(width: 60)
                Text("3 of 4 ready")
            }
            EmptyRow("No cars yet").ikutCard()
            InlineNote("Couldn't reach the server.", systemImage: Symbol.warning, tone: .alert)
                .padding(.top, Spacing.s)
            CardHeader("Tiles", inset: Spacing.xs)
            Text("A tile on a sheet").frame(maxWidth: .infinity, minHeight: 80).ikutTile()
        }
        .padding(.horizontal, Spacing.l)
    }
    .background(Color.ikutScreen)
}

#Preview("Sheet header and close buttons") {
    VStack(spacing: Spacing.xl) {
        SheetHeader(title: "Report", subtitle: "The cars behind you get an alert.") {}
        HStack(spacing: Spacing.xl) {
            SheetCloseButton {}
            MapCloseButton {}
                .padding(Spacing.l)
                .background(LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom))
        }
    }
    .padding(Spacing.l)
}

#Preview("Icon tiles") {
    HStack(spacing: Spacing.s) {
        IconTile(symbol: Symbol.pin, color: .red, size: .small, font: .footnote.weight(.bold))
        IconTile(symbol: Symbol.steering, color: .ikutAccent, size: .small)
        IconTile(symbol: Symbol.fuel, color: .orange, size: .regular, radius: Radius.icon)
    }
    .padding(Spacing.l)
}
