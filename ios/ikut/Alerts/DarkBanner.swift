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
        HStack(spacing: Spacing.gap) {
            icon
                .font(.title3.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 40, height: 40)
                .background(circle, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.body.weight(.semibold)).lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .foregroundStyle(.white)
        // 14 on the right as on the canvas; a button there brings its own room.
        .padding(.leading, Spacing.s)
        .padding(.trailing, Trailing.self == EmptyView.self ? Spacing.cozy : Spacing.s)
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: 56)
        // #1C1C1E, as on the design canvas.
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
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
