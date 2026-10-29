import Testing
import CoreGraphics
@testable import ikut

@Suite("Text sizes off the map")
struct TypeSizeTests {
    @Test("Text keeps its line limit at normal sizes and wraps freely at accessibility sizes")
    func lineLimit() {
        #expect(LineLimit.lines(1, accessibility: false) == 1)
        #expect(LineLimit.lines(2, accessibility: false) == 2)
        #expect(LineLimit.lines(1, accessibility: true) == nil)
    }

    @Test("A display size follows the text size but never passes its cap")
    func cappedSize() {
        #expect(ScaledSize.capped(30, base: 30, cap: 1.5) == 30)
        #expect(ScaledSize.capped(40, base: 30, cap: 1.5) == 40)
        #expect(ScaledSize.capped(90, base: 30, cap: 1.5) == 45)
    }

    @Test("A glyph role is its base at the default size, grows with the text, and stops at its cap")
    func glyphRole() {
        // At the default text size the scaled value equals the base, so nothing changes on screen.
        #expect(ScaledSize.capped(14, base: 14, cap: 1.3) == 14)
        // One step up still grows.
        #expect(abs(ScaledSize.capped(16, base: 14, cap: 1.3) - 16) < 0.001)
        // At accessibility sizes it stops at base * cap, so a fixed circle is never outgrown.
        #expect(abs(ScaledSize.capped(14 * 3, base: 14, cap: 1.3) - 18.2) < 0.001)
        // Smaller text sizes shrink it a little, never grow.
        #expect(ScaledSize.capped(12, base: 14, cap: 1.3) == 12)
    }
}
