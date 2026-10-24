import SwiftUI

// MARK: - Mode control

/// Follow / fit buttons; neither is highlighted in free mode.
struct MapModeControl: View {
    @Binding var mode: MapMode

    var body: some View {
        VStack(spacing: 0) {
            button(.follow, symbol: "location.fill", label: "Follow my car")
            Divider().padding(.horizontal, Spacing.s)
            button(.fit, symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", label: "Fit whole convoy")
        }
        .frame(width: 44)
        .glassSurface(.control)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func button(_ target: MapMode, symbol: String, label: String) -> some View {
        Button { mode = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mode == target ? Color.surfaceAccent : Color.primary)
                .frame(width: 44, height: 46)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }
}
