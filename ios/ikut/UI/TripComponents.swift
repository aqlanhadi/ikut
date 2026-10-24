import SwiftUI

/// One line at normal text sizes, as many as it needs at the accessibility sizes, so text wraps instead of
/// shrinking or cutting off. Use it in place of `.lineLimit(1)` + `.minimumScaleFactor`.
enum LineLimit {
    nonisolated static func lines(_ normal: Int, accessibility: Bool) -> Int? { accessibility ? nil : normal }
}

private struct WrapsAtAccessibilitySizes: ViewModifier {
    var lines: Int
    @Environment(\.dynamicTypeSize) private var typeSize
    func body(content: Content) -> some View {
        content.lineLimit(LineLimit.lines(lines, accessibility: typeSize.isAccessibilitySize))
    }
}

extension View {
    func wrapsAtAccessibilitySizes(lines: Int = 1) -> some View { modifier(WrapsAtAccessibilitySizes(lines: lines)) }
}

/// A display size that follows the text size up to `cap` times its base, so a big number grows but a
/// short token still fits on one line at the largest sizes.
enum ScaledSize {
    nonisolated static func capped(_ scaled: CGFloat, base: CGFloat, cap: CGFloat) -> CGFloat { min(scaled, base * cap) }
}

/// Small uppercase caption above a value: "FROM", "DISTANCE", "JOIN CODE".
struct StatCaption: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.6)
            .foregroundStyle(.secondary)
    }
}

/// "KL → Ipoh" in big rounded type. Shows only the destination until the start is known.
struct RouteEnds: View {
    var from: String?
    var to: String
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: Spacing.gap) {
            if let from {
                Text(from)
                Image(systemName: "arrow.right")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(to)
        }
        .font(.system(size: size, weight: .bold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(from.map { "From \($0) to \(to)" } ?? "To \(to)")
    }
}

/// Three (or so) captioned values side by side, divided by hairlines: DISTANCE | DRIVE | VIA.
struct StatGrid: View {
    struct Item: Identifiable {
        var caption: String
        /// Nil shows a dash.
        var value: String?
        var color: Color?
        /// A small line under the value ("18 km · 12 min").
        var detail: String?
        /// Makes the cell a button.
        var action: (() -> Void)?
        var id: String { caption }

        init(_ caption: String, _ value: String?, color: Color? = nil, detail: String? = nil, action: (() -> Void)? = nil) {
            self.action = action
            self.caption = caption
            self.value = value
            self.color = color
            self.detail = detail
        }
    }

    var items: [Item]
    var background: Color
    var valueSize: CGFloat = 17
    @ScaledMetric private var scaledValue: CGFloat

    init(_ items: [Item], background: Color, valueSize: CGFloat = 17) {
        self.items = items
        self.background = background
        self.valueSize = valueSize
        _scaledValue = ScaledMetric(wrappedValue: valueSize, relativeTo: .title3)
    }

    private var scaledValueSize: CGFloat { ScaledSize.capped(scaledValue, base: valueSize, cap: 1.6) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().frame(height: 28)
                }
                cell(item)
            }
        }
        .padding(.vertical, Spacing.s)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
    }

    @ViewBuilder private func cell(_ item: Item) -> some View {
        if let action = item.action {
            Button(action: action) { content(item) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("stat.\(item.caption)")
                .accessibilityAddTraits(.isButton)
        } else {
            content(item)
        }
    }

    private func content(_ item: Item) -> some View {
        VStack(spacing: 0) {
            StatCaption(item.caption)
            Text(item.value ?? "–")
                .font(.system(size: scaledValueSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .wrapsAtAccessibilitySizes()
                .minimumScaleFactor(0.7)
                .foregroundStyle(item.color ?? (item.value == nil ? Color.secondary : Color.primary))
            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .wrapsAtAccessibilitySizes()
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Color.surfaceSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Capsule status with a pulsing dot: "Gathering", "On the move".
struct StatusPill: View {
    var text: String
    var color: Color
    var dot: Color
    var background: AnyShapeStyle = AnyShapeStyle(.regularMaterial)

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(dot)
                .symbolEffect(.pulse, options: .repeating)
        }
        .labelStyle(PillLabelStyle())
        .font(.footnote.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, Spacing.gap)
        .padding(.vertical, 5)
        .background(background, in: Capsule())
    }

    private struct PillLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: Spacing.tight) {
                configuration.icon
                configuration.title
            }
        }
    }
}

/// Vertical dashed rule, like a ticket's tear line.
struct DashedDivider: View {
    var body: some View {
        Line()
            .stroke(Color(.systemGray5), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .frame(width: 2)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            }
        }
    }
}

#Preview {
    VStack(spacing: Spacing.xl) {
        VStack(spacing: Spacing.xs) {
            StatCaption("Join code")
            RouteEnds(from: "KL", to: "Ipoh")
            RouteEnds(from: nil, to: "Ipoh", size: 22)
        }
        StatGrid([
            .init("Distance", "205 km"),
            .init("Drive", "2 h 10 min"),
            .init("Via", nil),
        ], background: Color(.secondarySystemBackground))
        StatGrid([
            .init("Spread", "8.2 km", color: .ikutWarning),
            .init("Lead", "96 km/h"),
            .init("Cars", "5"),
        ], background: Color(.secondarySystemBackground), valueSize: 15)
        HStack(spacing: Spacing.gap) {
            StatusPill(text: "Gathering", color: .ikutWarning, dot: .orange)
            StatusPill(text: "On the move", color: .ikutPositive, dot: .green)
        }
        HStack(spacing: Spacing.l) {
            Text("Ticket")
            DashedDivider().frame(height: 60)
            Text("Stub")
        }
    }
    .padding(Spacing.l)
}
