import SwiftUI

/// The surface behind a floating card: the convoy panel and the stop card. One place decides how they look; `GlassSurface.useGlass` is the switch.
enum GlassSurface {
    /// Liquid Glass on iOS 26 and later for the floating convoy panel and stop card. False gives them
    /// the frosted material, as before iOS 26.
    static let useGlass = true

    /// True when the glass look is showing (the switch above, on iOS 26 or later).
    static var active: Bool {
        if #available(iOS 26, *) { return useGlass }
        return false
    }

    enum Kind {
        /// Inset card floating over the map, with a plain 38 pt rectangle.
        case floating
        /// The trip pill at the top of the map: a capsule with a lighter shadow.
        case pill
        /// The map's view buttons: a small rounded rectangle with the same lighter shadow.
        case control
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    var kind: GlassSurface.Kind

    /// The floating panel's own corner radius, used nowhere else.
    private static let panelRadius: CGFloat = 38

    private var plain: AnyShape {
        switch kind {
        case .floating: AnyShape(RoundedRectangle(cornerRadius: Self.panelRadius, style: .continuous))
        case .pill: AnyShape(Capsule())
        case .control: AnyShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }

    func body(content: Content) -> some View {
        // Clipped to the same shape: a ScrollView draws on under the safe area and past the rounded
        // corners, and a folding list draws outside a shrinking panel.
        if GlassSurface.useGlass, #available(iOS 26, *) {
            content.clipShape(plain).glassEffect(.regular, in: plain)
        } else {
            content
                .clipShape(plain)
                .background(.regularMaterial, in: plain)
                .elevation(.floating)
        }
    }
}

extension View {
    func glassSurface(_ kind: GlassSurface.Kind = .floating) -> some View {
        modifier(GlassSurfaceModifier(kind: kind))
    }

    /// The glass surface only when `on`: inside Apple's own sheet, the sheet is the surface.
    @ViewBuilder func glassSurface(_ kind: GlassSurface.Kind = .floating, if on: Bool) -> some View {
        if on { glassSurface(kind) } else { self }
    }
}

extension View {
    /// A round button floating over the map: interactive Liquid Glass on iOS 26, else the pill's frosted
    /// material and shadow in a circle.
    @ViewBuilder func roundGlass() -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
                .elevation(.floating)
        }
    }
}

extension View {
    /// An inset tile (a stop reason, a message) on a floating surface. On iOS 26 glass it is a
    /// raised, translucent tile, so the glass shows through, not the opaque gray slab the sheets use.
    @ViewBuilder
    func surfaceTile(radius: CGFloat = Radius.card) -> some View {
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
    /// Secondary text on a floating surface. On glass the system gray falls to about 3:1 in dark, so it
    /// is lifted there; elsewhere it is the usual secondary label.
    static var surfaceSecondary: Color {
        guard GlassSurface.active else { return Color.secondary }
        return Palette.surfaceSecondary.color
    }

    /// How much a stale car's row is dimmed: less on glass, where 0.6 went thin.
    static var staleRowOpacity: Double { GlassSurface.active ? 0.78 : 0.6 }
}

extension Color {
    /// The accent colour for an icon on a glass surface: a lifted blue in dark, where the system blue
    /// goes faint over the map; the usual accent in light and off glass.
    static var surfaceAccent: Color {
        guard GlassSurface.active else { return Color.ikutAccentFill }
        let lifted = UIColor(MapColors.pillBlue.color)
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? lifted : UIColor(Color.ikutAccentFill)
        })
    }
}
