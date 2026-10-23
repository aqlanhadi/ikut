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

extension Color {
    /// Teal of a car that is still joining the convoy; the meeting point wears it too.
    static let ikutJoining = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.18, green: 0.83, blue: 0.75, alpha: 1) : UIColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1) })
}

extension PlaceKind {
    /// "Petrol station", "Restaurant", "Town": the word under a place's name.
    static func word(for result: DestinationResult) -> String {
        switch result.category.map(MKPointOfInterestCategory.init(rawValue:)) {
        case nil: "Town"
        case .gasStation?: "Petrol station"
        case .evCharger?: "Charging point"
        case .restaurant?: "Restaurant"
        case .cafe?: "Cafe"
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

/// Add a stop (AddStop.dc.html): search like Where to?, then what it is and how long, then Add to the trip.
struct AddStopSheet: View {
    /// The route the stop is added to, for "62 km" and "40 min along".
    var along: AlongRoute?
    /// A meeting point can only be the first stop.
    var canMeet: Bool
    var onAdd: (StopDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = CreateTripModel()
    @State private var picked: DestinationResult?
    @State private var kind: PlannedStopKind = .fuel
    @State private var minutes: Int?
    @State private var meetClock: Date?
    @FocusState private var searchFocused: Bool

    init(along: AlongRoute?, canMeet: Bool, onAdd: @escaping (StopDraft) -> Void) {
        self.along = along
        self.canMeet = canMeet
        self.onAdd = onAdd
    }

    #if DEBUG
    /// A sheet already on a step, for previews and screenshots.
    init(demoModel: CreateTripModel, picked: DestinationResult?, kind: PlannedStopKind, minutes: Int?, canMeet: Bool, meetClock: Date? = nil) {
        along = demoModel.along
        self.canMeet = canMeet
        onAdd = { _ in }
        _model = State(initialValue: demoModel)
        _picked = State(initialValue: picked)
        _kind = State(initialValue: kind)
        _minutes = State(initialValue: minutes)
        _meetClock = State(initialValue: meetClock)
    }
    #endif

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.cozy) {
                header
                if let picked { details(picked) } else { search }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.l)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.ikutScreen)
        .presentationDragIndicator(.visible)
        .presentationDetents([.large])
        .onAppear { model.along = along }
    }

    private var header: some View {
        HStack {
            Button(picked == nil ? "Cancel" : "Back") {
                if picked == nil { dismiss() } else { picked = nil }
            }
            .frame(minWidth: 60, alignment: .leading)
            Spacer()
            Text("Add a stop").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Color.clear.frame(width: 60, height: 1)
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.top, Spacing.m)
        .frame(minHeight: 44)
    }

    // MARK: Step 1: search

    private var search: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                IconTile(symbol: "mappin", color: .red, size: 30, font: .footnote.weight(.bold))
                VStack(alignment: .leading, spacing: 0) {
                    StatCaption("Where?")
                    TextField("Search a place or address", text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("addStop.search")
                        .onChange(of: model.query) { model.queryChanged() }
                }
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                        searchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 54)
            .ikutCard()

            if let message = model.errorMessage {
                InlineNote(message, tone: .alert).padding(.top, Spacing.m)
            }
            if !model.trimmedQuery.isEmpty {
                CardHeader("Results")
                VStack(spacing: 0) {
                    if model.isSearching && model.results.isEmpty {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 58).accessibilityLabel("Searching")
                    } else if model.results.isEmpty {
                        Text("No places match “\(model.trimmedQuery)”. Try another name.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.section)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                        if index > 0 { RowDivider() }
                        row(result)
                    }
                }
                .ikutCard()
                if along != nil, !model.results.isEmpty {
                    InlineNote("Distances are along your route.").padding(.top, Spacing.s)
                }
            }
        }
        .task { searchFocused = picked == nil }
    }

    private func row(_ result: DestinationResult) -> some View {
        var shown = result
        shown.subtitle = [PlaceKind.word(for: result), result.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
        let along = model.alongText(result)
        return PlaceResultRow(result: shown, action: { pick(result) }) {
            if let along {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(along.distance)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    if let time = along.time { Text(time).font(.caption).foregroundStyle(.secondary) }
                }
            } else if let distance = model.distanceText(result) {
                Text(distance).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            }
        }
    }

    private func pick(_ result: DestinationResult) {
        searchFocused = false
        picked = result
        kind = PlannedStopKind(guessing: result)
        minutes = nil
        meetClock = nil
    }

    // MARK: Step 2: what and how long

    private func details(_ place: DestinationResult) -> some View {
        VStack(spacing: Spacing.cozy) {
            HStack(spacing: Spacing.m) {
                IconTile(symbol: "mappin", color: .red, size: 30, font: .footnote.weight(.bold))
                VStack(alignment: .leading, spacing: 0) {
                    Text(place.name).font(.body)
                    Text(placeLine(place)).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.cozy).padding(.vertical, Spacing.gap)
            .ikutSurface(Color(.secondarySystemGroupedBackground), radius: Radius.row + 2)
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: Spacing.s) {
                caption("What for?")
                let kinds = (canMeet ? [PlannedStopKind.meet] : []) + [.fuel, .food, .rest, .toilet, .sight]
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 3), spacing: Spacing.s) {
                    ForEach(kinds, id: \.self) { option in kindTile(option) }
                }
            }

            if kind == .meet {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    caption("Meet at (optional)")
                    meetTimeRow
                }
                Text("The trip starts here. Everyone drives to this spot first, and the lead car taps Leave when you’re all there.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    caption("How long? (optional)")
                    HStack(spacing: Spacing.s) {
                        chip("None", selected: minutes == nil) { minutes = nil }
                        ForEach(PlannedStop.allowedMinutes, id: \.self) { value in
                            chip(StopFormat.length(minutes: value), selected: minutes == value) { minutes = value }
                        }
                    }
                }
                if !canMeet {
                    Text("A meeting point can only be the first stop.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.xs)
                }
            }

            Button("Add to the trip") { add(place) }
                .buttonStyle(PillButtonStyle())
                .padding(.top, Spacing.s)
                .accessibilityIdentifier("addStop.add")
        }
    }

    private func placeLine(_ place: DestinationResult) -> String {
        let word = PlaceKind.word(for: place)
        guard let along = along?.place(for: place.coordinate) else { return word }
        return "\(word) · \(along)"
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func kindTile(_ option: PlannedStopKind) -> some View {
        let selected = kind == option
        return Button { kind = option } label: {
            VStack(spacing: Spacing.tight) {
                Image(systemName: option.symbol).font(.system(size: 20, weight: .semibold))
                Text(StopFormat.kind(option)).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 84)
            .ikutSurface(selected ? AnyShapeStyle(option.tint) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), radius: Radius.row + 2)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("addStop.kind.\(option.rawValue)")
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? AnyShapeStyle(Color.ikutAccent) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var meetTimeRow: some View {
        HStack {
            Text("Time")
            Spacer()
            if let clock = meetClock {
                DatePicker("Time", selection: Binding(get: { clock }, set: { meetClock = $0 }), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button { meetClock = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("No time")
            } else {
                Button("Set a time") { meetClock = Self.defaultMeetClock() }
                    .font(.body.weight(.semibold))
            }
        }
        .padding(.horizontal, Spacing.cozy)
        .frame(minHeight: 50)
        .ikutSurface(Color(.secondarySystemGroupedBackground), radius: Radius.row + 2)
    }

    /// 9:00 today, the starting point for the picker.
    private static func defaultMeetClock() -> Date {
        Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private func add(_ place: DestinationResult) {
        var meetAt: Date?
        if kind == .meet, let clock = meetClock {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: clock)
            meetAt = StopFormat.nextTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0, after: Date())
        }
        onAdd(StopDraft(
            name: place.name, coordinate: place.coordinate, kind: kind,
            minutes: kind == .meet ? nil : minutes, meetAt: meetAt))
        dismiss()
    }
}
