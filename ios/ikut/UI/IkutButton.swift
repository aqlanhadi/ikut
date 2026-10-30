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
    /// What Apple's large capsule adds above and below its label, scaled with the text size.
    @ScaledMetric(relativeTo: .body) private var pad = 14

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, pad)
            .foregroundStyle(foreground)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
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

/// Which of the styles an `ikutButton` draws, and whether that style pads the label: decided from the role, the stop
/// card's flat face, the surface and whether glass is showing (iOS 26 and `GlassSurface.useGlass`).
struct IkutButtonLook: Equatable {
    enum Kind: Equatable { case flat, glassProminent, glass, borderedProminent, bordered, borderless }
    var kind: Kind
    static func resolve(role: IkutButtonRole, face: IkutButtonFace?, surface: IkutSurface, glassActive: Bool) -> IkutButtonLook {
        switch role {
        case .flat: return IkutButtonLook(kind: .flat)
        case .link: return IkutButtonLook(kind: .borderless)
        case .primary, .secondary:
            let primary = role.isPrimary
            if surface == .glass, glassActive { return IkutButtonLook(kind: primary ? .glassProminent : .glass) }
            if face != nil { return IkutButtonLook(kind: .flat) }
            return IkutButtonLook(kind: primary ? .borderedProminent : .bordered)
        }
    }
}

/// Accent text with no fill. The label itself is at least `SheetButtonSize.hit` (44) tall and the whole of it is
/// tappable, so the button's tap area is 44, not just the words.
private struct LinkButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .frame(minHeight: SheetButtonSize.hit)
            .contentShape(Rectangle())
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.6 : 1)
    }
}

private extension View {
    @ViewBuilder func applyStyle(_ look: IkutButtonLook, role: IkutButtonRole, face: IkutButtonFace?, tint: Color) -> some View {
        switch look.kind {
        case .flat:
            if case .flat(let own) = role {
                buttonStyle(FilledCapsuleButtonStyle(fill: own.fill, foreground: own.foreground))
            } else if let face {
                buttonStyle(FilledCapsuleButtonStyle(fill: face.fill, foreground: face.foreground))
            }
        case .glassProminent:
            if #available(iOS 26, *) { buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large).tint(tint) }
        case .glass:
            if #available(iOS 26, *) { buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).tint(tint) }
        case .borderedProminent: buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).tint(tint)
        case .bordered: buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large).tint(tint)
        case .borderless: buttonStyle(LinkButtonStyle(tint: tint))
        }
    }
}

private struct IkutButtonModifier: ViewModifier {
    var role: IkutButtonRole
    var face: IkutButtonFace?
    var tint: Color?
    @Environment(\.buttonSurface) private var surface

    func body(content: Content) -> some View {
        let look = IkutButtonLook.resolve(role: role, face: face, surface: surface, glassActive: GlassSurface.active)
        content.applyStyle(look, role: role, face: face, tint: tint ?? role.defaultTint)
    }
}

extension View {
    /// The one button API. Apply to a `Button` (or `ShareLink`) whose label is full width with `.frame(maxWidth: .infinity)`.
    /// The height is Apple's own large control size (about 50 pt, growing with the text size); the glass or filled look
    /// comes from the surface (`buttonSurface`).
    /// `surface`: the flat face a stop card button keeps before iOS 26 in place of Apple's bordered style (the card's
    /// primary and secondary are gray and accent capsules there); a link has none.
    /// `tint`: a colour other than the accent, for a bar that keeps its own (the blue fill, or primary text on a clear button).
    func ikutButton(_ role: IkutButtonRole, surface: IkutButtonFace? = nil, tint: Color? = nil) -> some View {
        modifier(IkutButtonModifier(role: role, face: surface, tint: tint))
    }
}

extension IkutButtonRole {
    /// Primary fills with `ikutAccentFill`, so its white label holds 4.5:1 in both modes; the roles whose label is
    /// the tint (secondary, link) use `accentText` (D79).
    fileprivate var defaultTint: Color { isPrimary ? .ikutAccentFill : .accentText }
    fileprivate var isPrimary: Bool { if case .primary = self { true } else { false } }
}
