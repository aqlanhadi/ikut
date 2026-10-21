import SwiftUI
import UIKit

/// Shared look from the design canvas: grouped background, 24 pt inset cards,
/// 50 pt pill buttons and the #0071E3 accent. All colors adapt to dark mode.
extension Color {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    static let ikutAccent = dynamic(light: 0x0071E3, dark: 0x2997FF)
    /// "Tracking" and other positive status text (darker than system green for contrast on white).
    static let ikutPositive = dynamic(light: 0x1F7A35, dark: 0x30D158)
    /// "Waiting" status text.
    static let ikutWarning = dynamic(light: 0xC93400, dark: 0xFF9F0A)
    static let ikutScreen = Color(.systemGroupedBackground)
    static let ikutCard = Color(.secondarySystemGroupedBackground)
}

/// The spacing scale. Margins, padding and stack gaps use these instead of literals.
/// `l` is the screen margin and the card's side padding; `s`/`m` are the usual gaps between rows;
/// `gap` is the design canvas's 10 pt between tiles in a grid and between an icon and its text.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    /// Between a capsule's label and its edge, top and bottom.
    static let tight: CGFloat = 6
    static let s: CGFloat = 8
    /// Side padding of a small capsule (status, "Lead", car count).
    static let chipX: CGFloat = 9
    static let gap: CGFloat = 10
    static let m: CGFloat = 12
    /// Inside tickets, banners and the pinned-place card, where the canvas uses 14.
    static let cozy: CGFloat = 14
    static let l: CGFloat = 16
    static let xl: CGFloat = 24

    /// Side margin of every screen's content.
    static let screenMargin = l

    /// Space above a section header, and a floating panel's top and bottom padding (canvas: 18).
    static let section: CGFloat = 18
    /// Space above Home's "Past trips" header and the join code boxes (canvas: 22).
    static let sectionLarge: CGFloat = 22
    /// A 20 pt block gap: below a long sheet, above a closing action group.
    static let block: CGFloat = 20
}

/// Continuous corner radii from the design canvas.
enum Radius {
    /// Small icon square (a 30 pt role icon, a stop's flag).
    static let icon: CGFloat = 8
    /// Larger icon square in a list row.
    static let iconLarge: CGFloat = 10
    /// The stats strip inside the lobby card.
    static let inner: CGFloat = 16
    /// Code boxes, warning banners.
    static let control: CGFloat = 14
    /// Selectable car tile.
    static let row: CGFloat = 18
    /// Tiles inside sheets (report options, stop reasons, places) and the pinned-place card.
    static let tile: CGFloat = 22
    /// Inset grouped cards.
    static let card: CGFloat = 24
    /// Floating map panels (convoy panel, stop request card).
    static let panel: CGFloat = 38
    /// The dark banner and the Recap map header card.
    static let banner: CGFloat = 28
    /// The Welcome app icon.
    static let hero: CGFloat = 20
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
    func ikutTile(radius: CGFloat = Radius.tile) -> some View {
        ikutSurface(Color(.secondarySystemBackground), radius: radius)
    }

    /// Bottom action area: 16 pt side margins, 8 pt above and below, on the screen color.
    /// Put on the pill inside a bottom `safeAreaInset`.
    func ikutBottomBar() -> some View {
        padding(.horizontal, Spacing.screenMargin)
            .padding(.vertical, Spacing.s)
            .background(Color.ikutScreen)
    }
}

/// Full-width accent capsule, 50 pt high.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.ikutAccent.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Card-colored capsule with accent text, 50 pt high: the second of two side-by-side pills.
struct SecondaryPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.ikutCard, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Borderless accent text button, 50 pt high, for the secondary action under a pill.
struct LinkPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
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
        _ title: String, inset: CGFloat = Spacing.l, top: CGFloat = Spacing.section, bottom: CGFloat = Spacing.tight,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.inset = inset
        self.top = top
        self.bottom = bottom
        self.content = content()
    }

    var body: some View {
        HStack(spacing: Spacing.gap) {
            Text(title.uppercased()).accessibilityAddTraits(.isHeader)
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
    init(_ title: String, inset: CGFloat = Spacing.l, top: CGFloat = Spacing.section, bottom: CGFloat = Spacing.tight) {
        self.init(title, inset: inset, top: top, bottom: bottom) { EmptyView() }
    }
}

/// Hairline between rows inside a card.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, Spacing.l)
    }
}

/// The round "x" at the top trailing corner of a sheet, 44 pt to tap.
struct SheetCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(.quaternary, in: Circle())
        }
        .accessibilityLabel("Close")
    }
}

/// The round "x" on a screen's top corner, on a material so it reads over a map or a scrolling page.
struct MapCloseButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 15, weight: .bold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }
        .tint(.primary)
        .accessibilityLabel("Close")
    }
}

/// Sheet title with its one-line explanation and the close button.
struct SheetHeader: View {
    var title: String
    var subtitle: String
    var subtitleFont: Font = .footnote
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.title2.bold())
                Text(subtitle).font(subtitleFont).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            SheetCloseButton(action: onClose)
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

/// Colored rounded square with a white symbol: the stop flag, the role icon, a suggested place.
struct IconTile: View {
    var symbol: String
    var color: Color
    var size: CGFloat
    var radius: CGFloat = Radius.icon
    var font: Font = .footnote.weight(.semibold)

    var body: some View {
        Image(systemName: symbol)
            .font(font)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
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
        Button("Start Trip") {}.buttonStyle(PillButtonStyle())
        Button("Start Trip") {}.buttonStyle(PillButtonStyle()).disabled(true)
        HStack(spacing: Spacing.gap) {
            Button("Share") {}.buttonStyle(PillButtonStyle())
            Button("Done") {}.buttonStyle(SecondaryPillButtonStyle())
        }
        Button("Join a trip") {}.buttonStyle(LinkPillButtonStyle())
    }
    .padding(Spacing.l)
    .frame(maxHeight: .infinity)
    .background(Color.ikutScreen)
}

#Preview("Cards and notes") {
    func row(_ text: String) -> some View {
        Text(text).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).padding(.horizontal, Spacing.l)
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
            InlineNote("Couldn't reach the server.", systemImage: "exclamationmark.triangle.fill", tone: .alert)
                .padding(.top, Spacing.s)
            CardHeader("Tiles", inset: Spacing.xs)
            Text("A tile on a sheet").frame(maxWidth: .infinity, minHeight: 80).ikutTile()
        }
        .padding(.horizontal, Spacing.screenMargin)
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
    HStack(spacing: Spacing.gap) {
        IconTile(symbol: "mappin", color: .red, size: 30, font: .footnote.weight(.bold))
        IconTile(symbol: "steeringwheel", color: .ikutAccent, size: 30)
        IconTile(symbol: "fuelpump.fill", color: .orange, size: 34, radius: Radius.iconLarge)
    }
    .padding(Spacing.l)
}
