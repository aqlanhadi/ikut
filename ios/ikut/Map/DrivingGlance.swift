import SwiftUI

/// The small rules that keep the driving map readable at a glance (D34 piece 2a): where the Apple logo and
/// Legal link sit, what fades or moves, how long information stays, and what stays until it is dealt with.
enum DrivingGlance {
    /// The map's bottom safe area for the folded sheet: from the screen's bottom edge to the sheet's top (its detent
    /// height and what a floating sheet adds, `BottomSheet.detentExtra`), so MapKit's own 10 pt between the logo
    /// and the edge of that area is Apple's 10 pt above the sheet. Nothing before the sheet is up. Only the folded
    /// sheet: following the unfolded one would move the convoy fit (Q15 report).
    static func legalInset(foldedSheetHeight: CGFloat) -> CGFloat {
        foldedSheetHeight > 0 ? foldedSheetHeight + BottomSheet.detentExtra : 0
    }

    /// Follow / Fit fades out while the sheet is tall (the sheet would cut through it) and returns when folded.
    static func modeControlOpacity(panelExpanded: Bool) -> Double { panelExpanded ? 0 : 1 }

    enum Motion: Equatable {
        case move(Edge)
        case fade
    }

    /// A pill or banner slides in from `edge`, or just fades with Reduce Motion.
    static func motion(edge: Edge, reduceMotion: Bool) -> Motion { reduceMotion ? .fade : .move(edge) }

    /// `base`, or a short fade with Reduce Motion.
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.2) : base
    }

    /// The camera's glide to a new view; with Reduce Motion it jumps.
    static func cameraAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.8)
    }

    /// How long "Passed the debris" stays; nil (until the next hazard or a Close) while VoiceOver is running.
    static func passedDuration(voiceOver: Bool) -> Duration? { voiceOver ? nil : .seconds(3) }
}

/// An error that stays up until its cause is fixed or the person closes it. No timer.
struct GlanceError: Equatable {
    enum Cause: Equatable { case send, pause }

    private(set) var message: String?
    private(set) var cause: Cause?

    mutating func show(_ message: String, cause: Cause) {
        self.message = message
        self.cause = cause
    }

    mutating func close() {
        message = nil
        cause = nil
    }

    /// A stop action finished: a failure shows `message`; a success clears an earlier send error.
    mutating func actionFinished(failure message: String?) {
        if let message { show(message, cause: .send) } else { resolve(.send) }
    }

    /// The cause is gone (pause ended, a later action went through): the error goes with it.
    mutating func resolve(_ cause: Cause) {
        if self.cause == cause { close() }
    }
}

/// The map's error line with its Close button.
struct GlanceErrorBanner: View {
    let message: String
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("map.error.close")
        }
        .padding(.leading, Spacing.l).padding(.trailing, Spacing.xs).padding(.vertical, Spacing.xs)
        .background(MapColors.errorBanner.color, in: Capsule())
        .elevation(.pill)
        .announces(message)
        .accessibilityIdentifier("map.error")
    }
}

extension View {
    /// Slides in from `edge`, or fades with Reduce Motion.
    func glanceTransition(edge: Edge) -> some View { modifier(GlanceTransition(edge: edge)) }

    /// Says `text` to VoiceOver when this appears, not on each redraw. It speaks again only when `id` changes,
    /// so a live distance or "N min ago" in `text` doesn't repeat it; without an `id`, the text is the identity.
    func announces(_ text: String, id: String? = nil) -> some View {
        modifier(Announces(text: text, key: id ?? text))
    }
}

/// What the banner slot has already said (D34 2b): a message that waited behind a more urgent one and comes back is
/// not said again. The map forgets a key once its message is gone for good, so a new appearance is announced.
@MainActor
final class SpokenBanners {
    private var spoken: Set<String> = []

    /// True the first time a key is asked for since it was last forgotten.
    func claim(_ key: String) -> Bool { spoken.insert(key).inserted }

    /// Forgets every key not in `live`.
    func keep(_ live: Set<String>) { spoken.formIntersection(live) }
}

private struct SpokenBannersKey: EnvironmentKey {
    static let defaultValue: SpokenBanners? = nil
}

extension EnvironmentValues {
    var spokenBanners: SpokenBanners? {
        get { self[SpokenBannersKey.self] }
        set { self[SpokenBannersKey.self] = newValue }
    }
}

private struct Announces: ViewModifier {
    let text: String
    let key: String
    @Environment(\.spokenBanners) private var spoken

    func body(content: Content) -> some View {
        content.task(id: key) { @MainActor in
            if let spoken, !spoken.claim(key) { return }
            AccessibilityNotification.Announcement(text).post()
        }
    }
}

private struct GlanceTransition: ViewModifier {
    let edge: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        switch DrivingGlance.motion(edge: edge, reduceMotion: reduceMotion) {
        case .fade: content.transition(.opacity)
        case .move(let edge): content.transition(.move(edge: edge).combined(with: .opacity))
        }
    }
}
