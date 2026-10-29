import SwiftUI

/// The timeline filter: All, Stops, Road reports.
enum RecapFilter: String, CaseIterable, Identifiable {
    case all = "All", stops = "Stops", reports = "Road reports"
    var id: String { rawValue }

    func matches(_ item: RecapTimelineItem) -> Bool {
        switch self {
        case .all: true
        case .stops: item.kind == .stop
        case .reports: item.kind == .hazard
        }
    }
}

/// What a recap says: the stat card, awards and the filtered timeline (design/project/Summary.dc.html).
/// One view for both places a recap shows, so they can't drift apart: the full screen at the end of
/// a trip (`RecapView`) and the sheet over Home's map when a past trip is picked (`PickedTripSheet`).
struct RecapContent: View {
    enum Layout: Equatable {
        /// The screen after a trip: "Trip complete" and subtitle on top (the name is the bar's large title), a route map card
        /// above the stats, and Share and Done at the bottom.
        case screen
        /// Inside Home's sheet: the name is already pinned above, the map is Home's own.
        case sheet
    }

    var recap: Recap
    var snapshot: RecapSnapshot
    var layout: Layout
    @Binding var filter: RecapFilter
    /// The screen's route map card.
    var onOpenMap: () -> Void = {}
    /// A timeline item was tapped (only items with a place on the map are tappable); nil leaves rows plain.
    var onSelect: ((RecapTimelineItem) -> Void)?
    var onDone: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var statValueSize: CGFloat = 28
    @ScaledMetric(relativeTo: .headline) private var statUnitSize: CGFloat = 17

    /// At the largest text sizes the sheet's tiles and awards go one to a row (the screen keeps two).
    private var columns: Int { layout == .sheet && typeSize.isAccessibilitySize ? 1 : 2 }

    var body: some View {
        if layout == .screen {
            Text("Trip complete")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ikutAccent)
                .padding(.horizontal, Spacing.xs).padding(.top, Spacing.l)
            Text(recap.subtitle)
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, Spacing.xs).padding(.top, Spacing.xxs)
        }

        VStack(spacing: 0) {
            if layout == .screen {
                Button(action: onOpenMap) {
                    RecapRouteMap(recap: recap, snapshot: snapshot, interactive: false)
                        .frame(height: 150)
                        .overlay(alignment: .bottomTrailing) {
                            Label("Route map", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, Spacing.m).frame(height: 30)
                                .background(.regularMaterial, in: Capsule())
                                .padding(Spacing.s)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open full route map")
            }
            statGrid(recap.stats)
        }
        .ikutCard()
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.top, Spacing.l)

        if !recap.awards.isEmpty {
            sectionTitle("Road trip awards")
            LazyVGrid(columns: columns == 1 ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: Spacing.s), GridItem(.flexible())], spacing: Spacing.s) {
                ForEach(recap.awards, id: \.kind) { award(of: $0, snapshot) }
            }
        }

        sectionTitle("Timeline")
        Picker("Filter timeline", selection: $filter) {
            ForEach(RecapFilter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        timeline(recap.timeline.filter(filter.matches))
            .padding(.top, Spacing.m)

        ForEach(recap.notes, id: \.self) { note in
            InlineNote(note, systemImage: "info.circle", inset: Spacing.xs)
                .padding(.top, Spacing.m)
        }

        VStack(spacing: Spacing.xs) {
            ShareLink(item: Self.shareText(recap)) {
                Label("Share recap", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .ikutButton(.primary)
            if let onDone {
                Button(action: onDone) { Text("Done").frame(maxWidth: .infinity) }.ikutButton(.link)
            }
        }
        .padding(.top, Spacing.xl)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title2.bold())
            .padding(.horizontal, Spacing.xs).padding(.top, Spacing.xl).padding(.bottom, Spacing.s)
            .accessibilityAddTraits(.isHeader)
    }

    private func statGrid(_ stats: [RecapStat]) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: stats.count, by: columns)), id: \.self) { row in
                if row > 0 { Divider() }
                GridRow {
                    statTile(stats[row])
                    if columns == 2, row + 1 < stats.count {
                        statTile(stats[row + 1]).overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
                    }
                }
            }
        }
    }

    private func statTile(_ s: RecapStat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(s.label).font(.footnote).foregroundStyle(.secondary)
            (Text(s.value).font(.ikutDisplay(scaled: statValueSize, base: 28, cap: 1.6, weight: .bold, design: .rounded))
                + Text(s.unit.isEmpty ? "" : " \(s.unit)").font(.ikutDisplay(scaled: statUnitSize, base: 17, cap: 1.6, weight: .semibold)).foregroundStyle(.secondary))
                .monospacedDigit()
            Text(s.note.isEmpty ? " " : s.note).font(.footnote).foregroundStyle(.secondary).wrapsAtAccessibilitySizes()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.l)
        .accessibilityElement(children: .combine)
    }

    private static let awardStyle: [RecapAward.Kind: (symbol: String, tint: Color)] = [
        .lead: ("bolt.fill", .recapLead),
        .firstIn: ("flag.checkered", .recapFirstIn),
        .reporter: ("eye.fill", .recapReporter),
        .stopCaller: ("fuelpump.fill", .recapStopCaller),
        .sweeper: ("shield.fill", .recapSweeper),
    ]

    private func award(of a: RecapAward, _ s: RecapSnapshot) -> some View {
        let style = Self.awardStyle[a.kind] ?? ("star.fill", .ikutAccent)
        let car = s.cars.first { $0.id == a.carId }
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Image(systemName: style.symbol).ikutGlyph(18, weight: .semibold, cap: 1.4).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(style.tint, in: Circle())
                Spacer()
                if let car { CarBadge(number: car.number, colorHex: car.color, size: IconSize.small.base) }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(a.title).font(.headline)
                Text(a.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ikutCard()
        .accessibilityElement(children: .combine)
    }

    private func timeline(_ items: [RecapTimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(filter == .all ? "Nothing to show." : "None on this trip, or no longer stored.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.bottom, Spacing.m)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                timelineRow(item, isLast: index == items.count - 1)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.top, Spacing.l).padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.quick(reduceMotion: reduceMotion), value: filter)
        .ikutCard()
    }

    @ViewBuilder
    private func timelineRow(_ item: RecapTimelineItem, isLast: Bool) -> some View {
        if let onSelect, item.coordinate != nil {
            Button { onSelect(item) } label: { rowBody(item, isLast: isLast).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityHint("Shows it on the map")
        } else {
            rowBody(item, isLast: isLast)
        }
    }

    private func rowBody(_ item: RecapTimelineItem, isLast: Bool) -> some View {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Text(RecapLogic.clock(item.time))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 42, alignment: .leading).padding(.top, Spacing.xs)
                    VStack(spacing: Spacing.xs) {
                        RecapEventDot(kind: item.kind, symbol: item.symbol, size: 28)
                        if !isLast {
                            Capsule().fill(Color(.systemGray5)).frame(width: 2).frame(minHeight: 12)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, Spacing.xs).padding(.bottom, Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
    }

    /// What Share sends, from the screen's and the sheet's Share alike.
    static func shareText(_ r: Recap) -> String {
        var lines = ["\(r.title): trip complete", r.subtitle]
        lines += r.stats.map { "\($0.label): \($0.value)\($0.unit.isEmpty ? "" : " \($0.unit)")" }
        return lines.joined(separator: "\n")
    }
}
