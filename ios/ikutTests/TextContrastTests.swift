import Foundation
import Testing
import UIKit
@testable import ikut

/// D79: text drawn in the accent or positive colour uses `accentText` / `positiveText`, and the primary button's
/// white label sits on `ikutAccentFill`; each pair holds 4.5:1 on the surfaces it is drawn on, in light and dark.
struct TextContrastTests {
    private func rgb(_ name: String, dark: Bool) -> UInt32 {
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        guard let named = UIColor(named: name, in: Bundle.main, compatibleWith: traits) else { return 0xFF00FF }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        named.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ x: CGFloat) -> UInt32 { UInt32(min(max((x * 255).rounded(), 0), 255)) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ v: UInt32) -> Double {
            func ch(_ c: UInt32) -> Double {
                let s = Double(c) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch((v >> 16) & 0xFF) + 0.7152 * ch((v >> 8) & 0xFF) + 0.0722 * ch(v & 0xFF)
        }
        return (max(lum(a), lum(b)) + 0.05) / (min(lum(a), lum(b)) + 0.05)
    }

    /// The surfaces text sits on: white card and grouped grey screen in light; elevated and base black in dark.
    private static let surfaces: [(dark: Bool, bg: UInt32)] = [
        (false, 0xFFFFFF), (false, 0xF2F2F7), (true, 0x1C1C1E), (true, 0x000000),
    ]

    @Test func accentTextAndPositiveTextReadOnEverySurface() {
        for token in ["accentText", "positiveText"] {
            for s in Self.surfaces {
                let ratio = Self.contrast(rgb(token, dark: s.dark), s.bg)
                #expect(ratio >= 4.5, "\(token) \(s.dark ? "dark" : "light") on \(String(s.bg, radix: 16)): \(ratio)")
            }
        }
    }

    @Test func whiteReadsOnTheAccentFillTheButtonUses() {
        for dark in [false, true] {
            let ratio = Self.contrast(0xFFFFFF, rgb("ikutAccentFill", dark: dark))
            #expect(ratio >= 4.5, "white on ikutAccentFill \(dark ? "dark" : "light"): \(ratio)")
        }
    }

    /// The reason the primary tint moved: the brand accent in dark (2997FF) is too light for a white label.
    @Test func theBrandAccentIsNotWhatAWhiteLabelSitsOn() {
        #expect(Self.contrast(0xFFFFFF, rgb("ikutAccent", dark: true)) < 4.5)
    }
}
