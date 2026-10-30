import SwiftUI

extension Color {
    /// "#RRGGBB" (the `#` is optional); nil if malformed.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }

    /// A car's stored color; gray when malformed.
    static func car(hex: String) -> Color { Color(hex: hex) ?? .gray }
}

/// Filled circle in a car's color with its number (or a symbol, e.g. "plus") in white.
/// Decorative: callers put the car's name in the row's accessibility label.
struct CarBadge: View {
    var number: Int?
    var symbol: String?
    var colorHex: String
    var size: CGFloat = IconSize.regular.base

    @ScaledMetric(relativeTo: .body) private var scale = 1.0

    init(number: Int?, colorHex: String, size: CGFloat = IconSize.regular.base) {
        self.number = number
        self.colorHex = colorHex
        self.size = size
    }

    init(symbol: String, colorHex: String, size: CGFloat = IconSize.regular.base) {
        self.symbol = symbol
        self.colorHex = colorHex
        self.size = size
    }

    var body: some View {
        let diameter = size * scale
        ZStack {
            Circle().fill(Color.car(hex: colorHex))
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.46, weight: .bold))
            } else if let number {
                Text("\(number)")
                    .font(.system(size: diameter * 0.47, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack {
        CarBadge(number: 1, colorHex: "#2563EB")
        CarBadge(number: 4, colorHex: "#7C3AED", size: IconSize.small.base)
        CarBadge(symbol: Symbol.add, colorHex: "#8E8E93", size: IconSize.small.base)
    }
    .padding()
}
