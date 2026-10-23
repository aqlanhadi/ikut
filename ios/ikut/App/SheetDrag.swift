import CoreGraphics

/// The maths of dragging Home's sheet between its short and tall detents, pure so it can be tested.
/// The sheet is laid out once at `layoutHeight` and moved with an offset while a finger is on it, so a
/// drag costs no layout; only the end of a drag (a new detent) does.
enum SheetDrag {
    /// How far past the tall detent the sheet may be pulled (rubber band), kept laid out below the screen.
    static let rubberRoom: CGFloat = 40
    /// How much of a pull past a detent shows.
    static let rubberFactor: CGFloat = 0.2

    /// A drag's translation from where it began to count: `DragGesture` only starts after its
    /// `minimumDistance`, and its translation includes that distance, so the sheet would jump by it.
    static func travel(translation: CGFloat, start: CGFloat?) -> CGFloat {
        translation - (start ?? translation)
    }

    /// The sheet's visible height for a drag of `travel` (positive is down), with rubber bands past both detents.
    static func height(expanded: Bool, compact: CGFloat, tall: CGFloat, travel: CGFloat) -> CGFloat {
        let raw = (expanded ? tall : compact) - travel
        if raw > tall { return tall + (raw - tall) * rubberFactor }
        if raw < compact { return compact - (compact - raw) * rubberFactor }
        return raw
    }

    /// The height the sheet is laid out at.
    static func layoutHeight(tall: CGFloat) -> CGFloat { tall + rubberRoom }

    /// How far down the laid-out sheet is moved to show `height`.
    static func offset(tall: CGFloat, height: CGFloat) -> CGFloat { layoutHeight(tall: tall) - height }

    /// Which detent a finished drag settles on. The fling is projected (`predicted` is the gesture's
    /// predicted end translation) so a quick flick moves a detent over a short distance.
    static func settlesExpanded(expanded: Bool, compact: CGFloat, tall: CGFloat, predicted: CGFloat, start: CGFloat?) -> Bool {
        let projected = (expanded ? tall : compact) - (predicted - (start ?? 0))
        return projected > (compact + tall) / 2
    }
}
