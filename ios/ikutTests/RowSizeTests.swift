import Testing
import SwiftUI
@testable import ikut

/// The two named row and icon sizes (D85): a tappable row is never under a finger, and there are only two icon sizes.
@MainActor
struct RowSizeTests {
    @Test func minimumRowIsAFinger() {
        #expect(RowSize.minimum == 44)
    }

    @Test func iconSizesAreTwoSteps() {
        #expect(IconSize.small.base == 28)
        #expect(IconSize.regular.base == 32)
        #expect(IconSize.small.base < IconSize.regular.base)
    }

    @Test func rowHelperLaysOutAtTheMinimum() {
        let row = Text("Name").ikutRow(fillWidth: true, alignment: .leading)
        let size = ImageRenderer(content: row.frame(width: 200)).uiImage?.size
        #expect(size?.height == RowSize.minimum)
    }

    @Test func tallerContentKeepsItsOwnHeight() {
        let row = VStack { Text("a"); Text("b"); Text("c") }.frame(height: 90).ikutRow()
        let size = ImageRenderer(content: row).uiImage?.size
        #expect(size?.height == 90)
    }
}
