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
    /// With `actionBarStyle` (or `actionButton`, `surfaceButton`) and inside `sheetActionBar`, every bar is one shape.
    /// `font`: the lobby's waiting line keeps its quieter text in the same shape.
    func barActionLabel(fullWidth: Bool = true, font: Font = .headline) -> some View {
        modifier(BarActionLabel(fullWidth: fullWidth, font: font))
    }

    /// The label of a button inside the content (Copy, QR code, the steppers, Suggest's Not now and Add):
    /// `SheetButtonSize.inline` tall, growing with the text size.
    func inlineActionLabel(fullWidth: Bool = true) -> some View { modifier(InlineActionLabel(fullWidth: fullWidth)) }

    /// A round icon face inside the content (the steppers' minus and plus): `SheetButtonSize.inline` across.
    func inlineRoundLabel() -> some View { modifier(InlineRoundLabel()) }

    /// Liquid Glass buttons on iOS 26 (the owner chose glass on the sheet, 2026-10-25): the main action prominent
    /// and tinted with the accent, the quieter one clear (`GlassSurface.useGlass` is the switch). Before iOS 26,
    /// the tinted and bordered capsules as before.
    @ViewBuilder func actionBarStyle(prominent: Bool) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Color.ikutAccentFill)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).tint(.primary)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.ikutAccentFill)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
        }
    }
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
    static let inline: CGFloat = 44
    static let round: CGFloat = 48
    /// The least a tap target is, whatever the text size.
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

private struct InlineActionLabel: ViewModifier {
    var fullWidth: Bool
    @ScaledMetric(relativeTo: .body) private var height = SheetButtonSize.inline

    func body(content: Content) -> some View {
        content.frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
    }
}

private struct InlineRoundLabel: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.inline

    func body(content: Content) -> some View { content.frame(width: side, height: side) }
}

/// A round button for the top corners of a sheet (`SheetButtonSize.round` across by default): Liquid Glass on iOS 26, else a quiet
/// filled circle. Its face is an SF Symbol (the close "x", Back, Share) or a short text (the name's initial).
struct RoundGlassIconButton: View {
    /// `.glass`: Liquid Glass (a quiet circle before iOS 26), `SheetButtonSize.round` across. `.quiet` and `.bare`
    /// never use glass: a tertiary-filled circle (a sheet's pinned header) or the bare glyph (a button inside a card),
    /// both `SheetButtonSize.inline` across, scaled and capped.
    enum Style { case glass, quiet, bare }
    private enum Face { case symbol(String), text(String) }
    private var face: Face
    var label: String
    /// Nil: `SheetButtonSize.round`, scaled.
    var size: CGFloat?
    var style = Style.glass
    /// The glyph's font, nil for the footnote bold every round button had.
    var glyph: Font?
    @ScaledMetric(relativeTo: .body) private var roundSize = SheetButtonSize.round
    @ScaledMetric(relativeTo: .body) private var inlineSize = SheetButtonSize.inline
    /// The circle is exactly `size` across (Home's name button, which must match the search bar's height as it
    /// grows with the text size), glass included, whatever padding the glass style would add around the face.
    var exact = false
    var action: () -> Void

    init(systemImage: String, label: String, size: CGFloat? = nil, style: Style = .glass, glyph: Font? = nil, exact: Bool = false, action: @escaping () -> Void) {
        face = .symbol(systemImage)
        self.label = label
        self.size = size
        self.style = style
        self.glyph = glyph
        self.exact = exact
        self.action = action
    }

    /// A text face, such as the person's initial: .primary and semibold, shrinking to fit the circle.
    init(text: String, label: String, size: CGFloat? = nil, exact: Bool = false, action: @escaping () -> Void) {
        face = .text(text)
        self.label = label
        self.size = size
        self.exact = exact
        self.action = action
    }

    @ViewBuilder private var faceView: some View {
        switch face {
        case .symbol(let name): Image(systemName: name).font(glyph ?? .footnote.weight(.bold))
        case .text(let text): Text(text).font(.body.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    var body: some View {
        if style != .glass {
            Button(action: action) { RoundIconFace(face: faceView, style: style, side: inlineSize) }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
        } else {
            glassBody
        }
    }

    @ViewBuilder private var glassBody: some View {
        let size = size ?? roundSize
        if GlassSurface.useGlass, #available(iOS 26, *) {
            if exact {
                Button(action: action) {
                    faceView.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .frame(width: size, height: size)
                .accessibilityLabel(label)
            } else {
                Button(action: action) {
                    faceView.frame(width: size, height: size)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel(label)
            }
        } else {
            Button(action: action) {
                faceView
                    .foregroundStyle(isText ? Color.primary : Color.secondary)
                    .frame(width: size, height: size)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(label)
        }
    }

    private var isText: Bool { if case .text = face { true } else { false } }
}

/// The face of a `.quiet` or `.bare` round icon button, also the label of a `ShareLink`: `SheetButtonSize.inline`
/// across, scaled with the text size and capped, never under the 44 pt hit target.
struct RoundIconFace<Face: View>: View {
    var face: Face
    var style: RoundGlassIconButton.Style = .quiet
    var side: CGFloat

    var body: some View {
        let side = SheetButtonSize.capped(side, base: SheetButtonSize.inline)
        face
            .foregroundStyle(style == .bare ? Color.secondary : Color.primary)
            .frame(width: side, height: side)
            .background(style == .quiet ? AnyShapeStyle(Color(.tertiarySystemFill)) : AnyShapeStyle(.clear), in: Circle())
            .contentShape(Circle())
    }
}

/// A symbol for `RoundIconFace`, for a label that isn't a `Button` (a `ShareLink`).
struct RoundIconSymbol: View {
    var systemImage: String
    var glyph: Font = .footnote.weight(.bold)
    var style: RoundGlassIconButton.Style = .quiet
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.inline

    var body: some View {
        RoundIconFace(face: Image(systemName: systemImage).font(glyph), style: style, side: side)
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
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityIdentifier(subtitleIdentifier ?? "")
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.m)
            trailing.frame(width: side, height: side)
        }
        .frame(minHeight: 48)
    }
}

/// The same round button for the system share sheet (a `ShareLink`, which isn't a `Button` to wrap).
struct RoundGlassShareLink: View {
    var item: String
    var label = "Share invite"
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.round

    var body: some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            ShareLink(item: item) { face.frame(width: side, height: side) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel(label)
        } else {
            ShareLink(item: item) {
                face.foregroundStyle(.secondary).frame(width: side, height: side).background(.quaternary, in: Circle())
            }
            .accessibilityLabel(label)
        }
    }

    private var face: some View { Image(systemName: "square.and.arrow.up").font(.footnote.weight(.bold)) }
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
            Image(systemName: "magnifyingglass").foregroundStyle(.primary).accessibilityHidden(true)
            field.font(.body)
            if let clear {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
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
                Image(systemName: "magnifyingglass").foregroundStyle(.primary).accessibilityHidden(true)
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
