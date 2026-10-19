import SwiftUI

/// The floating glass panel at the bottom of the map (Map.dc.html): FROM and TO with the arrival
/// time, a progress bar with every car and hazard on the route, spread / lead speed / next stop,
/// one row per car (joining cars last, with dashed badges), then Report and Pit stop. Tap or drag
/// the grabber to collapse it to FROM/TO and the buttons.
///
/// A custom overlay rather than a `.sheet`: a sheet that is always up would stop the map from
/// presenting the report sheet, and the mock's inset glass card is what this matches.
struct ConvoyPanel: View {
    var model: TripMapModel
    @Binding var expanded: Bool
    var canReport: Bool
    /// The pinned place of the open stop request, for NEXT STOP.
    var nextStop: StopPlace?
    var onReport: () -> Void
    var onStop: () -> Void

    @State private var listHeight: CGFloat = 0
    @State private var originName: String?

    private var convoy: ConvoyModel { model.convoy }
    private let maxListHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            if expanded {
                progress
                stats
                list
            }
            buttons
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 38, style: .continuous))
        // While the list collapses (e.g. a stop card slides in above), the outgoing rows would
        // otherwise draw outside the shrinking panel and over the card.
        .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .animation(.snappy, value: expanded)
        .task(id: originKey) {
            guard let start = model.mainRoute?.coordinates.first else { return }
            originName = await RouteBuilder.placeName(at: start)
        }
    }

    // MARK: Derived values

    private var originKey: String {
        guard let c = model.mainRoute?.coordinates.first else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }

    private var routeLength: Double? {
        guard let length = model.mainRoute?.length, length > 0 else { return nil }
        return length
    }

    /// One size for both ends so a long town name doesn't leave the other end looking bigger.
    private var endSize: CGFloat {
        let longest = max(originName?.count ?? 0, convoy.destinationName?.count ?? 0)
        return longest > 9 ? 22 : 28
    }

    private var frontArrival: Date? {
        guard let reference = convoy.snapshot.etaReference else { return nil }
        return convoy.arrival(forCar: reference.id)
    }

    /// "On the move" while the front car is driving, "Stopped" once it isn't, "Waiting" with no cars.
    private var motion: (text: String, color: Color, dot: Color) {
        guard let front = convoy.snapshot.etaReference else {
            return ("Waiting", Color.ikutWarning, .orange)
        }
        return front.speed > 3
            ? ("On the move", Color.ikutPositive, .green)
            : ("Stopped", Color.ikutWarning, .orange)
    }

    // MARK: Pieces

    private var grabber: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .gesture(
                DragGesture(minimumDistance: 12).onEnded { drag in
                    if drag.translation.height > 20 { expanded = false }
                    if drag.translation.height < -20 { expanded = true }
                })
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse convoy list" : "Expand convoy list")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expanded.toggle() }
    }

    private var header: some View {
        let motion = motion
        let destination = convoy.destinationName ?? ""
        let arrive = frontArrival.map { ConvoyFormat.clock($0) }
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                StatCaption("From")
                Text(originName ?? "Start")
                    .font(.system(size: endSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusPill(text: motion.text, color: motion.color, dot: motion.dot,
                       background: AnyShapeStyle(motion.dot.opacity(0.14)))
                .fixedSize()
                .padding(.top, 14)
            VStack(alignment: .trailing, spacing: 0) {
                StatCaption("To")
                Text(destination)
                    .font(.system(size: endSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let arrive {
                    Text("Arrive \(Text(arrive).foregroundStyle(Color.ikutPositive).fontWeight(.semibold))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel(destination: destination, arrive: arrive, motion: motion.text))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("convoy.header")
    }

    /// Starts with "3 in Convoy" (UI tests read it), then the route, motion and arrival.
    private func headerLabel(destination: String, arrive: String?, motion: String) -> String {
        var parts = [convoy.title]
        if let originName { parts.append("from \(originName) to \(destination)") } else { parts.append("to \(destination)") }
        parts.append(motion)
        if let arrive { parts.append("arrive \(arrive)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var progress: some View {
        if let length = routeLength, let front = convoy.snapshot.front {
            let driven = min(max(front.convoyOffset, 0), length)
            ConvoyProgressBar(
                fraction: driven / length,
                cars: convoy.convoy.reversed().map { (min(max($0.convoyOffset / length, 0), 1), $0.car.color) },
                hazards: model.hazards.markers.compactMap { $0.mainOffset.map { min(max($0 / length, 0), 1) } }
            )
            .padding(.horizontal, 4)
            .padding(.top, 10)
            .accessibilityElement()
            .accessibilityLabel("Convoy progress: \(ConvoyFormat.distance(driven)) of \(ConvoyFormat.distance(length))")

            HStack {
                Text("\(ConvoyFormat.distance(driven)) driven")
                Spacer()
                Text(toGo(remaining: length - driven))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .padding(.horizontal, 4)
        }
    }

    /// "63 km · 41 min to go", or just the distance before an ETA arrives.
    private func toGo(remaining: Double) -> String {
        guard let arrival = frontArrival else { return "\(ConvoyFormat.distance(remaining)) to go" }
        return "\(ConvoyFormat.distance(remaining)) · \(ConvoyFormat.duration(arrival.timeIntervalSinceNow)) to go"
    }

    private var stats: some View {
        let lead = convoy.snapshot.lead ?? convoy.snapshot.front
        return StatGrid([
            .init("Spread", convoy.snapshot.spread.map(ConvoyFormat.distance),
                  color: model.separationWarning == nil ? nil : MapPalette.warning),
            .init("Lead", lead.map { ConvoyFormat.speed(metersPerSecond: $0.speed) }),
            .init("Next stop", nextStop?.name ?? "None", color: nextStop == nil ? .secondary : nil),
        ], background: Color(.tertiarySystemFill), valueSize: 20)
        .padding(.top, 14)
    }

    private var list: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ListHeightKey.self, value: proxy.size.height)
                    })
        }
        .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
        .frame(height: min(max(listHeight, 0), maxListHeight))
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .padding(.top, 6)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let warning = model.separationWarning {
                separation(warning)
            }
            if convoy.convoy.isEmpty && convoy.joining.isEmpty {
                Text("Waiting for cars to share their location")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            ForEach(Array(convoy.convoyRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 44) }
                ConvoyRowView(row: row)
            }
            // Joining cars follow in the same list; their dashed badges set them apart.
            ForEach(Array(convoy.joiningRows.enumerated()), id: \.element.id) { index, row in
                if index > 0 || !convoy.convoyRows.isEmpty { Divider().padding(.leading, 44) }
                JoiningRowView(row: row)
            }
        }
    }

    private func separation(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(MapPalette.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(MapPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 6)
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onReport) {
                Label("Report", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(.white)
                    .background(MapPalette.accent.opacity(canReport ? 1 : 0.4), in: Capsule())
            }
            .disabled(!canReport)
            Button(action: onStop) {
                // "Pit stop" with a map pin, as in Map.dc.html: a bare "Stop" read as "Stop Trip".
                Label("Pit stop", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .frame(width: 146, height: 50)
                .foregroundStyle(.primary)
                .background(Color(.systemGray5).opacity(0.7), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
    }
}

/// Route progress: the driven part in the accent, a yellow dot per hazard and a dot per car in its
/// color. Fractions are 0...1 along the main route; cars are drawn back to front.
private struct ConvoyProgressBar: View {
    var fraction: Double
    var cars: [(Double, String)]
    var hazards: [Double]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5)).frame(height: 4)
                Capsule().fill(MapPalette.accent).frame(width: max(4, w * fraction), height: 4)
                ForEach(Array(hazards.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .fill(Color.yellow)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: w * f, y: 15)
                }
                ForEach(Array(cars.enumerated()), id: \.offset) { _, car in
                    Circle()
                        .fill(Color(mapHex: car.1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .position(x: w * car.0, y: 15)
                }
            }
            .frame(height: 30)
        }
        .frame(height: 30)
    }
}

private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Rows

private struct RowBadge: View {
    var number: Int?
    var colorHex: String
    var dashed = false

    var body: some View {
        let color = Color(mapHex: colorHex)
        Text(number.map(String.init) ?? "·")
            .font(.system(.subheadline, design: .rounded).weight(.bold))
            .foregroundStyle(dashed ? color : .white)
            .frame(width: 30, height: 30)
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

    var body: some View {
        HStack(spacing: 12) {
            RowBadge(number: row.number, colorHex: row.color)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.body).lineLimit(1)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.isSeparated ? MapPalette.warning : Color.primary)
                Text(row.trailingSecondary)
                    .font(.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 4)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("convoy.row.\(row.number.map(String.init) ?? row.id)")
    }
}

struct JoiningRowView: View {
    var row: JoiningRowText

    var body: some View {
        HStack(spacing: 12) {
            RowBadge(number: row.number, colorHex: row.color, dashed: true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.body).lineLimit(1)
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary).font(.body.weight(.semibold)).monospacedDigit()
                Text(row.trailingSecondary).font(.footnote).foregroundStyle(Color(.secondaryLabel))
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 4)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("joining.row.\(row.number.map(String.init) ?? row.id)")
    }
}
