import SwiftUI

/// The surface behind a floating sheet: the trips sheet on the home screen, the convoy panel and the
/// stop card. One place decides how they look; `GlassSurface.useGlass` is the switch.
enum GlassSurface {
    /// Liquid Glass on iOS 26 and later for the floating convoy panel and stop card. False gives them
    /// the frosted material, as before iOS 26. The home trips sheet is glass on iOS 26 either way.
    static let useGlass = true

    /// True when the glass look is showing (the switch above, on iOS 26 or later).
    static var active: Bool {
        if #available(iOS 26, *) { return useGlass }
        return false
    }

    enum Kind {
        /// Full-width sheet with bottom corners that follow the screen's (home trips sheet, glass only).
        case sheet
        /// Inset card floating over the map, with a plain Radius.panel rectangle.
        case floating
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    var kind: GlassSurface.Kind

    private var plain: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.panel, style: .continuous) }

    func body(content: Content) -> some View {
        // Clipped to the same shape: a ScrollView draws on under the safe area and past the rounded
        // corners, and a folding list draws outside a shrinking panel.
        if kind == .sheet, #available(iOS 26, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.panel)), isUniform: false)
            content.clipShape(shape).glassEffect(.regular, in: shape)
        } else if kind == .floating, GlassSurface.useGlass, #available(iOS 26, *) {
            content.clipShape(plain).glassEffect(.regular, in: plain)
        } else {
            content
                .clipShape(plain)
                .background(.regularMaterial, in: plain)
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        }
    }
}

extension View {
    func glassSurface(_ kind: GlassSurface.Kind = .floating) -> some View {
        modifier(GlassSurfaceModifier(kind: kind))
    }
}

/// Which kind of button face `surfaceButton` gives.
enum SurfaceButtonRole {
    /// The main action: Liquid Glass tinted with the accent colour (prominent).
    case primary
    /// A quiet action next to it: clear Liquid Glass.
    case secondary
    /// Anything else (a chosen answer, a plain text button): always the flat fill below.
    case flat
}

/// A flat capsule: the face of a surface button before iOS 26, and of the flat role.
struct FilledCapsuleButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension View {
    /// A button on a floating surface. On iOS 26 the primary and secondary roles are Liquid Glass
    /// buttons (`.glassProminent` / `.glass`), which draw their own face, foreground and press
    /// feedback; the label brings only its content and size. Before that, and for `.flat`, the label
    /// sits on `fill` in `foreground`, as the buttons always looked.
    @ViewBuilder
    func surfaceButton(
        _ role: SurfaceButtonRole, tint: Color = .ikutAccent, fill: Color, foreground: Color
    ) -> some View {
        if role != .flat, GlassSurface.useGlass, #available(iOS 26, *) {
            if role == .primary {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(tint)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else {
            buttonStyle(FilledCapsuleButtonStyle(fill: fill, foreground: foreground))
        }
    }
}

extension View {
    /// An inset tile (a stop reason, the suggested place) on a floating surface. On iOS 26 glass it is a
    /// raised, translucent tile, so the glass shows through, not the opaque gray slab the sheets use.
    @ViewBuilder
    func surfaceTile(radius: CGFloat = Radius.tile) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            background(Color.surfaceTileFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
        } else {
            ikutTile(radius: radius)
        }
    }
}

extension Color {
    /// The tile colour `surfaceTile` uses, for a tile that draws its own background (a place row).
    static var surfaceTileBackground: Color {
        if GlassSurface.useGlass, #available(iOS 26, *) { return surfaceTileFill }
        return Color(.secondarySystemBackground)
    }

    /// Light: a milky white; dark: a faint lift. Both let the glass behind show.
    static let surfaceTileFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.5)
    })
}

extension Color {
    /// Secondary text on a floating surface. On glass the system gray falls to about 3:1 in dark, so it
    /// is lifted there; elsewhere it is the usual secondary label.
    static var surfaceSecondary: Color {
        guard GlassSurface.active else { return Color.secondary }
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.78) : UIColor(white: 0, alpha: 0.68)
        })
    }

    /// How much a stale car's row is dimmed: less on glass, where 0.6 went thin.
    static var staleRowOpacity: Double { GlassSurface.active ? 0.78 : 0.6 }
}
