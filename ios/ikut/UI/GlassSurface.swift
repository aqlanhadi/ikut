import SwiftUI

/// The surface behind a floating sheet: the trips sheet on the home screen, the convoy panel and the
/// stop card. One place decides how they look; `GlassSurface.useGlass` is the switch.
enum GlassSurface {
    /// Liquid Glass on iOS 26 and later for the floating convoy panel and stop card. False gives them
    /// the frosted material, as before iOS 26. The home trips sheet is glass on iOS 26 either way.
    static let useGlass = false

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
