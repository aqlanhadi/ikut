import SwiftUI

/// Route progress: the driven part in the accent, a yellow dot per hazard and a dot per car in its
/// color. Fractions are 0...1 along the main route; cars are drawn back to front.
struct ConvoyProgressBar: View {
    var fraction: Double
    /// Fraction, color hex, mine (drawn with a blue ring).
    var cars: [(Double, String, Bool)]
    var hazards: [Double]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                // systemGray5 vanished on the dark glass; secondary keeps a visible track in both modes.
                Capsule().fill(Color.secondary.opacity(0.3)).frame(height: 4)
                Capsule().fill(Color.ikutAccentFill).frame(width: max(4, w * fraction), height: 4)
                ForEach(Array(hazards.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .fill(Color.yellow)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: min(max(w * f, 6), w - 6), y: 15)
                }
                ForEach(Array(cars.enumerated()), id: \.offset) { _, car in
                    Circle()
                        .fill(Color.car(hex: car.1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .overlay {
                            if car.2 { Circle().strokeBorder(Color.ikutAccentFill, lineWidth: 2).padding(-2) }
                        }
                        .frame(width: 18, height: 18)
                        .elevation(.marker)
                        .position(x: min(max(w * car.0, 9), w - 9), y: 15)
                }
            }
            .frame(height: 30)
        }
        .frame(height: 30)
    }
}

// MARK: - Rows

private struct RowBadge: View {
    var number: Int?
    var colorHex: String
    var dashed = false

    var body: some View {
        let color = Color.car(hex: colorHex)
        Text(number.map(String.init) ?? "·")
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(dashed ? color : .white)
            .iconFrame(.small)
            .background(dashed ? Color.white : color, in: Circle())
            .overlay {
                if dashed {
                    Circle().strokeBorder(color, style: StrokeStyle(lineWidth: 2.5, dash: [4, 3]))
                }
            }
            .accessibilityHidden(true)
    }
}

struct ConvoyRowView: View {
    var row: ConvoyRowText
    var youOnline = true

    var body: some View {
        HStack(spacing: Spacing.m) {
            RowBadge(number: row.number, colorHex: row.color)
            VStack(alignment: .leading, spacing: 0) {
                NameLine(name: row.name, mine: row.isMine, online: youOnline)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? Color.ikutWarning : Color.surfaceSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.hasArrived {
                Chip(text: row.trailingPrimary, tone: .positive, lead: .symbol("checkmark"))
                    .accessibilityIdentifier("convoy.row.arrived")
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(row.trailingPrimary)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(row.isSeparated ? Color.ikutWarning : Color.primary)
                    Text(row.trailingSecondary)
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
                }
            }
        }
        .ikutRow()
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? Color.staleRowOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("convoy.row.\(row.number.map(String.init) ?? row.id)")
    }
}

/// A car's name on one line; my own car gets "• You" after it. The name gives way, the tag never wraps.
private struct NameLine: View {
    var name: String
    var mine: Bool
    var online: Bool

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(name).lineLimit(1)
            if mine { YouTag(online: online).layoutPriority(1) }
        }
        .font(.body)
    }
}

struct JoiningRowView: View {
    var row: JoiningRowText
    var mine = false
    var youOnline = true

    var body: some View {
        HStack(spacing: Spacing.m) {
            RowBadge(number: row.number, colorHex: row.color, dashed: true)
            VStack(alignment: .leading, spacing: 0) {
                NameLine(name: row.name, mine: mine, online: youOnline)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? Color.ikutWarning : Color.surfaceSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary).font(.body.weight(.semibold)).monospacedDigit()
                Text(row.trailingSecondary).font(.footnote).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .ikutRow()
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? Color.staleRowOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("joining.row.\(row.number.map(String.init) ?? row.id)")
    }
}

#Preview("Rows") {
    func row(_ id: String, _ number: Int, _ color: String, _ name: String, subtitle: String, warning: Bool = false,
             _ primary: String, _ secondary: String, stale: Bool = false, separated: Bool = false,
             mine: Bool = false, arrived: Bool = false) -> ConvoyRowText {
        ConvoyRowText(
            id: id, number: number, name: name, color: color, subtitle: subtitle, subtitleIsWarning: warning,
            trailingPrimary: primary, trailingSecondary: secondary, isStale: stale, isSeparated: separated,
            isMine: mine, hasArrived: arrived)
    }
    let rows = [
        row("c1", 1, "#2563EB", "Aqlan’s car", subtitle: "Lead · " + ConvoyFormat.speed(metersPerSecond: 96 / 3.6),
            "Lead", ConvoyFormat.eta(Date().addingTimeInterval(3_000)), mine: true),
        row("c2", 2, "#D9480F", "Wyna’s X70", subtitle: ConvoyFormat.speed(metersPerSecond: 92 / 3.6),
            ConvoyFormat.distance(1_800), ConvoyFormat.behind(70)),
        row("c5", 5, "#BE185D", "Faiz’s car", subtitle: ConvoyFormat.speed(metersPerSecond: 90 / 3.6),
            ConvoyFormat.distance(8_000), ConvoyFormat.behind(330), separated: true),
        row("c4", 4, "#7C3AED", "Daniel’s City", subtitle: ConvoyFormat.lastSeen(age: 125), warning: true,
            ConvoyFormat.distance(6_400), ConvoyFormat.behind(290), stale: true),
        row("c6", 6, "#CA8A04", "Siti’s Bezza", subtitle: ConvoyFormat.paused,
            ConvoyFormat.distance(2_600), ConvoyFormat.behind(110)),
        row("c7", 7, "#0891B2", "Aisha’s Ativa", subtitle: ConvoyFormat.speed(metersPerSecond: 0),
            ConvoyFormat.arrived, "", arrived: true),
    ]
    let joining = [
        JoiningRowText(
            id: "c3", number: 3, name: "Hafiz’s Hilux", color: "#0F766E",
            subtitle: ConvoyFormat.speed(metersPerSecond: 84 / 3.6), subtitleIsWarning: false,
            trailingPrimary: ConvoyFormat.duration(1_080), trailingSecondary: "to join", isStale: false),
        JoiningRowText(
            id: "c8", number: 8, name: "Rina’s Persona", color: "#65A30D",
            subtitle: ConvoyFormat.lastSeen(age: 300), subtitleIsWarning: true,
            trailingPrimary: "--", trailingSecondary: "to join", isStale: true),
        JoiningRowText(
            id: "c9", number: nil, name: "Aqlan’s car", color: "#2563EB",
            subtitle: "Waiting for its location", subtitleIsWarning: false,
            trailingPrimary: "--", trailingSecondary: "to join", isStale: false),
    ]
    return ScrollView {
        VStack(spacing: 0) {
            ForEach(rows) { ConvoyRowView(row: $0) }
            Divider().padding(.vertical, Spacing.s)
            ForEach(joining) { JoiningRowView(row: $0, mine: $0.id == "c9", youOnline: false) }
        }
        .padding(Spacing.l)
    }
}
