import Testing
import SwiftUI
@testable import ikut

/// The named row and icon sizes (D85): a tappable row is never under a finger, and there are only two icon sizes.
@MainActor
struct RowSizeTests {
    private func size<V: View>(_ view: V, width: CGFloat? = nil, type: DynamicTypeSize = .large) -> CGSize? {
        let framed = Group { if let width { view.frame(width: width) } else { view } }.environment(\.dynamicTypeSize, type)
        return ImageRenderer(content: framed).uiImage?.size
    }

    @Test func minimumRowIsAFinger() {
        #expect(RowSize.minimum == 44)
    }

    @Test func iconSizesAreTwoSteps() {
        #expect(IconSize.small.base == 28)
        #expect(IconSize.regular.base == 32)
        #expect(IconSize.maxScale == 1.3)
    }

    @Test func rowHelperLaysOutAtTheMinimum() {
        let s = size(Text("Name").ikutRow())
        #expect(s?.height == RowSize.minimum)
    }

    @Test func fillWidthStretchesAndPlainDoesNot() throws {
        let plain = try #require(size(Text("Name").ikutRow()))
        let filled = try #require(size(Text("Name").ikutRow(fillWidth: true, alignment: .leading), width: 200))
        #expect(plain.width < 200)
        #expect(filled.width == 200)
    }

    @Test func tallerContentKeepsItsOwnHeight() {
        let row = VStack { Text("a"); Text("b"); Text("c") }.frame(height: 90).ikutRow()
        #expect(size(row)?.height == 90)
    }

    @Test func iconFrameScalesButStopsAtTheCap() throws {
        let normal = try #require(size(Color.red.iconFrame(.small)))
        let big = try #require(size(Color.red.iconFrame(.small), type: .accessibility3))
        let huge = try #require(size(Color.red.iconFrame(.small), type: .accessibility5))
        #expect(normal.width == 28)
        #expect(big.width > normal.width)
        #expect(huge.width == big.width, "both are held at the cap")
        #expect(abs(huge.width - 28 * IconSize.maxScale) < 1)
    }

    @Test func clearButtonIsAFinger() throws {
        let s = try #require(size(ClearFieldButton {}))
        #expect(s.width == RowSize.minimum)
        #expect(s.height == RowSize.minimum)
    }
}
