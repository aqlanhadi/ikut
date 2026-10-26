import SwiftUI

/// The pieces every Apple-sheet-on-the-map screen shares (the driving screen's convoy sheet, the lobby's sheet,
/// New trip): the action bar on glass, the glass button faces inside it, and the round glass icon button.

extension View {
    /// The bottom bar of a sheet that is the glass surface itself: no background of its own, `Spacing.l` beside
    /// the buttons, and the buttons hanging `lift` down into the sheet's bottom safe area (`PanelSheet.barLift`) so
    /// the gap under them equals the gap beside them. The bar's layout height stops above the safe area, so
    /// detents stay content + bar. Put it on the bar's content inside a bottom `safeAreaInset`.
    func sheetActionBar(lift: CGFloat = 0) -> some View {
        padding(.horizontal, PanelSheet.sideGap)
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

    /// Liquid Glass buttons on iOS 26 (the owner chose glass on the sheet, 2026-10-25): the main action prominent
    /// and tinted with the accent, the quieter one clear (`GlassSurface.useGlass` is the switch). Before iOS 26,
    /// the tinted and bordered capsules as before.
    @ViewBuilder func actionBarStyle(prominent: Bool) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).tint(.primary)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
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
            background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            ikutSurface(Color.ikutScreen, radius: radius)
        }
    }
}

/// A round button for the top corners of a sheet (44 pt to tap by default): Liquid Glass on iOS 26, else a quiet
/// filled circle. Its face is an SF Symbol (the close "x", Back, Share) or a short text (the name's initial).
struct RoundGlassIconButton: View {
    private enum Face { case symbol(String), text(String) }
    private var face: Face
    var label: String
    var size: CGFloat = 44
    var action: () -> Void

    init(systemImage: String, label: String, size: CGFloat = 44, action: @escaping () -> Void) {
        face = .symbol(systemImage)
        self.label = label
        self.size = size
        self.action = action
    }

    /// A text face, such as the person's initial: .primary and semibold.
    init(text: String, label: String, size: CGFloat = 44, action: @escaping () -> Void) {
        face = .text(text)
        self.label = label
        self.size = size
        self.action = action
    }

    @ViewBuilder private var faceView: some View {
        switch face {
        case .symbol(let name): Image(systemName: name).font(.footnote.weight(.bold))
        case .text(let text): Text(text).font(.body.weight(.semibold))
        }
    }

    var body: some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            Button(action: action) {
                faceView.frame(width: size, height: size)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .accessibilityLabel(label)
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

/// The top row of a sheet over the map: [leading round button] [title over subtitle] [trailing round button], with the
/// title block centred between them as Apple's inline sheet titles are. Each side reserves a button's width (44 pt)
/// even with no button, so the block stays truly centred, and it keeps `Spacing.m` from each button. The title is one line
/// (semibold title3; two at accessibility sizes), the subtitle up to two (footnote), truncating in the middle. Give it
/// the sheet's side insets (`Spacing.l`) where it is used.
struct SheetTopRow<Leading: View, Trailing: View>: View {
    var title: String
    var subtitle: String?
    /// What VoiceOver reads for the title when it should say more than the title.
    var titleLabel: String?
    var subtitleIdentifier: String?
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let lines = typeSize.isAccessibilitySize ? 2 : 1
        HStack(spacing: 0) {
            leading.frame(width: 44, height: 44)
            VStack(spacing: Spacing.xxs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(lines)
                    .truncationMode(.middle)
                    .accessibilityLabel(titleLabel ?? title)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
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
            trailing.frame(width: 44, height: 44)
        }
        .frame(minHeight: 48)
    }
}

/// The same round button for the system share sheet (a `ShareLink`, which isn't a `Button` to wrap).
struct RoundGlassShareLink: View {
    var item: String
    var label = "Share invite"

    var body: some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            ShareLink(item: item) { face.frame(width: 44, height: 44) }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(.primary)
                .accessibilityLabel(label)
        } else {
            ShareLink(item: item) {
                face.foregroundStyle(.secondary).frame(width: 44, height: 44).background(.quaternary, in: Circle())
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
enum SheetSearch {
    static let height: CGFloat = 48
    /// A capsule at the bar's height.
    static let radius: CGFloat = height / 2
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
        .surfaceTile(radius: SheetSearch.radius)
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
            .surfaceTile(radius: SheetSearch.radius)
        }
        .buttonStyle(.plain)
    }
}
