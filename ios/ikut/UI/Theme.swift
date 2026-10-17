import SwiftUI
import UIKit

/// Shared look from the design canvas: grouped background, 24 pt inset cards,
/// 50 pt pill buttons and the #0071E3 accent. All colors adapt to dark mode.
extension Color {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        func ui(_ v: UInt32) -> UIColor {
            UIColor(
                red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }

    static let ikutAccent = dynamic(light: 0x0071E3, dark: 0x2997FF)
    /// "Tracking" and other positive status text (darker than system green for contrast on white).
    static let ikutPositive = dynamic(light: 0x1F7A35, dark: 0x30D158)
    /// "Waiting" status text.
    static let ikutWarning = dynamic(light: 0xC93400, dark: 0xFF9F0A)
    static let ikutScreen = Color(.systemGroupedBackground)
    static let ikutCard = Color(.secondarySystemGroupedBackground)
}

extension View {
    /// White (secondary grouped) inset card with 24 pt continuous corners.
    func ikutCard() -> some View {
        background(Color.ikutCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Full-width accent capsule, 50 pt high.
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Color.ikutAccent.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// Borderless accent text button, 50 pt high, for the secondary action under a pill.
struct LinkPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Small uppercase caption above a card.
struct CardHeader: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let trailing { Text(trailing) }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 6)
    }
}

/// Hairline between rows inside a card.
struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 16)
    }
}
