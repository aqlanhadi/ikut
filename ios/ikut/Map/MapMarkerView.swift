import SwiftUI

// MARK: - Markers

/// A numbered badge in the car's color, an arrow showing the heading, and the car's name beside it.
/// Stale cars are dimmed and say how long ago they were seen; the designated lead has a small star.
struct MapMarkerView: View {
    var marker: MapMarker
    var cameraHeading: Double
    /// Width of the map, so the chip can flip to the left near the right edge.
    var containerWidth: CGFloat = 0
    /// The driver tapped this car: a ring in the accent around the badge.

    @State private var markerX: CGFloat?
    @State private var chipWidth: CGFloat = 120
    /// What the text size does to a point; the marker's circle, wedge and glyphs all grow by it, up to
    /// `MarkerMetrics.maxGrowth`.
    @ScaledMetric(relativeTo: .subheadline) private var textScale: CGFloat = 1
    private var scale: CGFloat { MarkerMetrics.scale(textScale) }
    private var badge: CGFloat { 32 * scale }
    private var frameSize: CGFloat { 58 * scale }

    var body: some View {
        ZStack {
            ZStack {
                if let heading = marker.heading {
                    Wedge()
                        .fill(Color.car(hex: marker.colorHex))
                        .overlay(Wedge().stroke(.white, lineWidth: 1.5))
                        .frame(width: 14 * scale, height: 10 * scale)
                        .frame(width: frameSize, height: frameSize, alignment: .top)
                        .rotationEffect(.degrees(MapMarkerBuilder.rotation(heading: heading, cameraHeading: cameraHeading)))
                }
                Text(marker.number.map(String.init) ?? "·")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.7)
                    .frame(width: badge, height: badge)
                    .background(Color.car(hex: marker.colorHex), in: Circle())
                    .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    .elevation(.marker)
                    .overlay(alignment: .bottomTrailing) {
                        if marker.hasArrived {
                            glyph("checkmark", weight: .heavy, size: 15, fill: Color.ikutPositive, ring: 1.5)
                                .offset(x: 5 * scale, y: 5 * scale)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if marker.isLead {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8 * scale, weight: .bold))
                                .foregroundStyle(Color.ikutLeadYellow)
                                .frame(width: 14 * scale, height: 14 * scale)
                                .background(.white, in: Circle())
                                .offset(x: 5 * scale, y: -5 * scale)
                        }
                    }
            }
            .opacity(marker.isStale ? 0.6 : 1)
            // A small clock on a car that has gone quiet, at full strength, so stale reads without the fade.
            .overlay(alignment: .bottomLeading) {
                if MarkerMetrics.showsStaleBadge(marker) {
                    glyph("clock.fill", weight: .bold, size: 15, fill: MapColors.staleBadge.color, ring: 1.5)
                        .padding(.leading, (frameSize - badge) / 2 - 5 * scale)
                        .padding(.bottom, (frameSize - badge) / 2 - 5 * scale)
                }
            }
        }
        .frame(width: frameSize, height: frameSize)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { markerX = $0 }
        .overlay(alignment: side == .trailing ? .leading : .trailing) {
            HStack(spacing: Spacing.xs) {
                Text(marker.label)
                if marker.isMine { YouTag(online: marker.youOnline) }
            }
                .font(.caption.weight(.semibold))
                .foregroundStyle(marker.isPaused ? Color.secondary : (marker.isStale ? Color.ikutStaleChipText : Color.primary))
                .lineLimit(1)
                .fixedSize()
                // No capsule: a halo in the background colour, as on Apple's own map labels, keeps it readable.
                .shadow(color: Color(.systemBackground), radius: 1)
                .shadow(color: Color(.systemBackground), radius: 1)
                .shadow(color: Color(.systemBackground).opacity(0.6), radius: 3)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                .padding(side == .trailing ? .leading : .trailing, MapChipPlacement.gap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var side: MapChipPlacement.Side {
        MapChipPlacement.side(markerX: markerX, chipWidth: chipWidth, containerWidth: containerWidth)
    }

    /// A white glyph in a small filled circle with a white ring (the arrived tick, the stale clock).
    private func glyph(_ symbol: String, weight: Font.Weight, size: CGFloat, fill: Color, ring: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 8 * scale, weight: weight))
            .foregroundStyle(.white)
            .frame(width: size * scale, height: size * scale)
            .background(fill, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: ring))
    }

    private var accessibilityText: String {
        var text = marker.name
        if marker.isMine { text += ", " + YouOnline.spoken(online: marker.youOnline) }
        if marker.hasArrived { text += ", arrived" }
        if marker.isLead { text += ", lead" }
        if marker.isJoining { text += ", joining" }
        if marker.isPaused {
            text += ", sharing paused"
        } else if marker.isStale, let age = marker.ageText {
            text += ", last seen \(age)"
        }
        return text
    }
}

private struct Wedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// White dot with the joining car's color where its route meets the main route; the label hangs
/// off to the side so the dot stays on the coordinate. The label is dark-on-material with the
/// car's color as its outline, so it reads in light and dark mode.
struct MergePointView: View {
    var colorHex: String
    var containerWidth: CGFloat = 0

    @State private var dotX: CGFloat?
    @State private var chipWidth: CGFloat = 70

    private var side: MapChipPlacement.Side {
        // The dot is 18 wide, so its chip sits closer than a marker's.
        MapChipPlacement.side(markerX: dotX.map { $0 - 16 }, chipWidth: chipWidth, containerWidth: containerWidth)
    }

    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.car(hex: colorHex), lineWidth: 3))
            .frame(width: 18, height: 18)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { dotX = $0 }
            .overlay(alignment: side == .trailing ? .leading : .trailing) {
                Text("Join point")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .padding(.horizontal, Spacing.chipX)
                    .padding(.vertical, Spacing.xs)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.car(hex: colorHex), lineWidth: 1.5))
                    .elevation(.label)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                    .padding(side == .trailing ? .leading : .trailing, Spacing.xl)
            }
    }
}

#Preview("Markers") {
    func marker(_ id: String, _ number: Int?, _ name: String, _ color: String, heading: Double? = 20,
                stale: Bool = false, age: String? = nil, lead: Bool = false, joining: Bool = false,
                mine: Bool = false, paused: Bool = false, arrived: Bool = false) -> MapMarker {
        MapMarker(
            id: id, number: number, name: name, colorHex: color, coordinate: MapCoordinate(latitude: 4.2, longitude: 101.26),
            heading: heading, isStale: stale, ageText: age, isLead: lead, isJoining: joining, isMine: mine,
            isPaused: paused, hasArrived: arrived)
    }
    let markers = [
        marker("c1", 1, "Aqlan’s Myvi", "#2563EB", lead: true, mine: true),
        marker("c2", 2, "Wyna’s X70", "#D9480F", heading: 200),
        marker("c3", 3, "Hafiz’s Hilux", "#0F766E", heading: 90, joining: true),
        marker("c4", 4, "Daniel’s City", "#7C3AED", stale: true, age: "2 min ago"),
        marker("c5", 5, "Siti’s Bezza", "#CA8A04", heading: nil, stale: true, paused: true),
        marker("c6", 6, "Aisha’s Ativa", "#0891B2", heading: nil, arrived: true),
        marker("c7", nil, "Old car", "#8E8E93", heading: nil),
    ]
    return VStack(alignment: .leading, spacing: Spacing.l) {
        ForEach(markers) { MapMarkerView(marker: $0, cameraHeading: 0, containerWidth: 390) }
        MergePointView(colorHex: "#0F766E", containerWidth: 390)
            .frame(width: 58)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(.systemGray5))
}

#Preview("Mode control") {
    HStack(spacing: Spacing.xl) {
        MapModeControl(mode: .constant(.follow))
        MapModeControl(mode: .constant(.fit))
        MapModeControl(mode: .constant(.free))
    }
    .padding(Spacing.xl)
    .background(Color(.systemGray5))
}
