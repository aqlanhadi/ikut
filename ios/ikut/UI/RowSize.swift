import SwiftUI

/// Sizes the system does not give us. Rows and fields are sized by their text and padding; only a row that comes out
/// shorter than a finger gets `RowSize.minimum`, through `ikutRow()`, never a per-row number (D85).
enum RowSize {
    /// The smallest tap target (Apple's 44 pt).
    static let minimum: CGFloat = 44
}

extension View {
    /// A tappable row or a field: its content and padding size it, and it is never under `RowSize.minimum` tall.
    /// `fillWidth` stretches it across its container; `alignment` places the content when it does.
    func ikutRow(fillWidth: Bool = false, alignment: Alignment = .center) -> some View {
        frame(maxWidth: fillWidth ? .infinity : nil, minHeight: RowSize.minimum, alignment: alignment)
    }
}

/// The two sizes of a round or rounded-square icon beside a row's text: the stop number, a role tile, a car badge.
/// Each is drawn at `base` points at the default text size and grows with Dynamic Type.
enum IconSize {
    case small
    case regular

    /// The most an icon grows with the text, so a badge never outgrows its row.
    static let maxScale: CGFloat = 1.3

    var base: CGFloat {
        switch self {
        case .small: 28
        case .regular: 32
        }
    }
}

private struct IconFrame: ViewModifier {
    @ScaledMetric private var side: CGFloat
    private let cap: CGFloat

    init(_ size: IconSize) {
        _side = ScaledMetric(wrappedValue: size.base, relativeTo: .body)
        cap = size.base * IconSize.maxScale
    }

    func body(content: Content) -> some View {
        let drawn = min(side, cap)
        return content.frame(width: drawn, height: drawn)
    }
}

extension View {
    /// A square icon frame of a named size, scaling with the text.
    func iconFrame(_ size: IconSize) -> some View { modifier(IconFrame(size)) }
}

/// The clear (x) button at the end of a text field. SwiftUI has no system one for `TextField` on iOS, so this is the
/// one shared button, with a 44 pt hit area.
struct ClearFieldButton: View {
    var label = "Clear search"
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .foregroundStyle(.tertiary)
                .frame(width: RowSize.minimum, height: RowSize.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
