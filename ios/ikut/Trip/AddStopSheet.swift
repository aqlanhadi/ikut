import CoreLocation
import MapKit
import SwiftUI

/// What a stop can be, with its icon and the color of its tile (AddStop.dc.html).
extension PlannedStopKind {
    var symbol: String {
        switch self {
        case .meet: "flag.fill"
        case .fuel: "fuelpump.fill"
        case .food: "fork.knife"
        case .rest: "cup.and.saucer.fill"
        case .toilet: "toilet.fill"
        case .sight: "mountain.2.fill"
        }
    }

    /// A meeting point is teal, the color of a car still joining; every other stop is the accent.
    var tint: Color { self == .meet ? Color.ikutJoining : Color.ikutAccent }

    /// The kind a search result most likely is, as the sheet's first guess.
    init(guessing result: DestinationResult) {
        let category = result.category.map(MKPointOfInterestCategory.init(rawValue:))
        switch category {
        case .gasStation?, .evCharger?: self = .fuel
        case .restaurant?, .cafe?, .bakery?, .foodMarket?: self = .food
        case .restroom?: self = .toilet
        case .park?, .nationalPark?, .beach?, .museum?, .zoo?, .aquarium?: self = .sight
        default: self = .fuel
        }
    }
}

extension PlaceKind {
    /// "Petrol station", "Restaurant", "Town": the word under a place's name.
    static func word(for result: DestinationResult) -> String {
        switch result.category.map(MKPointOfInterestCategory.init(rawValue:)) {
        case nil: "Town"
        case .gasStation?: "Petrol station"
        case .evCharger?: "Charging point"
        case .restaurant?: "Restaurant"
        case .cafe?: "Café"
        case .bakery?: "Bakery"
        case .foodMarket?: "Market"
        case .hotel?: "Hotel"
        case .park?, .nationalPark?: "Park"
        case .beach?: "Beach"
        case .publicTransport?: "Station"
        case .airport?: "Airport"
        case .restroom?: "Rest area"
        default: "Place"
        }
    }
}


/// Add a stop (B6, AddStop.dc.html): the lobby's own sheet turned into the stop chooser, over the map that shows the
/// same numbered R&Rs. The R&Rs along the way in order, with Stay and "Add <place>" once one is selected; a search
/// along the route for any other place, which then asks what it is. Back returns to the lobby with nothing changed.
struct AddStopContent: View {
    @Bindable var model: AddStopModel
    /// How far the bottom bar's button hangs into the sheet's bottom safe area (`PanelSheet.barLift`).
    var barLift: CGFloat = 0
    var onSelect: (String) -> Void
    var onExpand: () -> Void = {}
    var onBack: () -> Void
    var onAdd: (StopDraft) -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The header stays put and the rows fade out under it, as they do above the Add bar.
        Group {
            ScrollViewReader { proxy in
                List {
                    if let place = model.picked { details(place) } else { chooser }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                // The picked place's sections stack tight, so "How long?" is still above the Add bar on the short sheet.
                .listSectionSpacing(.compact)
                .contentMargins(.top, Spacing.xs, for: .scrollContent)
                .contentMargins(.bottom, Spacing.l, for: .scrollContent)
                .scrollDismissesKeyboard(.interactively)
                // A tap on a pin brings its row into view.
                .onChange(of: model.selectedId) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.quick(reduceMotion: reduceMotion)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .sheetBottomBar { addBar }
        }
        .buttonSurface(.glass)
        .sheetTopBar {
            SheetTopRow(title: "Add a stop", subtitle: nil) {
                RoundGlassIconButton(systemImage: "chevron.backward", label: model.picked == nil ? "Back to the trip" : "Back to the list") {
                    searchFocused = false
                    if !model.back() { onBack() }
                }
                .accessibilityIdentifier("addStop.back")
            } trailing: { Color.clear }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xs)
        }
        .task { await model.load() }
    }

    // MARK: The list

    @ViewBuilder private var chooser: some View {
        @Bindable var search = model.search
        // The search bar is the sheet's own capsule, a clear row on the glass.
        Section {
            SheetSearchField(clear: search.query.isEmpty ? nil : { search.query = ""; searchFocused = true }) {
                TextField("Search along the route", text: $search.query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .accessibilityIdentifier("addStop.search")
                    .onChange(of: search.query) { model.search.queryChanged() }
                    .onSubmit { model.search.submit() }
            }
            .onChange(of: searchFocused) { _, focused in if focused { onExpand() } }
            .lobbyRow()
        }
        if let message = model.search.errorMessage {
            Section { InlineNote(message, tone: .alert).lobbyRow() }
        }
        if model.search.showsList || searchFocused {
            PlaceSearchResults(model: model.search, distance: .alongRoute, showsKind: true, onPick: { place in
                searchFocused = false
                model.pick(place)
            })
        } else {
            rnrList
        }
    }

    @ViewBuilder private var rnrList: some View {
        Section {
            if model.loading {
                ProgressView().frame(maxWidth: .infinity).accessibilityLabel("Looking for R&Rs")
            } else if model.rows.isEmpty {
                Text("No R&R on our side of the road along this trip. Search for a place instead.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("addStop.none")
            } else {
                ForEach(model.rows) { row in rnrRow(row) }
            }
        } header: {
            Text("R&R along the way, in order")
        }
    }

    private func rnrRow(_ row: AddStopLogic.Row) -> some View {
        let selected = row.id == model.selectedId
        let taken = row.alreadyStop
        return Button { onSelect(row.id) } label: {
            HStack(spacing: Spacing.m) {
                Text("\(row.number)")
                    .ikutGlyph(13, weight: .bold, design: .rounded, cap: 1.3)
                    .foregroundStyle(.white)
                    .iconFrame(.small)
                    .background(selected ? Color.ikutAccent : Color.neutralFill, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name).font(.callout.weight(selected ? .semibold : .medium)).foregroundStyle(Color.primary)
                    Text(AddStopLogic.detail(row, selected: selected)).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected {
                    Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Color.ikutAccent).accessibilityHidden(true)
                }
            }
            .opacity(taken ? 0.45 : 1)
        }
        .disabled(taken)
        .id(row.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("addStop.rnr.\(row.number)")
    }

    /// On a material, not the tile fill: the rows scroll under it.
    private var stayRow: some View {
        HStack(spacing: Spacing.m) {
            Text("Stay").font(.callout)
            Spacer(minLength: Spacing.s)
            Text(StopFormat.length(minutes: model.stay)).font(.body.weight(.semibold)).monospacedDigit()
                .accessibilityIdentifier("addStop.stay")
            HStack(spacing: Spacing.xs) {
                Button { model.step(-1) } label: { Image(systemName: "minus").inlineRoundLabel() }
                    .disabled(!AddStopLogic.canStep(model.stay, by: -1))
                    .accessibilityLabel("Shorter").accessibilityIdentifier("addStop.shorter")
                Button { model.step(1) } label: { Image(systemName: "plus").inlineRoundLabel() }
                    .disabled(!AddStopLogic.canStep(model.stay, by: 1))
                    .accessibilityLabel("Longer").accessibilityIdentifier("addStop.longer")
            }
            .buttonStyle(.bordered).buttonBorderShape(.circle).tint(Color.ikutAccent)
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .ikutRow()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }

    // MARK: Add

    @ViewBuilder private var addBar: some View {
        if let title = model.addTitle {
            // Stay sits with the button, so it is in view whatever the list's length (an R&R only, not a searched place).
            VStack(spacing: Spacing.s) {
                if model.picked == nil, model.selected != nil { stayRow }
                Button {
                    if let draft = model.take() { onAdd(draft) }
                } label: { Text(title).wrapsAtAccessibilitySizes(lines: 2).font(.headline).frame(maxWidth: .infinity) }
                    .ikutButton(.primary)
                    .disabled(model.draft == nil)
                    .accessibilityIdentifier("addStop.add")
            }
            .sheetActionBar(lift: barLift)
        }
    }

    // MARK: A searched place: what it is and how long

    @ViewBuilder private func details(_ place: DestinationResult) -> some View {
        Section {
            HStack(spacing: Spacing.m) {
                IconTile(symbol: "mappin", color: .red, size: .small, font: .footnote.weight(.bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(place.name).font(.body)
                    Text(placeLine(place)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
        }

        // The kinds are a grid of tiles, not rows: the grid stays its own layout, a clear row of the list.
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 3), spacing: Spacing.s) {
                ForEach(AddStopLogic.kinds(canMeet: model.canMeet), id: \.self) { option in kindTile(option) }
            }
            .lobbyRow()
        } header: {
            Text("What for?")
        }

        if model.kind == .meet {
            Section {
                meetTimeRow
            } header: {
                Text("Meet at (optional)")
            } footer: {
                Text("The trip starts here. Everyone drives to this spot first, and the lead car taps Leave when you’re all there.")
            }
        } else {
            Section {
                HStack(spacing: Spacing.s) {
                    chip("None", selected: model.searchedMinutes == nil) { model.searchedMinutes = nil }
                    ForEach(PlannedStop.allowedMinutes, id: \.self) { value in
                        chip(StopFormat.length(minutes: value), selected: model.searchedMinutes == value) { model.searchedMinutes = value }
                    }
                }
                .lobbyRow()
            } header: {
                Text("How long? (optional)")
            } footer: {
                if !model.canMeet { Text("A meeting point can only be the first stop.") }
            }
        }
    }

    private func placeLine(_ place: DestinationResult) -> String {
        let word = PlaceKind.word(for: place)
        guard let along = model.search.along?.place(for: place.coordinate) else { return word }
        return "\(word) · \(along)"
    }

    private func kindTile(_ option: PlannedStopKind) -> some View {
        let selected = model.kind == option
        return Button { model.kind = option } label: {
            VStack(spacing: Spacing.s) {
                Image(systemName: option.symbol).ikutGlyph(20, weight: .semibold, cap: 1.3)
                Text(StopFormat.kind(option)).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(selected ? AnyShapeStyle(option.tint) : AnyShapeStyle(Color.primary.fill(.wash)),
                        in: RoundedRectangle(cornerRadius: Radius.inner + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("addStop.kind.\(option.rawValue)")
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .wrapsAtAccessibilitySizes()
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .ikutRow(fillWidth: true)
                .background(selected ? AnyShapeStyle(Color.ikutAccent) : AnyShapeStyle(Color.primary.fill(.wash)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var meetTimeRow: some View {
        HStack {
            Text("Time")
            Spacer()
            if let clock = model.meetClock {
                DatePicker("Time", selection: Binding(get: { clock }, set: { model.meetClock = $0 }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                ClearFieldButton(label: "No time") { model.meetClock = nil }
            } else {
                Button("Set a time") { model.meetClock = Self.defaultMeetClock() }
                    .font(.body.weight(.semibold))
            }
        }
    }

    /// 9:00 today, the starting point for the picker.
    private static func defaultMeetClock() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }
}
