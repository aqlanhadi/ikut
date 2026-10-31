import SwiftUI

/// The stay of a planned stop as a menu (D121): "20 min" with a chevron, opening the usual lengths and the stop's own.
/// Used in the lobby's stop row and on the map's stop card; the caller decides who sees it (`StopStay.canEdit`).
struct StayMenu: View {
    var minutes: Int?
    var disabled = false
    /// What to read when no length is set: the lobby row offers "Add a stay", the card says "Not set".
    var emptyTitle: LocalizedStringKey = "Add a stay"
    var onPick: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(StopStay.options(current: minutes), id: \.self) { value in
                Button { onPick(value) } label: {
                    if value == minutes {
                        Label(StopFormat.length(minutes: value), systemImage: Symbol.tick)
                    } else {
                        Text(StopFormat.length(minutes: value))
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                if let minutes {
                    Text(StopFormat.length(minutes: minutes)).monospacedDigit()
                } else {
                    Text(emptyTitle)
                }
                Image(systemName: Symbol.chevronUpDown).font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentText)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(minutes.map { Text("Stay, \(StopFormat.length(minutes: $0))") } ?? Text("Stay, not set"))
        .accessibilityIdentifier(AXID.Stop.stay)
    }
}
