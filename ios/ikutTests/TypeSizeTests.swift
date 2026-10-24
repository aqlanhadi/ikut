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
}
