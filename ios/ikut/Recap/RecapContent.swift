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
    @ScaledMetric(relativeTo: .title) private var statValueSize: CGFloat = 28
    @ScaledMetric(relativeTo: .headline) private var statUnitSize: CGFloat = 17

    /// At the largest text sizes the sheet's tiles and awards go one to a row (the screen keeps two).
    private var columns: Int { layout == .sheet && typeSize.isAccessibilitySize ? 1 : 2 }

    /// The recap as list sections: the host (`RecapView`, `PickedTripBody`) puts them in an inset-grouped `List` (D86). The
    /// route map and the stat tiles are not rows of text, so they sit in one section as clear-inset rows of their own.
    var body: some View {
        if layout == .screen {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Trip complete")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ikutAccent)
                    Text(recap.subtitle)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .lobbyRow(top: Spacing.xs, bottom: Spacing.xs)
            }
        }

        Section {
            if layout == .screen {
                Button(action: onOpenMap) {
                    RecapRouteMap(recap: recap, snapshot: snapshot, interactive: false)
                        .frame(height: 150)
                        .overlay(alignment: .bottomTrailing) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                Text("Route map")
                            }
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, Spacing.m).frame(height: 30)
                            .background(.regularMaterial, in: Capsule())
                            .padding(Spacing.s)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open full route map")
                .listRowInsets(EdgeInsets())
            }
            statGrid(recap.stats)
                .listRowInsets(EdgeInsets())
        }

        if !recap.awards.isEmpty {
            Section("Road trip awards") {
                ForEach(recap.awards, id: \.kind) { award(of: $0, snapshot) }
            }
        }

        Section("Timeline") {
            Picker("Filter timeline", selection: $filter) {
                ForEach(RecapFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .lobbyRow()
        }
        let items = recap.timeline.filter(filter.matches)
        Section {
            if items.isEmpty {
                Text(filter == .all ? "Nothing to show." : "None on this trip, or no longer stored.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(items) { timelineRow($0) }
        }

        if !recap.notes.isEmpty {
            Section {
                ForEach(recap.notes, id: \.self) { note in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                        Image(systemName: "info.circle")
                        Text(note)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .lobbyRow()
                }
            }
        }

        Section {
            VStack(spacing: Spacing.xs) {
                ShareLink(item: Self.shareText(recap)) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share recap")
                    }
                    .frame(maxWidth: .infinity)
                }
                .ikutButton(.primary)
                if let onDone {
                    Button(action: onDone) { Text("Done").frame(maxWidth: .infinity) }.ikutButton(.link)
                }
            }
            .lobbyRow()
        }
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
        return HStack(spacing: Spacing.m) {
            Image(systemName: style.symbol).ikutGlyph(18, weight: .semibold, cap: 1.4).foregroundStyle(.white)
                .frame(width: 40, height: 40).background(style.tint, in: Circle())
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(a.title).font(.headline)
                Text(a.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let car { CarBadge(number: car.number, colorHex: car.color, size: IconSize.small.base) }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func timelineRow(_ item: RecapTimelineItem) -> some View {
        if let onSelect, item.coordinate != nil {
            Button { onSelect(item) } label: { rowBody(item).contentShape(Rectangle()) }
                .accessibilityHint("Shows it on the map")
        } else {
            rowBody(item)
        }
    }

    private func rowBody(_ item: RecapTimelineItem) -> some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            Text(RecapLogic.clock(item.time))
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 42, alignment: .leading)
            RecapEventDot(kind: item.kind, symbol: item.symbol, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                if !item.detail.isEmpty {
                    Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                }
            }
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
