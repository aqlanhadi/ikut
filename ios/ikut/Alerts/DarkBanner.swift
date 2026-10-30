import SwiftUI

/// The one dark banner on the map (MapHazard.dc.html): a 40 pt icon circle, a title with an
/// optional subtitle, and an optional trailing view (a close button, Undo, a live distance).
/// At least 56 pt tall and fully rounded; a two-line subtitle makes it taller and it stays rounded.
/// Used by the alert banner, the approach pill, "Passed the …" and the report toast.
struct DarkBanner<Icon: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    /// Fill behind the icon; the glyph on it is black.
    let circle: Color
    @ViewBuilder var icon: Icon
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.s) {
            icon
                .font(.title3.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(circle, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.body.weight(.semibold)).wrapsAtAccessibilitySizes(lines: 2)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Color.white.dimmed(.faded))
                        .wrapsAtAccessibilitySizes(lines: 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(.white)
        // 14 on the right as on the canvas; a button there brings its own room.
        .padding(.leading, Spacing.s)
        .padding(.trailing, Trailing.self == EmptyView.self ? Spacing.l : Spacing.s)
        .padding(.vertical, Spacing.xs)
        .frame(minHeight: 56)
        // #1C1C1E, as on the design canvas.
        .background(Color.ikutBannerDark, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .elevation(.floating)
    }
}

extension DarkBanner where Icon == Image {
    init(title: String, subtitle: String? = nil, symbol: String, circle: Color,
         @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, subtitle: subtitle, circle: circle, icon: { Image(systemName: symbol) }, trailing: trailing)
    }
}

extension DarkBanner where Icon == Image, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String, circle: Color) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, circle: circle) { EmptyView() }
    }
}

#Preview {
    VStack(spacing: Spacing.m) {
        DarkBanner(title: "Passed the debris", symbol: Symbol.tick, circle: .green)
        DarkBanner(title: "Debris ahead in 500 m", subtitle: "Reported by Wyna’s car · 4 min ago",
                   symbol: Symbol.warning, circle: .orange)
        DarkBanner(
            title: "Message from Wyna’s car",
            subtitle: "We'll wait at the Tapah R&R, the one after the toll, near the surau. Take your time.",
            symbol: Symbol.message, circle: .white)
        DarkBanner(title: "Heavy rain reported", symbol: Symbol.rain, circle: .yellow) {
            Button {} label: { RoundIconSymbol(systemImage: Symbol.close, glyph: .body.weight(.semibold), style: .bare, color: .white) }
                .accessibilityLabel("Close")
        }
        DarkBanner(title: "Sending debris…", circle: .white.fill(.tint)) {
            ProgressView().tint(.white)
        } trailing: {
            EmptyView()
        }
    }
    .padding(Spacing.m)
}
