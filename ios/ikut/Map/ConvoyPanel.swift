import CoreLocation
import SwiftUI

/// What Apple's own sheet at the bottom of the map holds (Map.dc.html): FROM and TO with the arrival
/// time, a progress bar with every car and hazard on the route, spread / lead speed,
/// one row per car (joining cars last, with dashed badges), then Report and Pit stop. Folded (the
/// short detent) it is FROM/TO, progress, a one-line summary and the buttons; a tap on the header
/// or the handle, or a drag of the sheet, unfolds it (the tall detent).
///
/// The sheet (`TripMapView`, `PanelSheet`) is the surface and owns the sizes: this view only reports
/// its own height (`onHeight`) so the detents follow it. The alerts the panel's buttons lead to are
/// presented from the sheet, since a presented sheet blocks a presentation from the map under it.
struct ConvoyPanel: View {
    var model: TripMapModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var expanded: Bool
    var canReport: Bool
    /// What the Pit stop button says: "Pit stop", or the open stop ("Fuel · 2 of 4 OK") with a badge.
    var stopButton = StopLogic.ButtonContent(
        label: "Pit stop", symbol: "mappin.and.ellipse", badge: 0, accessibilityLabel: "Pit stop")
    var onReport: () -> Void
    var onStop: () -> Void
    /// Tapping the Next stop cell: opens that stop's card (D25 piece 3b).
    var onNextStop: (String) -> Void = { _ in }
    /// The panel's own height as laid out (folded or unfolded), for the sheet's detents.
    var onHeight: (CGFloat) -> Void = { _ in }

    @State private var listHeight: CGFloat = 0
    @State private var originName: String?
    @State private var ownStartName: String?
    @State private var joinPlaceName: String?
    @State private var ownStart: CLLocationCoordinate2D?
    @State private var ownJoin: OwnWayJoin?
    @State private var joinCoordinate: CLLocationCoordinate2D?

    private var convoy: ConvoyModel { model.convoy }
    private let maxListHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            handle
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
        .padding(.bottom, Spacing.l)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
        .task(id: originKey) {
            guard let start = model.mainRoute?.coordinates.first else { return }
            originName = await RouteBuilder.placeName(at: start)
        }
        .task(id: ownInputs) {
            // Once per change of my car's route, merge offset, state or the main route, not per refresh.
            let main = model.mainRoute
            ownStart = OwnWayLogic.start(car: model.myCar, phone: nil)
            if model.myCar?.state == .joining, let main {
                ownJoin = OwnWayLogic.join(car: model.myCar, main: main)?.join
                joinCoordinate = OwnWayLogic.joinCoordinate(ownJoin, main: main)
            } else {
                ownJoin = nil
                joinCoordinate = nil
            }
        }
        .task(id: coordinateKey(ownStart)) {
            ownStartName = nil
            guard let start = ownStart else { return }
            ownStartName = await RouteBuilder.placeName(at: start)
        }
        .task(id: coordinateKey(joinCoordinate)) {
            joinPlaceName = nil
            guard let at = joinCoordinate else { return }
            joinPlaceName = await RouteBuilder.placeName(at: at)
        }
    }

    // MARK: Derived values

    private var originKey: String {
        guard let c = model.mainRoute?.coordinates.first else { return "" }
        return "\(c.latitude),\(c.longitude)"
    }

    private var ownInputs: String {
        let car = model.myCar
        return "\(car?.route ?? "-")|\(car?.mergeOffset.map { String($0) } ?? "-")|\(car?.state.rawValue ?? "-")|\(model.mainRoute?.length ?? 0)"
    }

    private func coordinateKey(_ c: CLLocationCoordinate2D?) -> String {
        c.map { "\($0.latitude),\($0.longitude)" } ?? ""
    }

    private var myJoining: JoiningEntry? { convoy.joining.first(where: { $0.id == model.myCarId }) }

    /// My own trip's words: start town, and the joining line while my car is joining.
    private var headerText: ConvoyHeader.Text {
        convoy.headerText(
            car: model.myCar, join: ownJoin,
            ownStartTown: ownStartName.map(ConvoyFormat.placeShortName), mainStartTown: originShort,
            joinPlace: joinPlaceName.map(ConvoyFormat.placeShortName), destination: destinationShort)
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

    /// The strip under the sheet's own drag indicator: a tap on it folds or unfolds the list, and it is the
    /// button VoiceOver and the UI tests find ("Expand convoy list").
    private var handle: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: BottomSheet.indicatorRoom)
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            .accessibilityElement()
            .accessibilityLabel(expanded ? "Collapse convoy list" : "Expand convoy list")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { expanded.toggle() }
    }

    private var header: some View {
        let destination = convoy.destinationName ?? ""
        let arrive = frontArrival.map { ConvoyFormat.clock($0) }
        let text = headerText
        return HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                StatCaption("From")
                Text(text.from)
                    .font(.system(size: endSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let joinLine = text.joinLine {
                    Text(joinLine)
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
                        .monospacedDigit()
                        .lineLimit(2)
                } else if let departed = model.departedAt {
                    Text("Left \(ConvoyFormat.clock(departed))")
                        .font(.footnote)
                        .foregroundStyle(Color.surfaceSecondary)
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
                        .foregroundStyle(Color.surfaceSecondary)
                        .monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.top, Spacing.xs)
        .contentShape(Rectangle())
        .onTapGesture { expanded.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConvoyHeader.label(title: convoy.title, text: text, destination: destination, arrive: arrive))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("convoy.header")
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
            .foregroundStyle(Color.surfaceSecondary)
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

    private var nextStopCell: NextStop.Cell? {
        if let mine = myEntry { return NextStop.cell(stops: model.stops, offset: mine.convoyOffset, pace: model.stopPace(), now: Date()) }
        // Still joining: the meeting point, how far my own way in has to go; after Leave, or my own "meet you along
        // the way", the next open stop ahead of where my road meets the main route.
        guard let mine = convoy.joining.first(where: { $0.id == model.myCarId }) else { return nil }
        return NextStop.joiningCell(
            stops: model.stops, distance: mine.distanceToMerge, seconds: mine.timeToMerge,
            mergeOffset: mine.car.mergeOffset, pace: model.joiningStopPace(), skipsMeet: model.skipsMeetingPoint)
    }

    private var myEntry: ConvoyEntry? { convoy.convoy.first(where: { $0.id == model.myCarId }) }

    /// Collapsed only (MapCollapsed.dc.html): overlapping car dots (dashed for joining cars), then
    /// "3 cars driving · Hafiz joins in 18 min · 6.4 km spread" and a chevron. Tapping expands.
    private var summary: some View {
        let parts = convoy.summaryParts(myCarId: model.myCarId)
        let warn = model.separationWarning != nil
        var text = Text(parts.driving).fontWeight(.semibold)
        if let joining = parts.joining { text = text + Text(" · \(joining)") }
        if let spread = parts.spread {
            text = text + Text(" · ") + Text(spread.replacingOccurrences(of: " km", with: "\u{00A0}km"))
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
                    .foregroundStyle(Color.surfaceSecondary)
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
        var items: [StatGrid.Item] = [
            .init("Spread", convoy.snapshot.spread.map(ConvoyFormat.distance),
                  color: model.separationWarning == nil ? nil : MapPalette.warning),
            .init("Lead", lead.map { ConvoyFormat.speed(metersPerSecond: $0.speed) }),
        ]
        // Planned stops (D25): no stop ahead, no cell. Tapping the cell opens that stop's card.
        if let cell = nextStopCell {
            items.append(.init("Next stop", cell.name, detail: cell.detail, action: cell.stopId.map { id in { onNextStop(id) } }))
        }
        return StatGrid(items, background: Color(.tertiarySystemFill), valueSize: 20)
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
                    .foregroundStyle(Color.surfaceSecondary)
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
            .accessibilityIdentifier("convoy.separation")
    }

    private var buttons: some View {
        // At accessibility sizes Report and Pit stop take a row each; otherwise they share one.
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: Spacing.gap)) : AnyLayout(HStackLayout(spacing: Spacing.gap))
        return layout {
            Button(action: onReport) {
                Label("Report", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .surfaceButton(
                .primary, tint: MapPalette.accent, fill: MapPalette.accent.opacity(canReport ? 1 : 0.4),
                foreground: .white)
            .disabled(!canReport)
            Button(action: onStop) {
                // "Pit stop" with a map pin, as in Map.dc.html: a bare "Stop" read as "Stop Trip".
                // An open stop shows its reason's icon and how it stands; the label never wraps, the
                // button widens over Report instead.
                Label(stopButton.label, systemImage: stopButton.symbol)
                    .font(.headline)
                    .lineLimit(stacked ? 2 : 1)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: !stacked, vertical: false)
                    .padding(.horizontal, Spacing.l)
                    .frame(minWidth: stacked ? nil : 146, maxWidth: stacked ? .infinity : nil, minHeight: 50)
                    .overlay(alignment: .topTrailing) {
                        if stopButton.badge > 0 {
                            Text("\(stopButton.badge)")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(Color.red, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color(.systemBackground), lineWidth: 2))
                                .offset(x: 6, y: -6)
                                .accessibilityHidden(true)
                                .accessibilityIdentifier("stop.badge")
                        }
                    }
            }
            .surfaceButton(.secondary, fill: Color(.systemGray5).opacity(0.7), foreground: .primary)
            .layoutPriority(1)
            .accessibilityLabel(stopButton.accessibilityLabel)
            .accessibilityIdentifier("stop.button")
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
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color.surfaceSecondary)
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
                        .foregroundStyle(Color.surfaceSecondary)
                }
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? Color.staleRowOpacity : 1)
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
                    .foregroundStyle(row.subtitleIsWarning ? MapPalette.staleChipText : Color.surfaceSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(row.trailingPrimary).font(.body.weight(.semibold)).monospacedDigit()
                Text(row.trailingSecondary).font(.footnote).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, Spacing.xs)
        .opacity(row.isStale ? Color.staleRowOpacity : 1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("joining.row.\(row.number.map(String.init) ?? row.id)")
    }
}

#if DEBUG
#Preview("Panel") {
    @Previewable @State var expanded = true
    ZStack(alignment: .bottom) {
        Color(.systemGray4).ignoresSafeArea()
        ConvoyPanel(model: MapDemo.model(), expanded: $expanded, canReport: true, onReport: {}, onStop: {}).previewCard()
    }
}

#Preview("Panel collapsed") {
    ZStack(alignment: .bottom) {
        Color(.systemGray4).ignoresSafeArea()
        ConvoyPanel(model: MapDemo.model(), expanded: .constant(false), canReport: false, onReport: {}, onStop: {}).previewCard()
    }
}

extension View {
    /// The panel as a card on a plain background, for previews and the small demos that show only its words.
    func previewCard() -> some View {
        glassSurface().padding(.horizontal, Spacing.s).padding(.bottom, Spacing.s)
    }
}
#endif

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
        row("c1", 1, "#2563EB", ConvoyFormat.me, subtitle: "Lead · " + ConvoyFormat.speed(metersPerSecond: 96 / 3.6),
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
            trailingPrimary: ConvoyFormat.duration(1_080), trailingSecondary: "to merge", isStale: false),
        JoiningRowText(
            id: "c8", number: 8, name: "Rina’s Persona", color: "#65A30D",
            subtitle: ConvoyFormat.lastSeen(age: 300), subtitleIsWarning: true,
            trailingPrimary: "--", trailingSecondary: "to merge", isStale: true),
        JoiningRowText(
            id: "c9", number: nil, name: ConvoyFormat.me, color: "#2563EB",
            subtitle: "Waiting for location", subtitleIsWarning: false,
            trailingPrimary: "--", trailingSecondary: "to merge", isStale: false),
    ]
    return ScrollView {
        VStack(spacing: 0) {
            ForEach(rows) { ConvoyRowView(row: $0) }
            Divider().padding(.vertical, Spacing.s)
            ForEach(joining) { JoiningRowView(row: $0) }
        }
        .padding(Spacing.l)
    }
}
