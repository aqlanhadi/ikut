import SwiftUI

/// The two type roles for text and glyphs that need an exact point size (D76). Everything else uses a text style.
///
/// - `Font.ikutDisplay`: a code or number display. The view reads its own `@ScaledMetric` (the base size, relative
///   to the style it sits near) and passes it in; the size follows the text size but stops at `cap` times the base,
///   so a short token such as a join code still fits on one line at the largest sizes.
/// - `View.ikutGlyph`: an icon or a small label that sits in a fixed circle or tile. It scales with the text size
///   from `base` (so the default size is unchanged) and stops at `cap` times the base, so the tile is never outgrown.
extension Font {
    static func ikutDisplay(scaled: CGFloat, base: CGFloat, cap: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: ScaledSize.capped(scaled, base: base, cap: cap), weight: weight, design: design)
    }
}

private struct IkutGlyph: ViewModifier {
    var base: CGFloat
    var weight: Font.Weight
    var design: Font.Design
    var cap: CGFloat
    @ScaledMetric private var scaled: CGFloat

    init(base: CGFloat, weight: Font.Weight, design: Font.Design, cap: CGFloat, relativeTo: Font.TextStyle) {
        self.base = base
        self.weight = weight
        self.design = design
        self.cap = cap
        _scaled = ScaledMetric(wrappedValue: base, relativeTo: relativeTo)
    }

    func body(content: Content) -> some View {
        content.font(.ikutDisplay(scaled: scaled, base: base, cap: cap, weight: weight, design: design))
    }
}

extension View {
    /// A glyph or short label of `base` points at the default text size, growing with it up to `cap` times the base.
    func ikutGlyph(_ base: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                   cap: CGFloat = SheetButtonSize.maxScale, relativeTo: Font.TextStyle = .body) -> some View {
        modifier(IkutGlyph(base: base, weight: weight, design: design, cap: cap, relativeTo: relativeTo))
    }
}
