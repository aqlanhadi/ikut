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

/// The height of an `ikutButton`: standard 44 (the least a tap target is) for everything in sheets, bars and cards,
/// and main 50 for the single main action of a full-screen flow. Filled and glass measure the same.
enum IkutButtonSize {
    case standard, main

    var base: CGFloat { self == .main ? 50 : SheetButtonSize.hit }

    /// The button's total height at the text size whose scaled base is `scaled` (an `@ScaledMetric` from `base`):
    /// never under 44, and no more than `SheetButtonSize.maxScale` times the base.
    func height(scaled: CGFloat) -> CGFloat { SheetButtonSize.capped(scaled, base: base) }

    /// What Apple's capsule styles add around the label at `.regular` (measured on iOS 26 in `design-compare-buttons-5`).
    static let styleExtra: CGFloat = 14

    /// The label's minimum height that makes the whole button `height`: the style's own padding comes off, except
    /// for a link and the flat capsule, which add none.
    static func labelMinHeight(total: CGFloat, addsPadding: Bool) -> CGFloat {
        max(total - (addsPadding ? styleExtra : 0), 0)
    }
}

/// The kind of surface a button sits on: it picks glass or filled. Set once where the surface is built.
enum IkutSurface {
    /// A plain screen: the filled styles.
    case plain
    /// Liquid Glass (a glass sheet, the map's floating panels): the glass styles on iOS 26, else the filled ones.
    case glass
}

extension EnvironmentValues {
    @Entry var buttonSurface: IkutSurface = .plain
}

extension View {
    /// Buttons below this view follow `surface`.
    func buttonSurface(_ surface: IkutSurface) -> some View { environment(\.buttonSurface, surface) }
}

/// Gives the button its exact height whatever style draws it: the label gets a minimum height scaled with the text
/// size, and Apple's style is applied to a button inside, so pressed, disabled and the accessibility element stay the system's.
private struct SizedButtonStyle: PrimitiveButtonStyle {
    var role: IkutButtonRole
    var size: IkutButtonSize
    var glass: Bool
    var face: IkutButtonFace?

    func makeBody(configuration: Configuration) -> some View {
        Sized(configuration: configuration, role: role, size: size, glass: glass, face: face)
    }

    private struct Sized: View {
        var configuration: PrimitiveButtonStyleConfiguration
        var role: IkutButtonRole
        var size: IkutButtonSize
        var glass: Bool
        var face: IkutButtonFace?
        @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

        var body: some View {
            let total = size.height(scaled: size.base * scale)
            let minHeight = IkutButtonSize.labelMinHeight(total: total, addsPadding: role.addsStylePadding(face: face, glass: glass))
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(minHeight: minHeight).contentShape(Rectangle())
            }
            .applyStyle(role, glass: glass, face: face)
        }
    }
}

private extension View {
    @ViewBuilder func applyStyle(_ role: IkutButtonRole, glass: Bool, face: IkutButtonFace?) -> some View {
        if case .flat(let face) = role {
            buttonStyle(FilledCapsuleButtonStyle(fill: face.fill, foreground: face.foreground))
        } else if glass, !role.isLink, #available(iOS 26, *) {
            if case .primary = role {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.regular).tint(Color.ikutAccent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.regular).tint(Color.ikutAccent)
            }
        } else if let face, !role.isLink {
            buttonStyle(FilledCapsuleButtonStyle(fill: face.fill, foreground: face.foreground))
        } else {
            switch role {
            case .flat: EmptyView()  // handled first
            case .primary: buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.regular).tint(Color.ikutAccent)
            case .secondary: buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.regular).tint(Color.ikutAccent)
            case .link: buttonStyle(.borderless).buttonBorderShape(.capsule).controlSize(.regular).tint(Color.ikutAccent)
            }
        }
    }
}

private struct IkutButtonModifier: ViewModifier {
    var role: IkutButtonRole
    var size: IkutButtonSize
    var face: IkutButtonFace?
    @Environment(\.buttonSurface) private var surface

    func body(content: Content) -> some View {
        let glass = surface == .glass && GlassSurface.active
        content.buttonStyle(SizedButtonStyle(role: role, size: size, glass: glass, face: face))
    }
}

extension View {
    /// The one button API. Apply to a `Button` (or `ShareLink`) whose label is full width with `.frame(maxWidth: .infinity)`:
    /// the height comes from `size` (44 standard; `.main` 50 only for the one main action of a full-screen flow), the
    /// glass or filled look from the surface (`buttonSurface`).
    /// `surface`: the flat face a stop card button keeps before iOS 26 in place of Apple's bordered style (the card's
    /// primary and secondary are gray and accent capsules there); a link has none.
    func ikutButton(_ role: IkutButtonRole, size: IkutButtonSize = .standard, surface: IkutButtonFace? = nil) -> some View {
        modifier(IkutButtonModifier(role: role, size: size, face: surface))
    }
}

private extension IkutButtonRole {
    var isLink: Bool { if case .link = self { true } else { false } }

    /// Whether the style around the label adds its own padding (the bordered and glass capsules do; a link and the flat capsule don't).
    func addsStylePadding(face: IkutButtonFace?, glass: Bool) -> Bool {
        switch self {
        case .link, .flat: false
        case .primary, .secondary: glass || face == nil
        }
    }
}
