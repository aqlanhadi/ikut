import SwiftUI

/// What Apple's own bottom sheets in the app share (Home's trips sheet, the driving screen's convoy panel):
/// a sheet is presented over its view, so anything else that needs presenting waits for it to go, and it
/// reports its own appear and dismiss instead of the app guessing with a timer.
enum BottomSheet {
    /// Room the drag indicator takes above the content.
    static let indicatorRoom: CGFloat = 20

    /// Something else is presented only once the always-up sheet is gone: one sheet can't come up while
    /// another is still on its way down. `sheetUp` follows the sheet's own appear and dismiss.
    static func presents(wanted: Bool, sheetUp: Bool) -> Bool { wanted && !sheetUp }

    /// Whether the sheet has settled on its tall detent (a dragged sheet reports only its detent).
    static func isTall(_ detent: PresentationDetent, tall: PresentationDetent) -> Bool { detent == tall }
}
