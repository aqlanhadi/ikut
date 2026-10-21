import SwiftUI

/// The floating glass panel at the bottom of the map (Map.dc.html): FROM and TO with the arrival
/// time, a progress bar with every car and hazard on the route, spread / lead speed / next stop,
/// one row per car (joining cars last, with dashed badges), then Report and Pit stop. Tap or drag
/// the grabber to collapse it to FROM/TO, progress, a one-line summary and the buttons.
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
            progress
            if !expanded {
                summary
            }
            if expanded {
                stats
                list
            }
            buttons
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.tight)
        .padding(.bottom, Spacing.section)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        // While the list collapses (e.g. a stop card slides in above), the outgoing rows would
        // otherwise draw outside the shrinking panel and over the card.
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.s)
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

    /// One fixed size for both ends whatever their length; a long name truncates rather than shrinks.
    private let endSize: CGFloat = 30

    /// Display names: "KL" for Kuala Lumpur and other well-known short forms, else the full name.
    private var originShort: String? { originName.map(ConvoyFormat.placeShortName) }
    private var destinationShort: String { ConvoyFormat.placeShortName(convoy.destinationName ?? "") }

    private var frontArrival: Date? {
        guard let reference = convoy.snapshot.etaReference else { return nil }
        return convoy.arrival(forCar: reference.id)
    }

    private var mineArrived: Bool { convoy.snapshot.hasArrived(model.myCarId) }

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
        let destination = convoy.destinationName ?? ""
        let arrive = frontArrival.map { ConvoyFormat.clock($0) }
        return HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                StatCaption("From")
                Text(originShort ?? "Start")
                    .font(.system(size: endSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let departed = model.departedAt {
                    Text("Left \(ConvoyFormat.clock(departed))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                StatCaption("To")
                Text(destinationShort)
                    .font(.system(size: endSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let arrive, !mineArrived {
                    Text("Arrive \(Text(arrive).foregroundStyle(Color.ikutPositive).fontWeight(.semibold))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.top, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel(destination: destination, arrive: arrive))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("convoy.header")
    }

    /// Starts with "3 in Convoy" (UI tests read it), then the route and arrival. The convoy's motion
    /// is in the trip pill at the top of the map.
    private func headerLabel(destination: String, arrive: String?) -> String {
        var parts = [convoy.title]
        if let originName { parts.append("from \(originName) to \(destination)") } else { parts.append("to \(destination)") }
        if let arrive { parts.append("arrive \(arrive)") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var progress: some View {
        if let length = routeLength, let front = convoy.snapshot.front {
            // The bar and "to go" describe my trip when I'm in the convoy (the front may already be in).
            let driven = min(max((myEntry ?? front).convoyOffset, 0), length)
            ConvoyProgressBar(
                fraction: driven / length,
                cars: convoy.convoy.reversed().map {
                    (min(max($0.convoyOffset / length, 0), 1), $0.car.color, $0.id == model.myCarId)
                },
                hazards: model.hazards.markers.compactMap { $0.mainOffset.map { min(max($0 / length, 0), 1) } }
            )
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.gap)
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
            .padding(.horizontal, Spacing.xs)
        }
    }

    /// "63 km · 41 min to go", just the distance before an ETA arrives, "Arrived" once I'm in.
    private func toGo(remaining: Double) -> String {
        let subject = myEntry ?? convoy.snapshot.front
        let arrival = subject.flatMap { convoy.arrival(forCar: $0.id) } ?? frontArrival
        return ConvoyFormat.toGo(
            remaining: remaining, travelTime: arrival?.timeIntervalSinceNow, arrived: subject?.hasArrived ?? false)
    }

    private var myEntry: ConvoyEntry? { convoy.convoy.first(where: { $0.id == model.myCarId }) }

    /// Collapsed only (MapCollapsed.dc.html): overlapping car dots (dashed for joining cars), then
    /// "3 cars driving · Hafiz joins in 18 min · 6.4 km spread" and a chevron. Tapping expands.
    private var summary: some View {
        // My own joining car first ("You join in 18 min"), else the first with a merge time.
        let joiner = convoy.joining.first(where: { $0.id == model.myCarId })
            ?? convoy.joining.first(where: { $0.timeToMerge != nil }) ?? convoy.joining.first
        let parts = ConvoyFormat.convoySummary(
            driving: convoy.convoy.count, joinerName: joiner?.car.name, joinIn: joiner?.timeToMerge,
            spread: convoy.convoy.count > 1 ? convoy.snapshot.spread : nil,
            joinerIsMe: joiner != nil && joiner?.id == model.myCarId)
        let warn = model.separationWarning != nil
        var text = Text(parts.driving).fontWeight(.semibold)
        if let joining = parts.joining { text = text + Text(" · \(joining)") }
        if let spread = parts.spread {
            text = text + Text(" · ") + Text(spread)
                .foregroundStyle(warn ? MapPalette.warning : Color.primary)
                .fontWeight(warn ? .semibold : .regular)
        }
        let fill = Color(.tertiarySystemFill)
        return Button { expanded = true } label: {
            HStack(spacing: Spacing.gap) {
                HStack(spacing: -5) {
                    ForEach(convoy.convoy) { e in
                        Circle().fill(Color(mapHex: e.car.color))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color(.systemBackground).opacity(0.8), lineWidth: 2))
                    }
                    ForEach(convoy.joining) { e in
                        Circle().fill(Color.white)
                            .overlay(Circle().strokeBorder(Color(mapHex: e.car.color),
                                                           style: StrokeStyle(lineWidth: 2, dash: [2.5, 2])))
                            .frame(width: 14, height: 14)
                    }
                }
                .fixedSize()
                text
                    .font(.footnote)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.cozy)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.gap)
        .accessibilityLabel([parts.driving, parts.joining, parts.spread].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint("Shows the convoy list")
        .accessibilityIdentifier("convoy.summary")
    }

    private var stats: some View {
        let lead = convoy.snapshot.lead ?? convoy.snapshot.front
        return StatGrid([
            .init("Spread", convoy.snapshot.spread.map(ConvoyFormat.distance),
                  color: model.separationWarning == nil ? nil : MapPalette.warning),
            .init("Lead", lead.map { ConvoyFormat.speed(metersPerSecond: $0.speed) }),
            .init("Next stop", nextStop?.name ?? "None", color: nextStop == nil ? .secondary : nil),
        ], background: Color(.tertiarySystemFill), valueSize: 20)
        .padding(.top, Spacing.cozy)
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
        .padding(.top, Spacing.tight)
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
            ForEach(Array(convoy.convoyRows(myCarId: model.myCarId).enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 44) }
                ConvoyRowView(row: row)
            }
            // Joining cars follow in the same list; their dashed badges set them apart.
            ForEach(Array(convoy.joiningRows(myCarId: model.myCarId).enumerated()), id: \.element.id) { index, row in
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
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
            .background(MapPalette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.bottom, Spacing.tight)
    }

    private var buttons: some View {
        HStack(spacing: Spacing.gap) {
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
        .padding(.top, Spacing.m)
    }
}

/// Route progress: the driven part in the accent, a yellow dot per hazard and a dot per car in its
/// color. Fractions are 0...1 along the main route; cars are drawn back to front.
private struct ConvoyProgressBar: View {
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
                Capsule().fill(MapPalette.accent).frame(width: max(4, w * fraction), height: 4)
                ForEach(Array(hazards.enumerated()), id: \.offset) { _, f in
                    Circle()
                        .fill(Color.yellow)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(x: min(max(w * f, 6), w - 6), y: 15)
                }
                ForEach(Array(cars.enumerated()), id: \.offset) { _, car in
                    Circle()
                        .fill(Color(mapHex: car.1))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .overlay {
                            if car.2 { Circle().strokeBorder(MapPalette.accent, lineWidth: 2).padding(-2) }
                        }
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                        .position(x: min(max(w * car.0, 9), w - 9), y: 15)
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
        HStack(spacing: Spacing.m) {
            RowBadge(number: row.number, colorHex: row.color)
            VStack(alignment: .leading, spacing: 0) {
                if row.isMine {
                    MeCapsule()
                } else {
                    Text(row.name).font(.body).lineLimit(1)
                }
                Text(row.subtitle)
                    .font(.footnote)
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color(.secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.hasArrived {
                Label(row.trailingPrimary, systemImage: "checkmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ikutPositive)
                    .padding(.horizontal, Spacing.gap)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.14), in: Capsule())
                    .accessibilityIdentifier("convoy.row.arrived")
            } else {
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
        }
        .frame(minHeight: 54)
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("convoy.row.\(row.number.map(String.init) ?? row.id)")
    }
}

/// "Me" in a subtle blue capsule, for my own row.
private struct MeCapsule: View {
    var body: some View {
        Text(ConvoyFormat.me)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(MapPalette.accent)
            .padding(.horizontal, Spacing.chipX)
            .padding(.vertical, Spacing.xxs)
            .background(MapPalette.accent.opacity(0.14), in: Capsule())
    }
}

struct JoiningRowView: View {
    var row: JoiningRowText

    var body: some View {
        HStack(spacing: Spacing.m) {
            RowBadge(number: row.number, colorHex: row.color, dashed: true)
            VStack(alignment: .leading, spacing: 0) {
                if row.name == ConvoyFormat.me { MeCapsule() } else { Text(row.name).font(.body).lineLimit(1) }
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
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("joining.row.\(row.number.map(String.init) ?? row.id)")
    }
}
