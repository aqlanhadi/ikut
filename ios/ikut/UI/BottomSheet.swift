import SwiftUI

/// What Apple's own bottom sheets in the app share (Home's trips sheet, the driving screen's convoy panel):
/// a sheet is presented over its view, so anything else that needs presenting waits for it to go, and it
/// reports its own appear and dismiss instead of the app guessing with a timer.
enum BottomSheet {
    /// Room the drag indicator takes above the content.
    static let indicatorRoom: CGFloat = 20

    /// How far above its `.height` detent a floating sheet's top really is: on an iPhone 17 with iOS 26 the 300 pt
    /// detent is a sheet 320.7 pt tall ending 8 pt above the screen's bottom edge, so its top is 28.7 pt higher than
    /// the detent says (29.2 pt on the driving sheet, whose heights are rounded). Rounded up to 30 so the logo
    /// never ends up under the sheet; older systems, with no floating sheet, just leave a bit more room. Used
    /// until a sheet has been measured, and by sheets that aren't.
    static let detentExtra: CGFloat = 30

    /// Something else is presented only once the always-up sheet is gone: one sheet can't come up while
    /// another is still on its way down. `sheetUp` follows the sheet's own appear and dismiss.
    static func presents(wanted: Bool, sheetUp: Bool) -> Bool { wanted && !sheetUp }

    /// Whether the sheet has settled on its tall detent (a dragged sheet reports only its detent).
    static func isTall(_ detent: PresentationDetent, tall: PresentationDetent) -> Bool { detent == tall }
}
