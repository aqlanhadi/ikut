import SwiftUI

// MARK: - Mode control

/// Follow / fit buttons; neither is highlighted in free mode.
struct MapModeControl: View {
    @Binding var mode: MapMode
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.round
    /// Bumped by the buttons only: the haptic follows a tap, not a pan that switches the mode to free.
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 0) {
            button(.follow, symbol: "location.fill", label: "Follow my car")
            Divider().padding(.horizontal, Spacing.s)
            button(.fit, symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", label: "Fit whole convoy")
        }
        .frame(width: side)
        .glassSurface(.control)
        .sensoryFeedback(.selection, trigger: taps)
    }

    private func button(_ target: MapMode, symbol: String, label: String) -> some View {
        Button { mode = target; taps += 1 } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mode == target ? Color.surfaceAccent : Color.primary)
                .frame(width: side, height: side)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }
}

// MARK: - Read alerts aloud

/// Its own round glass button under the follow / fit control: the speaker is on (accent) or slashed (off).
struct ReadAloudButton: View {
    @Binding var isOn: Bool
    @ScaledMetric(relativeTo: .body) private var side = SheetButtonSize.round

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? Color.surfaceAccent : Color.primary)
                .frame(width: side, height: side)
        }
        .glassSurface(.control)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityLabel("Read alerts aloud")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
