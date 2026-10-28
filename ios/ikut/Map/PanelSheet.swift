import SwiftUI

/// The sizes and detents of the driving screen's convoy sheet, pure so they can be tested; what it steps aside for is
/// the one list (`TripSheetCover`).
/// The sheet is Apple's own (`.sheet`, always up, the map above it stays touchable): short shows today's
/// folded panel, tall the unfolded one. A card (Report, Pit stop, who is here) is a sheet of its own over it, as
/// tall as its content (`cardHeight`). Heights are the panel's own measured height, so the text size is followed; until a layout has been
/// seen once, an estimate stands in. Neither ever passes the room under the pills and banners. Pulled up to its
/// tallest (D53, canvas row L), the unfolded panel stays where it was and the lobby continues below it.
enum PanelSheet {
    /// What the sheet is showing now: the folded panel (short), the unfolded one (tall), or the unfolded one with the
    /// lobby continuing below it (pulled up, as tall as the room allows).
    enum Shown: Equatable {
        case folded, unfolded, pulledUp

        /// The convoy list is unfolded at tall and pulled up alike, so pulling up never moves what was being read.
        var listUnfolded: Bool { self != .folded }

        /// The header's fold and unfold: unfolding a pulled-up sheet leaves it pulled up. The size to move to, nil
        /// when the list is in that state already.
        func expanding(_ value: Bool) -> Shown? {
            value == listUnfolded ? nil : (value ? .unfolded : .folded)
        }
    }

    /// The panel's content heights before they are measured (folded, then unfolded), without the bar.
    static let foldedEstimate: CGFloat = 220
    static let unfoldedEstimate: CGFloat = 450
    /// A card's content height before it is measured.
    static let cardEstimate: CGFloat = 330
    /// The gap beside Report and Pit stop (to the sheet's side edges), and under them to the sheet's bottom edge.
    static let sideGap: CGFloat = Spacing.l
    /// How far the buttons hang down into the sheet's bottom safe area (the home indicator's) so the gap under them
    /// equals `sideGap`. Never negative, so a sheet without a safe area (an iPhone with a home button) keeps them
    /// where the layout puts them; never more than leaves the indicator's own strip (`indicatorClearance`) free.
    static func barLift(safeBottom: CGFloat, gap: CGFloat = sideGap) -> CGFloat {
        max(0, min(safeBottom - gap, safeBottom - indicatorClearance))
    }
    /// The strip at the very bottom the home indicator draws in; the buttons stay above it.
    static let indicatorClearance: CGFloat = 14
    /// The sheet never gets smaller than this, however little room the pills leave.
    static let minimumHeight: CGFloat = 150

    struct Heights: Equatable {
        var short: CGFloat
        var tall: CGFloat
        /// Pulled up: never under tall.
        var full: CGFloat

        init(short: CGFloat, tall: CGFloat, full: CGFloat? = nil) {
            self.short = short
            self.tall = tall
            self.full = max(tall, full ?? tall)
        }
    }

    /// What continues below the unfolded panel when it is pulled up, before the room is measured; the room caps it.
    static let continuationEstimate: CGFloat = 600

    /// The bar's height before it is measured (Report and Pit stop with the space above them).
    static let barEstimate: CGFloat = 62

    /// The detent heights: each panel content height (nil until seen) plus the pinned bar's (nil until seen), capped
    /// at `room`, the map's height under the pills and banners (nil before the map is measured). No home-indicator strip is added: a presented sheet already keeps its content out of the bottom safe
    /// area, so adding it again (as Home's formula does for its own header) left about 34 pt of empty space.
    /// When the content is taller than the cap, the list scrolls under the bar and the bar stays in view.
    /// `top`: what sits above the panel at every height (the "no longer in this trip" banner), measured.
    static func heights(folded: CGFloat?, unfolded: CGFloat?, bar: CGFloat? = nil, top: CGFloat = 0, room: CGFloat?) -> Heights {
        let cap = max(room ?? .greatestFiniteMagnitude, minimumHeight)
        let barHeight = bar ?? barEstimate
        func fit(_ content: CGFloat?, _ estimate: CGFloat, bar: CGFloat = 0) -> CGFloat {
            min((content ?? estimate) + top + bar, cap).rounded()
        }
        let short = fit(folded, foldedEstimate, bar: barHeight)
        let tall = max(short, fit(unfolded, unfoldedEstimate, bar: barHeight))
        let full = room == nil ? tall + continuationEstimate : cap.rounded()
        return Heights(short: short, tall: tall, full: full)
    }

    /// What a detent the sheet reports means for the panel: folded, unfolded or pulled up when it is one of the
    /// heights it has now, nothing for any other value. A measured height that changes under an open tall sheet
    /// reports its old detent for a moment; that is not the driver folding the list. When tall is already as tall as
    /// the room, the one top detent is pulled up, so the lobby continues below the list there.
    static func choice(_ detent: PresentationDetent, in heights: Heights) -> Shown? {
        if detent == .height(heights.short) { return .folded }
        if detent == .height(heights.full) { return .pulledUp }
        if detent == .height(heights.tall) { return .unfolded }
        return nil
    }

    /// Whether the lobby continues below the unfolded panel: pulled up, or unfolded when tall is already the tallest.
    static func showsContinuation(_ shown: Shown, in heights: Heights) -> Bool {
        shown.listUnfolded && height(shown, in: heights) >= heights.full
    }

    /// The card sheet's one detent: its content's measured height (nil until seen), capped at `room` like the
    /// convoy sheet and never under `minimumHeight`.
    /// With the keyboard up (a passenger typing a stop message), the sheet is taller by what the keyboard covers, so the
    /// card sits above it with its field in view; the card's own layout never sees the keyboard (Q16).
    static func cardHeight(content: CGFloat?, room: CGFloat?, keyboard: CGFloat = 0) -> CGFloat {
        min((content ?? cardEstimate) + max(keyboard, 0), max(room ?? .greatestFiniteMagnitude, minimumHeight)).rounded()
    }

    /// How much of the screen's bottom the keyboard covers, from its end frame in screen coordinates: 0 when it is
    /// gone or off screen.
    static func keyboardCover(frame: CGRect, screenHeight: CGFloat) -> CGFloat {
        guard !frame.isEmpty, !frame.isNull else { return 0 }
        return max(0, screenHeight - frame.minY).rounded()
    }

    /// The card's bottom safe area, kept for its buttons' lift (`barLift`): a reading taken with the keyboard up is
    /// the keyboard's, not the home indicator's, and would hang the buttons down under the keyboard, so it is ignored.
    static func cardSafeBottom(reading: CGFloat, keyboard: CGFloat, last: CGFloat) -> CGFloat {
        keyboard > 0 ? last : reading
    }

    /// The height of the map the sheets cover, for the camera: the convoy sheet's, or the card's when it is the taller.
    /// Pulled up counts as tall: the lobby is read over the map then, and pulling up never moves the camera under it.
    static func covered(shown: Shown, in heights: Heights, card: CGFloat?) -> CGFloat {
        max(height(shown == .pulledUp ? .unfolded : shown, in: heights), card ?? 0)
    }

    static func height(_ shown: Shown, in heights: Heights) -> CGFloat {
        switch shown {
        case .folded: heights.short
        case .unfolded: heights.tall
        case .pulledUp: heights.full
        }
    }

    // MARK: The card sheet's open and close rule

    /// Whether the card sheet is up, and whether one is on its way out (its dismissal not yet reported).
    struct CardSheet: Equatable {
        var presented = false
        var dismissing = false
    }

    /// What the card sheet does when a card is `wanted` or not. One card at a time: a card asked for while another
    /// is up swaps in the sheet that is up; one asked for while a card slides down waits for `cardDismissed`; none
    /// wanted starts the dismissal of the one that is up.
    static func cardSync(_ state: CardSheet, wanted: Bool) -> CardSheet {
        var next = state
        if wanted {
            if !state.presented, !state.dismissing { next.presented = true }
        } else if state.presented {
            next = CardSheet(presented: false, dismissing: true)
        }
        return next
    }

    /// The sheet reported its dismissal (or the fallback `cardDismissFallback` ran): a card still wanted opens now.
    static func cardDismissed(_ state: CardSheet, wanted: Bool) -> CardSheet {
        cardSync(CardSheet(presented: state.presented, dismissing: false), wanted: wanted)
    }

    /// The convoy sheet under the card went away (the trip ended, the Always explainer, leaving), taking the card with it
    /// and its dismissal report: nothing is up and nothing is on its way out; the card comes back with the convoy sheet.
    static let cardsGone = CardSheet()

    /// How long a dismissal may go unreported before the next card opens anyway.
    static let cardDismissFallback: TimeInterval = 1

    /// The convoy sheet's detents: short (folded), tall (unfolded) and pulled up (one with tall when tall is the tallest).
    static func detents(in heights: Heights) -> Set<PresentationDetent> {
        [.height(heights.short), .height(heights.tall), .height(heights.full)]
    }

    static func detent(_ shown: Shown, in heights: Heights) -> PresentationDetent { .height(height(shown, in: heights)) }

    // MARK: One motion (D42: A1, A2, A3, A6)

    /// A measured height is taken at rest only when it differs from the one in use by more than this (a sub-point
    /// re-layout is not a resize).
    static let settleTolerance: CGFloat = 1
    /// After a fold motion has finished (its removed views gone), how long before the held heights are let go.
    static let settleAfterMotion: TimeInterval = 0.1
    /// The longest a motion holds the heights, should its completion never come.
    static let motionLongest: TimeInterval = 1.2

    /// The heights the sheet uses. While it moves (a fold, a drag let go) it holds the panel's
    /// short and tall heights, so the detent it is moving to never changes under
    /// it (the fold used to hand the sheet a new detent set mid-motion, which it applied in one frame). At rest each
    /// measured height is taken when it differs by more than `settleTolerance`. `applied` nil (nothing used yet): the
    /// measured ones.
    static func settled(_ applied: Heights?, measured: Heights, moving: Bool) -> Heights {
        guard let applied else { return measured }
        func take(_ old: CGFloat, _ new: CGFloat, hold: Bool) -> CGFloat {
            !hold && abs(new - old) > settleTolerance ? new : old
        }
        return Heights(
            short: take(applied.short, measured.short, hold: moving),
            tall: take(applied.tall, measured.tall, hold: moving),
            full: take(applied.full, measured.full, hold: moving))
    }

    /// The moments that touch the sheet by themselves: a hazard approach and its end, and a stop request that needs an
    /// answer (its pill, or a card over the sheet).
    enum Moment: Equatable { case approaching, passed, gaveUp, stopAsks }

    /// What the sheet shows after `moment`, from `shown` now. The approach folds it, so my car and the hazard have the
    /// room; passing the hazard (or giving up on it) leaves it as it is: the owner's choice (#344), since the unfolded
    /// list covers more than half the map while the car is moving. A stop asking brings a pulled-up sheet back to tall,
    /// so the pill and the card are not behind the lobby; folded or tall it stays (#402).
    static func shown(after moment: Moment, from shown: Shown) -> Shown {
        switch moment {
        case .approaching: .folded
        case .passed, .gaveUp: shown
        case .stopAsks: shown == .pulledUp ? .unfolded : shown
        }
    }

    /// The room for the sheet: the map's full height less what the pills and banners need above it.
    static func room(mapHeight: CGFloat, reserved: CGFloat) -> CGFloat? {
        mapHeight > 0 ? mapHeight - reserved : nil
    }
}

private struct CardActionLiftKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    /// How far a card sheet's buttons hang into its bottom safe area (`PanelSheet.barLift`, with the card's 20 pt gap).
    var cardActionLift: CGFloat {
        get { self[CardActionLiftKey.self] }
        set { self[CardActionLiftKey.self] = newValue }
    }
}

private struct InPanelSheetKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the convoy sheet: the stop cards drop their own glass, the sheet is the surface.
    var inPanelSheet: Bool {
        get { self[InPanelSheetKey.self] }
        set { self[InPanelSheetKey.self] = newValue }
    }
}
