import SwiftUI

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
        var id: String { caption }

        init(_ caption: String, _ value: String?, color: Color? = nil) {
            self.caption = caption
            self.value = value
            self.color = color
        }
    }

    var items: [Item]
    var background: Color
    var valueSize: CGFloat = 17

    init(_ items: [Item], background: Color, valueSize: CGFloat = 17) {
        self.items = items
        self.background = background
        self.valueSize = valueSize
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().frame(height: 28)
                }
                VStack(spacing: 0) {
                    StatCaption(item.caption)
                    Text(item.value ?? "–")
                        .font(.system(size: valueSize, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(item.color ?? (item.value == nil ? Color.secondary : Color.primary))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, Spacing.s)
        .background(background, in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
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
            .init("Next stop", "Tapah"),
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
