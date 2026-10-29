import SwiftUI

/// The fill and text colour of a flat capsule button (a chosen answer, a plain text button, or the
/// face a surface button keeps before iOS 26).
struct IkutButtonFace {
    var fill: Color
    var foreground: Color
}

/// The looks of a button. Each is Apple's own button style except `.flat`, so pressed, disabled and
/// Dynamic Type come from the system.
enum IkutButtonRole {
    /// Accent filled capsule (`.borderedProminent`, `.glassProminent` on glass).
    case primary
    /// The quiet one beside it (`.bordered`, `.glass` on glass).
    case secondary
    /// Accent text with no fill, under a primary (`.borderless`).
    case link
    /// A flat capsule in the given colours, never glass.
    case flat(IkutButtonFace)
}

/// A flat capsule: the face of the flat role, and of a surface button before iOS 26.
private struct FilledCapsuleButtonStyle: ButtonStyle {
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
    /// The one button API. Apply to a `Button` (or `ShareLink`); a full-width label has `.frame(maxWidth: .infinity)`.
    /// `onGlass`: a bar button on a Liquid Glass sheet, so on iOS 26 primary and secondary use the glass styles.
    /// `surface`: a button on a floating surface (the stop card), primary or secondary only. Its label brings its
    /// own size, it is glass on iOS 26, and otherwise it is that flat capsule instead of Apple's bordered style.
    @ViewBuilder
    func ikutButton(
        _ role: IkutButtonRole, onGlass: Bool = false, surface: IkutButtonFace? = nil
    ) -> some View {
        if case .flat(let face) = role {
            buttonStyle(FilledCapsuleButtonStyle(fill: face.fill, foreground: face.foreground))
        } else if let face = surface, !role.isLink {
            if GlassSurface.useGlass, #available(iOS 26, *) {
                if case .primary = role {
                    buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(Color.ikutAccent)
                } else {
                    buttonStyle(.glass).buttonBorderShape(.capsule)
                }
            } else {
                buttonStyle(FilledCapsuleButtonStyle(fill: face.fill, foreground: face.foreground))
            }
        } else if onGlass, !role.isLink, GlassSurface.useGlass, #available(iOS 26, *) {
            if case .primary = role {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).tint(Color.ikutAccent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).tint(Color.ikutAccent)
            }
        } else {
            let _ = assert(surface == nil, "a link button has no surface face")
            switch role {
            case .flat:
                EmptyView()  // handled first
            case .primary:
                buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(Color.ikutAccent)
            case .secondary:
                buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(Color.ikutAccent)
            case .link:
                buttonStyle(.borderless).buttonBorderShape(.capsule).controlSize(.large).tint(Color.ikutAccent)
            }
        }
    }
}

private extension IkutButtonRole {
    var isLink: Bool { if case .link = self { true } else { false } }
}
