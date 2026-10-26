import CoreLocation
import SwiftUI

/// What Apple's own sheet at the bottom of the map holds (Map.dc.html): FROM and TO with the arrival
/// time, a progress bar with every car and hazard on the route, spread / lead speed,
/// one row per car (joining cars last, with dashed badges). Report and Pit stop are `ConvoyActionBar`, pinned
/// under it. Folded (the short detent) it is FROM/TO, progress and a one-line summary; a tap on the header
/// or a drag of the sheet, unfolds it (the tall detent).
///
/// The sheet (`TripMapView`, `PanelSheet`) is the surface and owns the sizes: this view only reports
/// its own height (`onHeight`) so the detents follow it. The alerts the panel's buttons lead to are
/// presented from the sheet, since a presented sheet blocks a presentation from the map under it.
struct ConvoyPanel: View {
    var model: TripMapModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var expanded: Bool
    /// Tapping the Next stop cell: opens that stop's card (D25 piece 3b).
    var onNextStop: (String) -> Void = { _ in }
    /// The panel's own height as laid out (folded or unfolded), for the sheet's detents.
    var onHeight: (CGFloat) -> Void = { _ in }
    /// A hidden copy that only measures the other layout, so the sheet knows both heights before it is asked to
    /// move: it does no lookups and is not on screen or in VoiceOver.
    var probe = false
    /// The on-screen panel's header words (its place names come from lookups the probe does not make), so a probe
    /// measures the header the driver sees; and where the on-screen panel reports them.
    var headerWords: ConvoyHeader.Text?
    var onHeader: (ConvoyHeader.Text) -> Void = { _ in }

    @State private var originName: String?
    @State private var ownStartName: String?
    @State private var joinPlaceName: String?
    @State private var ownStart: CLLocationCoordinate2D?
    @State private var ownJoin: OwnWayJoin?
    @State private var joinCoordinate: CLLocationCoordinate2D?

    private var convoy: ConvoyModel { model.convoy }

    var body: some View {
        VStack(spacing: 0) {
            header
            progress
            // The summary and the list swap as the sheet starts to move: the outgoing one goes at once (so the short
            // sheet never shows the list's rows, nor the tall one both), the incoming one fades in quickly. Never a
            // slide; the header and the buttons stay in place.
            if !expanded {
                summary.transition(swap)
            }
            if expanded {
                stats.transition(swap)
                list.transition(swap)
            }
        }
        .padding(.horizontal, Spacing.l)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { onHeight($0) }
        .onChange(of: headerText, initial: true) { _, text in if !probe { onHeader(text) } }
        .task(id: probe ? "" : originKey) {
            guard !probe, let start = model.mainRoute?.coordinates.first else { return }
            originName = await RouteBuilder.placeName(at: start)
        }
        .task(id: probe ? "" : ownInputs) {
            // Once per change of my car's route, merge offset, state or the main route, not per refresh.
            guard !probe else { return }
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
        .task(id: probe ? "" : coordinateKey(ownStart)) {
            ownStartName = nil
            guard let start = ownStart else { return }
            ownStartName = await RouteBuilder.placeName(at: start)
        }
        .task(id: probe ? "" : coordinateKey(joinCoordinate)) {
            joinPlaceName = nil
            guard let at = joinCoordinate else { return }
            joinPlaceName = await RouteBuilder.placeName(at: at)
        }
    }

    // MARK: Derived values

    private var swap: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.quick(reduceMotion: reduceMotion)), removal: .identity)
    }

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

    private var myJoining: JoiningEntry? { convoy.myJoining }

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

    /// Both ends use one text style whatever their length (it grows with the text size); a long name wraps to
    /// a second line, and only then shrinks a little. It never truncates at the default size.
    private var endFont: Font { .system(.title, design: .rounded).weight(.bold) }
    private var endLines: Int { ConvoyEndName.lineLimit(accessibilitySize: typeSize.isAccessibilitySize) }

    /// Display names: "KL" for Kuala Lumpur and other well-known short forms, else the full name.
    private var originShort: String? { originName.map(ConvoyFormat.placeShortName) }
    private var destinationShort: String { ConvoyFormat.placeShortName(convoy.destinationName ?? "") }

    private var frontArrival: Date? {
        guard let reference = convoy.snapshot.etaReference else { return nil }
        return convoy.arrival(forCar: reference.id)
    }

    private var mineArrived: Bool { convoy.snapshot.hasArrived(model.myCarId) }

    // MARK: Pieces

    private var header: some View {
        let destination = convoy.destinationName ?? ""
        let arrive = frontArrival.map { ConvoyFormat.clock($0) }
        let text = probe ? (headerWords ?? headerText) : headerText
        return HStack(alignment: .top, spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: 0) {
                StatCaption("From")
                Text(text.from)
                    .font(endFont)
                    .lineLimit(endLines)
                    .minimumScaleFactor(ConvoyEndName.minimumScale)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .font(endFont)
                    .lineLimit(endLines)
                    .minimumScaleFactor(ConvoyEndName.minimumScale)
                    .fixedSize(horizontal: false, vertical: true)
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
        // Room for the sheet's own grabber, which is the only handle (a second one confused VoiceOver).
        .padding(.top, Spacing.xs + BottomSheet.indicatorRoom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ConvoyHeader.label(title: convoy.title, text: text, destination: destination, arrive: arrive))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("convoy.header")
        // A tap on the header folds or unfolds the list. It is also the button VoiceOver and the UI tests find
        // ("Expand convoy list"), beside the header's own words. The Next stop cell is in the grid below, not
        // under this tap, so the two never meet.
        .overlay {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
                .accessibilityElement()
                .accessibilityLabel(expanded ? "Collapse convoy list" : "Expand convoy list")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { expanded.toggle() }
        }
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
            .accessibilityLabel("Convoy progress, \(ConvoyFormat.distance(driven)) of \(ConvoyFormat.distance(length))")

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
        guard let mine = convoy.myJoining else { return nil }
        return NextStop.joiningCell(
            stops: model.stops, distance: mine.distanceToMerge, seconds: mine.timeToMerge,
            mergeOffset: mine.car.mergeOffset, pace: model.joiningStopPace(), skipsMeet: model.skipsMeetingPoint)
    }

    private var myEntry: ConvoyEntry? { convoy.myEntry }

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
                        Circle().fill(Color.car(hex: e.car.color))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().strokeBorder(Color(.systemBackground).opacity(0.8), lineWidth: 2))
                    }
                    ForEach(convoy.joining) { e in
                        Circle().fill(Color.white)
                            .overlay(Circle().strokeBorder(Color.car(hex: e.car.color),
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

    /// The cars, in the sheet's own scroll: the list has none of its own, so the whole panel moves as one.
    private var list: some View {
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
                ConvoyRowView(row: row, youOnline: model.youOnline)
            }
            // Joining cars follow in the same list; their dashed badges set them apart.
            ForEach(Array(convoy.joiningRows(myCarId: model.myCarId).enumerated()), id: \.element.id) { index, row in
                if index > 0 || !convoy.convoyRows.isEmpty { Divider().padding(.leading, 44) }
                JoiningRowView(row: row, mine: row.id == model.myCarId, youOnline: model.youOnline)
            }
        }
        .padding(.top, Spacing.tight)
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
}

/// Report and Pit stop, pinned to the bottom of the convoy sheet (D34 7c): outside the scrolling panel, so they never
/// move when the sheet folds, unfolds or is dragged, and the list scrolls under them. No background of its own: the
/// sheet is the surface.
struct ConvoyActionBar: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var canReport: Bool
    var stopButton: StopLogic.ButtonContent
    var onReport: () -> Void
    var onStop: () -> Void
    /// How far the buttons hang down into the sheet's bottom safe area (`PanelSheet.barLift`).
    var lift: CGFloat = 0

    var body: some View {
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
            .actionBarStyle(prominent: true)
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
            .actionBarStyle(prominent: false)
            .layoutPriority(1)
            .accessibilityLabel(stopButton.accessibilityLabel)
            .accessibilityIdentifier("stop.button")
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.m)
        // The sheet's bottom safe area is more than the side gap: the buttons hang down into it (the bar's layout
        // height stops above it, so the detents are still content + bar) until the gap under them equals the gap
        // beside them.
        .padding(.bottom, -lift)
    }
}

private extension View {
    /// Liquid Glass buttons on iOS 26 (the owner chose glass on the sheet, 2026-10-25): Report prominent and tinted
    /// with the accent, Pit stop clear (`GlassSurface.useGlass` is the switch). Before iOS 26, the tinted and bordered capsules as before.
    @ViewBuilder func actionBarStyle(prominent: Bool) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
            } else {
                buttonStyle(.glass).buttonBorderShape(.capsule).tint(.primary)
            }
        } else if prominent {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(MapPalette.accent)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule).tint(.primary)
        }
    }
}

#if DEBUG
#Preview("Panel") {
    @Previewable @State var expanded = true
    ZStack(alignment: .bottom) {
        Color(.systemGray4).ignoresSafeArea()
        ConvoyPanel(model: MapDemo.model(), expanded: $expanded).previewCard()
    }
}

#Preview("Panel collapsed") {
    ZStack(alignment: .bottom) {
        Color(.systemGray4).ignoresSafeArea()
        ConvoyPanel(model: MapDemo.model(), expanded: .constant(false)).previewCard()
    }
}

extension View {
    /// The panel as a card on a plain background, for previews and the small demos that show only its words.
    func previewCard() -> some View {
        glassSurface().padding(.horizontal, Spacing.s).padding(.bottom, Spacing.s)
    }
}
#endif
