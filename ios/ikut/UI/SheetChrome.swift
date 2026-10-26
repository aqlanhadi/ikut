import SwiftUI

/// The pieces every Apple-sheet-on-the-map screen shares (the driving screen's convoy sheet, the lobby's sheet,
/// New trip): the action bar on glass, the glass button faces inside it, and the round glass icon button.

extension View {
    /// The bottom bar of a sheet that is the glass surface itself: no background of its own, `Spacing.l` beside
    /// the buttons, and the buttons hanging `lift` down into the sheet's bottom safe area (`PanelSheet.barLift`) so
    /// the gap under them equals the gap beside them. The bar's layout height stops above the safe area, so
    /// detents stay content + bar. Put it on the bar's content inside a bottom `safeAreaInset`.
    func sheetActionBar(lift: CGFloat = 0) -> some View {
        padding(.horizontal, PanelSheet.sideGap)
            .padding(.top, Spacing.m)
            .padding(.bottom, -lift)
    }

    /// Liquid Glass buttons on iOS 26 (the owner chose glass on the sheet, 2026-10-25): the main action prominent
    /// and tinted with the accent, the quieter one clear (`GlassSurface.useGlass` is the switch). Before iOS 26,
    /// the tinted and bordered capsules as before.
    @ViewBuilder func actionBarStyle(prominent: Bool) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).tint(.primary)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
        }
    }
}

extension View {
    /// A tile inside a tile (the lobby's route total inside its card): a faint darkening on glass, the screen colour
    /// elsewhere.
    @ViewBuilder func innerTile(radius: CGFloat = Radius.inner) -> some View {
        if GlassSurface.active {
            background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            ikutSurface(Color.ikutScreen, radius: radius)
        }
    }
}

/// A round icon button (44 pt to tap) for the top corners of a sheet: Liquid Glass on iOS 26, else a quiet
/// filled circle. Any SF Symbol: the close "x", Back, Share.
struct RoundGlassIconButton: View {
    var systemImage: String
    var label: String
    var action: () -> Void

    var body: some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(.primary)
            .accessibilityLabel(label)
        } else {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(label)
        }
    }
}
