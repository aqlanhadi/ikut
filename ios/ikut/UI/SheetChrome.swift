import SwiftUI

/// The pieces every Apple-sheet-on-the-map screen shares (the driving screen's convoy sheet, the lobby's sheet,
/// New trip): the action bar on glass, the glass button faces inside it, and the round glass icon button.

extension View {
    /// The bottom bar of a sheet that is the glass surface itself: no background of its own, `Spacing.l` beside
    /// the buttons, and the buttons hanging `lift` down into the sheet's bottom safe area (`PanelSheet.barLift`) so
    /// the gap under them equals the gap beside them. The bar's layout height stops above the safe area, so
    /// detents stay content + bar. Put it on the bar's content inside a bottom `safeAreaInset`.
    /// `sides` false: the sheet already insets its content by `PanelSheet.sideGap` (Home's sheet, New trip).
    func sheetActionBar(lift: CGFloat = 0, sides: Bool = true) -> some View {
        padding(.horizontal, sides ? PanelSheet.sideGap : 0)
            .padding(.top, Spacing.m)
            .padding(.bottom, -lift)
    }

    /// The sheet's bottom bar as a container: on iOS 26 a `safeAreaBar`, so the scrolling content under it fades out
    /// with the system's soft bottom edge instead of reading through the bar; before that a plain bottom inset.
    /// The bar's content takes `sheetActionBar(lift:)` as before.
    @ViewBuilder func sheetBottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0) { bar() }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) { bar() }
        }
    }

    /// The sheet's top bar: a header that stays put over scrolling content (the lobby's, Add a stop's). On iOS 26 a
    /// `safeAreaBar`, so the rows scrolling up under it fade out with the system's soft top edge, as they do above
    /// the bottom bar; before that the header simply sits above the content, as it always has.
    @ViewBuilder func sheetTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0) { bar() }
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            VStack(spacing: 0) {
                bar()
                self
            }
        }
    }

    /// The label of a full-width bottom-bar action (Start trip, Show map, Create trip, Add <place>, Report, Pit stop,
    /// a card's main button): headline, as wide as the bar, `SheetButtonSize.bar` tall, growing with the text size.
    /// Only for what is not a button (the waiting line); buttons go through `ikutButton`.
    /// `font`: the lobby's waiting line keeps its quieter text in the same shape.
    func barActionLabel(fullWidth: Bool = true, font: Font = .headline) -> some View {
        modifier(BarActionLabel(fullWidth: fullWidth, font: font))
    }

    /// A round icon face inside the content (the steppers' minus and plus): `SheetButtonSize.hit` across.
    func inlineRoundLabel() -> some View { modifier(InlineRoundLabel()) }
}

extension View {
    /// A tile inside a tile (the lobby's route total inside its card): a faint darkening on glass, the screen colour
    /// elsewhere.
    @ViewBuilder func innerTile(radius: CGFloat = Radius.inner) -> some View {
        if GlassSurface.active {
            background(Color.primary.fill(.wash), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            ikutSurface(Color.ikutScreen, radius: radius)
        }
    }
}

/// The three button sizes of the sheets (owner, D53), each read through `@ScaledMetric` so it grows with the text
/// size. Bar: the full-width bottom-bar actions, the height most of them already had. Inline: buttons inside the
/// content. Round: the round icon buttons, which is also the search bar's height, so Home's avatar matches it.
enum SheetButtonSize {
    static let bar: CGFloat = 50
    static let round: CGFloat = 48
    /// The least a tap target is, whatever the text size; also the round close button's base.
    static let hit: CGFloat = 44
    /// The small square or round icon tile inside a row (Home's "Join with a code").
    static let tile: CGFloat = 30
    /// How far a scaled button may grow, as a multiple of its base size, so it never outgrows a sheet header.
    static let maxScale: CGFloat = 1.6

    /// A scaled side kept between the 44 pt hit target and `maxScale` times the base.
    static func capped(_ scaled: CGFloat, base: CGFloat) -> CGFloat {
        min(max(scaled, hit), max(base * maxScale, hit))
    }
}

private struct BarActionLabel: ViewModifier {
    var fullWidth: Bool
    var font: Font
    @ScaledMetric(relativeTo: .headline) private var height = SheetButtonSize.bar

    func body(content: Content) -> some View {
        content.font(font).frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
    }
}

private struct InlineRoundLabel: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.hit

    func body(content: Content) -> some View { content.frame(width: side, height: side) }
}

/// The system's glass circle on iOS 26 (the bordered circle before), at the large control size; nothing sets a frame.
extension View {
    @ViewBuilder func roundGlassStyle() -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large).tint(.primary)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.large).tint(.primary)
        }
    }
}

/// A round icon button (the close "x", Back, Share, the name's initial). Glass is the system's circle at its own size
/// (46 pt and up); the quiet and bare ones draw their own circle (or none) in `RoundIconFace`, at least 44 pt and
/// growing with the text size, since Apple's bordered circle measured 41 pt.
struct RoundGlassIconButton: View {
    /// `.glass`: Liquid Glass (the bordered circle before iOS 26). `.quiet`: a tertiary-filled circle. `.bare`: the glyph.
    enum Style { case glass, quiet, bare }
    private enum Face { case symbol(String), text(String) }
    private var face: Face
    var label: String
    /// Only with `exact`: the final side.
    var size: CGFloat?
    var style = Style.glass
    /// The glyph's font, nil for the system's own.
    var glyph: Font?
    /// The one custom size: Home's name button must line up with the search bar, which grows with the text size and is
    /// measured by the caller, so `size` is its final side (glass only).
    var exact = false
    var action: () -> Void
    /// What Apple's large circle style adds around its label, measured (46 pt for a 17 pt "xmark").
    private static let systemPadding: CGFloat = 27

    init(systemImage: String, label: String, size: CGFloat? = nil, style: Style = .glass, glyph: Font? = nil, exact: Bool = false, action: @escaping () -> Void) {
        face = .symbol(systemImage)
        self.label = label
        self.size = size
        self.style = style
        self.glyph = glyph
        self.exact = exact
        self.action = action
    }

    /// A text face, such as the person's initial: semibold, shrinking to fit the circle.
    init(text: String, label: String, size: CGFloat? = nil, exact: Bool = false, action: @escaping () -> Void) {
        face = .text(text)
        self.label = label
        self.size = size
        self.exact = exact
        self.action = action
    }

    @ViewBuilder private var faceView: some View {
        switch face {
        case .symbol(let name): Image(systemName: name).font(glyph)
        case .text(let text): Text(text).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    var body: some View {
        if style != .glass {
            Button(action: action) { RoundIconFace(face: faceView.font(glyph ?? .body.weight(.semibold)), style: style) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        } else if exact, let size {
            Button(action: action) { faceView.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .roundGlassStyle()
                .frame(width: size, height: size)
                .accessibilityLabel(label)
        } else {
            // A narrow glyph (the chevron) leaves the system's circle at 42.7 pt wide: the label's minimum makes up the
            // rest of the 44 pt tap (the system pads the label by about 29 pt in all).
            let least = SheetButtonSize.hit - Self.systemPadding
            Button(action: action) { faceView.frame(minWidth: least, minHeight: least) }
                .roundGlassStyle()
                .accessibilityLabel(label)
        }
    }
}

/// The face of a quiet or bare round button, also a label that isn't a `Button` (a `ShareLink`, a banner's close):
/// `SheetButtonSize.hit` across, growing with the text size up to `SheetButtonSize.maxScale` times, never under 44.
struct RoundIconFace<Face: View>: View {
    var face: Face
    var style: RoundGlassIconButton.Style = .quiet
    /// Nil: the style's own colour. White for a close button on a dark banner.
    var color: Color?
    @ScaledMetric(relativeTo: .body) private var scaled = SheetButtonSize.hit

    var body: some View {
        let side = SheetButtonSize.capped(scaled, base: SheetButtonSize.hit)
        face
            .foregroundStyle(color ?? (style == .bare ? .secondary : .primary))
            .frame(width: side, height: side)
            .background(style == .quiet ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }
}

/// A symbol for `RoundIconFace`, for a label that isn't a `Button`.
struct RoundIconSymbol: View {
    var systemImage: String
    var glyph: Font?
    var style: RoundGlassIconButton.Style = .quiet
    var color: Color?

    var body: some View {
        RoundIconFace(face: Image(systemName: systemImage).font(glyph ?? .body.weight(.semibold)), style: style, color: color)
    }
}

/// The top row of a sheet over the map: [leading round button] [title over subtitle] [trailing round button], with the
/// title block centred between them as Apple's inline sheet titles are. Each side reserves a round button's width (`SheetButtonSize.round`)
/// even with no button, so the block stays truly centred, and it keeps `Spacing.m` from each button. The title is one line
/// (semibold title3; two at accessibility sizes), the subtitle up to two (footnote), truncating in the middle. Give it
/// the sheet's side insets (`Spacing.l`) where it is used.
struct SheetTopRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    /// What VoiceOver reads for the title when it should say more than the title.
    var titleLabel: String?
    var subtitleIdentifier: String?
    /// A subtitle with parts in colour (the lobby's "Sharing", #394), drawn instead of `subtitle`'s plain words.
    var styledSubtitle: Text?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.round
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let lines = typeSize.isAccessibilitySize ? 2 : 1
        HStack(spacing: 0) {
            leading.frame(width: side, height: side)
            VStack(spacing: Spacing.xxs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(lines)
                    .truncationMode(.middle)
                    .accessibilityLabel(titleLabel ?? title)
                    .accessibilityAddTraits(.isHeader)
                if let line = styledSubtitle ?? subtitle.map({ Text($0) }) {
                    line
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
                        .wrapsAtAccessibilitySizes(lines: 2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier(subtitleIdentifier ?? "")
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.m)
            trailing.frame(width: side, height: side)
        }
        .ikutRow()
    }
}

/// The same round button for the system share sheet (a `ShareLink`, which isn't a `Button` to wrap).
struct RoundGlassShareLink: View {
    var item: String
    var label = "Share invite"

    var body: some View {
        ShareLink(item: item) { Image(systemName: Symbol.share) }
            .roundGlassStyle()
            .accessibilityLabel(label)
    }
}

/// The search bar of an Apple-Maps-style sheet (Home's Where to?, then the live search): a full-width capsule at
/// least 48 pt tall on a light translucent fill with a hairline edge, a magnifier in .primary, then the text at the
/// body size. Two forms with the same face: `SheetSearchButton` (a placeholder you tap) and `SheetSearchField`
/// (a TextField you put inside it, with a clear button once there is text).
extension View {
    /// Reports this view's height into `height`, as it lays out (the search bar grows with the text size, and the
    /// round button and Cancel beside it follow).
    func trackingHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
            if new > 0, abs(new - height.wrappedValue) > 0.1 { height.wrappedValue = new }
        }
    }
}

enum SheetSearch {
    /// The round buttons' size, so Home's avatar beside the bar is the same number.
    static let height: CGFloat = SheetButtonSize.round
    /// A capsule at the bar's height.
    static let radius: CGFloat = height / 2
}

extension View {
    /// The search bar's face: raised Liquid Glass on iOS 26 (the same glass as the round buttons beside it; the glass
    /// draws its own edge), the flat tile fill before that. Not interactive for the field form's sake: it must not
    /// take the taps meant for the text field.
    @ViewBuilder fileprivate func searchBarSurface(interactive: Bool = false) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            surfaceTile(radius: SheetSearch.radius)
        }
    }
}

/// The TextField form. `clear` is the action of the clear button, shown when it isn't nil (pass it while there is text).
struct SheetSearchField<Field: View>: View {
    var clear: (() -> Void)?
    @ViewBuilder var field: Field

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: Symbol.search).foregroundStyle(.primary).accessibilityHidden(true)
            field.font(.body)
            if let clear {
                ClearFieldButton(action: clear)
            }
        }
        .padding(.leading, Spacing.m)
        .padding(.trailing, clear == nil ? Spacing.m : 0)
        .frame(minHeight: SheetSearch.height)
        .searchBarSurface()
    }
}

/// The button form: the same bar with a placeholder, tapped to start the search.
struct SheetSearchButton: View {
    var placeholder: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: Symbol.search).foregroundStyle(.primary).accessibilityHidden(true)
                Text(placeholder).font(.body).foregroundStyle(Color.surfaceSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: SheetSearch.height)
            .contentShape(Capsule())
            .searchBarSurface(interactive: true)
        }
        .buttonStyle(.plain)
    }
}
