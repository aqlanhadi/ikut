import SwiftUI

/// One car in the lobby's Cars list, laid out like the convoy sheet's rows (`ConvoyRowView`): its number badge, the
/// name with a line under it, and Ready or Waiting on the trailing side. Nothing here says where a car is (#361).
struct CarRow: View {
    let text: LobbyContent.CarText
    let number: Int
    let colorHex: String

    var body: some View {
        HStack(spacing: Spacing.m) {
            CarBadge(number: number, colorHex: colorHex, size: IconSize.small.base)
            VStack(alignment: .leading, spacing: 0) {
                Text(text.name).font(.body).wrapsAtAccessibilitySizes()
                Text(text.line).font(.footnote).foregroundStyle(text.ready ? Color.surfaceSecondary : Color.ikutWarning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(text.trailing)
                .font(.subheadline)
                .foregroundStyle(text.ready ? Color.ikutPositive : Color.ikutWarning)
        }
        .ikutRow()
        .padding(.horizontal, Spacing.l)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("lobby.car.\(number)")
    }
}
