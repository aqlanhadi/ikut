import SwiftUI

/// The top of Home's sheet (D63 B1): Where to? with the name's avatar, and Join with a code.
struct HomeHeader: View {
    var onNewTrip: () -> Void
    var onJoin: () -> Void
    /// Who the avatar shows; nil hides it.
    var profileName: String?
    /// The search bar's height, which the name button is made to match (it grows with the text size).
    @Binding var barHeight: CGFloat
    var onProfile: (String) -> Void
    @ScaledMetric(relativeTo: .body) private var scaledTile = SheetButtonSize.tile
    /// The icon tile grows with the text size, up to `SheetButtonSize.maxScale` times.
    private var tileSide: CGFloat { min(scaledTile, SheetButtonSize.tile * SheetButtonSize.maxScale) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Apple Maps' top row: the search bar and the name's avatar. Tapping the bar starts the same flow, in
            // Where to?, where the bar becomes editable.
            HStack(spacing: Spacing.s) {
                SheetSearchButton(placeholder: "Where to?", action: onNewTrip)
                    .trackingHeight($barHeight)
                    .accessibilityIdentifier("homeWhereTo")
                profileButton
            }
            .padding(.top, Spacing.xs)

            Button(action: onJoin) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: tileSide, height: tileSide)
                        .background(Color(.label).opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Join with a code").font(.body.weight(.medium)).foregroundStyle(.primary)
                    Spacer(minLength: Spacing.s)
                    Text("or scan").font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                }
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
                .surfaceTile(radius: Radius.inner)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homeJoin")
        }
    }

    @ViewBuilder
    private var profileButton: some View {
        if let name = profileName {
            RoundGlassIconButton(text: name.prefix(1).uppercased(), label: "Your name and settings", size: barHeight, exact: true) {
                onProfile(name)
            }
        }
    }
}
