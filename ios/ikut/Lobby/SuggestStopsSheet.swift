import CoreLocation
import Foundation
import Observation
import SwiftUI

/// What the Suggest stops sheet shows for the trip (SuggestStops.dc.html).
@MainActor @Observable
final class SuggestStopsModel {
    enum State: Equatable {
        /// Looking through the places on the route.
        case loading
        /// No route or no places file yet.
        case cantSuggest
        /// Under 90 minutes: drive straight through.
        case short
        /// A trip long enough, but no R&R on our side near that time (or the stop is already planned).
        case nothing
        case ready
    }

    /// The minutes an added R&R stops for (#324).
    static let stopMinutes = 20

    private(set) var state: State = .loading
    private(set) var picks: [StopSuggestion] = []
    private(set) var added: Set<String> = []
    private(set) var after: Double

    private let line: RouteLine?
    private let routeSeconds: Double?
    private var existing: [Double]
    private let sites: [PlaceSite]
    private let fuel: [FuelStation]
    private var candidates: [PlaceAlong]?

    /// `existing`: route offsets (meters) of the stops already planned. `candidates` skips the lookup (tests, demos).
    init(
        line: RouteLine?, routeSeconds: Double?, existing: [Double],
        sites: [PlaceSite] = OurSide.bundledSites, fuel: [FuelStation] = OurSide.bundledFile?.fuel ?? [],
        candidates: [PlaceAlong]? = nil
    ) {
        self.line = line
        self.routeSeconds = routeSeconds
        self.existing = existing
        self.sites = sites
        self.fuel = fuel
        self.candidates = candidates
        after = SuggestAfter.defaultSeconds(routeSeconds: routeSeconds ?? 0)
        refresh()
    }

    var canSuggest: Bool { (line?.segmentCount ?? 0) > 0 && (routeSeconds ?? 0) > 0 && !(sites.isEmpty && fuel.isEmpty) }

    /// Looks through the places along the route, off the main thread, then picks.
    func load() async {
        guard candidates == nil else { return }
        guard let line, canSuggest else { refresh(); return }
        let sites = sites, fuel = fuel
        candidates = await Task.detached(priority: .userInitiated) {
            PlaceSide.along(sites: sites, fuel: fuel, line: line)
        }.value
        refresh()
    }

    func step(_ direction: Int) {
        after = SuggestAfter.stepped(after, by: direction)
        refresh()
    }

    private func refresh() {
        guard let line, let routeSeconds, canSuggest else { state = .cantSuggest; picks = []; return }
        guard let candidates else { state = .loading; return }
        guard routeSeconds >= PlaceRules.halfwayFrom else { state = .short; picks = []; return }
        picks = SuggestStops.suggest(
            candidates: candidates, routeLength: line.length, routeSeconds: routeSeconds, every: after, existing: existing)
        state = picks.isEmpty ? .nothing : .ready
    }

    /// The stop Add hands to the planner: a 20 min Rest at the R&R's gate on our slip road, so the route goes in by
    /// our carriageway (`entrance`, not the R&R's middle).
    func draft(for pick: StopSuggestion) -> StopDraft {
        StopDraft(
            name: RequestPlaces.name(pick.place), coordinate: pick.place.entrance, kind: .rest,
            minutes: Self.stopMinutes, routeOffset: pick.place.routeOffset)
    }

    /// Route offsets of the stops already planned: a meeting point is not a break.
    static func existingOffsets(_ items: [StopDraft]) -> [Double] {
        items.filter { !$0.isMeeting }.compactMap(\.routeOffset)
    }

    /// Records the add; false when this pick was already added, so a second tap does nothing. The added R&R counts
    /// as an existing stop, so moving the time doesn't suggest another beside it.
    @discardableResult
    func markAdded(_ pick: StopSuggestion) -> Bool {
        guard added.insert(pick.id).inserted else { return false }
        existing.append(pick.place.routeOffset)
        return true
    }
    var allAdded: Bool { !picks.isEmpty && picks.allSatisfy { added.contains($0.id) } }

    /// "R&R Tapah (northbound) · 1 h 43 min along · 139 km".
    static func along(_ pick: StopSuggestion) -> String {
        "\(ConvoyFormat.duration(pick.at)) along · \(RouteFormat.distance(pick.place.routeOffset))"
    }

    static func stepperText(_ after: Double) -> String { "Suggest after about \(ConvoyFormat.duration(after))" }

    static func chips(_ place: PlaceAlong) -> [String] {
        [place.facilities.contains(.fuel) ? "Fuel" : nil, place.facilities.contains(.food) ? "Food" : nil,
         place.facilities.contains(.toilets) ? "Toilets" : nil, place.facilities.contains(.ev) ? "EV charging" : nil]
            .compactMap { $0 }
    }
}

/// Suggest stops: the R&R the convoy should break at, with Not now and Add.
struct SuggestStopsSheet: View {
    @State var model: SuggestStopsModel
    /// "KL to Ipoh · 205 km · 2 h 25 min".
    var summary: String
    var canAdd: () -> Bool
    var onAdd: (StopDraft) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                    content
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.s)
                .padding(.bottom, Spacing.l)
            }
            .background(Color.ikutScreen)
            .navigationTitle("Suggest stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .buttonSurface(.glass)
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
        .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, Spacing.l)
                .accessibilityLabel("Looking for a stop")
        case .cantSuggest:
            note("Can't suggest a stop for this trip yet. Try again once the route is ready.")
        case .short:
            note("This trip is short enough to drive straight through.")
        case .nothing:
            stepper
            note("Nothing to add near that time. Try a different time.")
        case .ready:
            StatCaption("Suggested")
            stepper
            ForEach(model.picks) { pick in card(pick) }
            Text("Places © OpenStreetMap").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.body).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(AXID.Suggest.note)
    }

    private var stepper: some View {
        HStack(spacing: Spacing.m) {
            Text(SuggestStopsModel.stepperText(model.after)).font(.body).accessibilityIdentifier(AXID.Suggest.after)
            Spacer(minLength: Spacing.s)
            Button { model.step(-1) } label: { Image(systemName: Symbol.remove).inlineRoundLabel() }
                .disabled(!SuggestAfter.canStep(model.after, by: -1))
                .accessibilityLabel("Earlier").accessibilityIdentifier(AXID.Suggest.earlier)
            Button { model.step(1) } label: { Image(systemName: Symbol.add).inlineRoundLabel() }
                .disabled(!SuggestAfter.canStep(model.after, by: 1))
                .accessibilityLabel("Later").accessibilityIdentifier(AXID.Suggest.later)
        }
        .buttonStyle(.bordered).buttonBorderShape(.circle).tint(Color.ikutAccent)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .ikutSurface(Color(.secondarySystemGroupedBackground), radius: Radius.inner + 2)
    }

    private func card(_ pick: StopSuggestion) -> some View {
        let added = model.added.contains(pick.id)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Text(RequestPlaces.name(pick.place)).font(.headline)
            Text(SuggestStopsModel.along(pick)).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: Spacing.s) {
                ForEach(SuggestStopsModel.chips(pick.place), id: \.self) { chip in
                    Chip(text: .verbatim(chip), tone: .accent)
                }
            }
            HStack(spacing: Spacing.s) {
                Button { dismiss() } label: { Text("Not now").frame(maxWidth: .infinity) }
                    .ikutButton(.secondary)
                Button {
                    guard model.markAdded(pick) else { return }
                    onAdd(model.draft(for: pick))
                    if model.allAdded { dismiss() }
                } label: { Text("Add").frame(maxWidth: .infinity) }
                    .ikutButton(.primary)
                    .disabled(added || !canAdd())
                    .accessibilityIdentifier(AXID.Suggest.add)
            }
            .padding(.top, Spacing.xs)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutSurface(Color(.secondarySystemGroupedBackground), radius: Radius.inner + 2)
    }
}
