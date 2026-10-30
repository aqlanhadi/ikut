import MapKit
import SwiftUI

/// Where to? (MapFirst B2) as the content of Home's sheet: a search field with Cancel, then the results.
/// The pins and the camera are Home's map; this only reports the list's scroll position through `flow`.
struct WhereToSheet: View {
    @Bindable var flow: NewTripFlow
    var onClose: () -> Void
    @FocusState private var searchFocused: Bool
    /// The search bar's height, which Cancel is made to match.
    @State private var barHeight = SheetSearch.height
    /// Where the pinned search row ends in the list's frame (the list's top safe area).
    @State private var listTopInset: CGFloat = 0

    private var model: CreateTripModel { flow.search }

    var body: some View {
        @Bindable var model = flow.search
        // The search row stays put and the results fade out under it (the system's soft top edge).
        Group {
            List {
                if let message = model.errorMessage {
                    Section {
                        InlineNote(message, tone: .alert)
                            .accessibilityIdentifier(AXID.Trip.createError)
                            .lobbyRow(top: Spacing.m)
                    }
                }
                PlaceSearchResults(model: model, distance: .fromYou, workingLabel: "Finding the route", topResult: $flow.topResultID, topInset: listTopInset) { place in
                    searchFocused = false
                    Task { await flow.pick(place) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { listTopInset = $0 }
        }
        .sheetTopBar {
            HStack(spacing: Spacing.s) {
                SheetSearchField(clear: model.query.isEmpty ? nil : {
                    model.query = ""
                    searchFocused = true
                }) {
                    TextField("Search a town, place or address", text: $model.query, prompt: Text("Where to?").foregroundStyle(Color.surfaceSecondary))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .disabled(model.isWorking)
                        .accessibilityLabel("Destination")
                        .accessibilityIdentifier(AXID.Trip.destinationField)
                        .onChange(of: model.query) { model.queryChanged() }
                        .onSubmit { model.submit() }
                }
                .trackingHeight($barHeight)
                glassCapsule("Cancel", action: onClose)
            }
            .padding(.top, Spacing.xs)
            .padding(.horizontal, Spacing.l)
        }
        .environment(\.inPanelSheet, true)
        .task {
            searchFocused = true
            await model.locate()
        }
    }

    /// Cancel: a glass capsule on the sheet (iOS 26), plain accent text otherwise.
    @ViewBuilder private func glassCapsule(_ title: String, action: @escaping () -> Void) -> some View {
        if GlassSurface.useGlass, #available(iOS 26, *) {
            Button(action: action) { Text(title) }
                .ikutButton(.secondary, tint: .primary)
                .buttonSurface(.glass)
                .frame(height: barHeight)
        } else {
            Button(title, action: action).foregroundStyle(Color.ikutAccent).frame(minHeight: barHeight)
        }
    }
}

/// New trip (MapFirst B3): the place, how far, a Name field and Create trip. Back goes to the search, Close to Home.
struct NewTripSheet: View {
    @Bindable var flow: NewTripFlow
    var ready: NewTripFlow.Ready
    var onBack: () -> Void
    var onClose: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetTopRow(
                title: ready.place.name, subtitle: NewTripFlow.detailLine(place: ready.place, route: ready.route),
                titleLabel: "New trip to \(ready.place.name)"
            ) {
                backButton
            } trailing: {
                RoundGlassIconButton(systemImage: Symbol.close, label: "Close", action: onClose)
                    .accessibilityIdentifier(AXID.Sheet.close).disabled(flow.isCreating)
            }
            .padding(.top, Spacing.xs)
            .padding(.horizontal, Spacing.l)

            List {
                Section {
                    HStack(spacing: Spacing.m) {
                        Text("Name")
                            .frame(width: 80, alignment: .leading)
                        TextField(flow.namePlaceholder, text: $flow.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                            .disabled(flow.isCreating)
                            .accessibilityLabel("Trip name")
                            .accessibilityIdentifier(AXID.Trip.newTripNameField)
                    }
                }
                if let message = flow.createError {
                    Section {
                        InlineNote(message, tone: .alert)
                            .accessibilityIdentifier(AXID.Trip.createError)
                            .lobbyRow()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.top, Spacing.xs, for: .scrollContent)

            Text("Next you get a code for the group chat. Add a meeting point and stops once the trip is made.")
                .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.l)
            Button(action: onCreate) {
                Group {
                    if flow.isCreating { ProgressView().accessibilityLabel("Creating trip") } else { Text("Create trip") }
                }
                .font(.headline).frame(maxWidth: .infinity)
            }
            .ikutButton(.primary, tint: .ikutAccentFill)
            .disabled(flow.isCreating)
            // The same bar as every sheet's: as tall, and as far above the sheet's bottom edge as from its sides
            // (`PanelSheet.sideGap`, what `barLift` gives the other bars). Home's sheet gives the side insets; the bar
            // runs into the home indicator's strip rather than measuring it, which looped the layout.
            .sheetActionBar(sides: false)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, PanelSheet.sideGap)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
        .buttonSurface(.glass)
    }

    private var backButton: some View {
        RoundGlassIconButton(systemImage: Symbol.back, label: "Back to search", action: onBack)
            .disabled(flow.isCreating)
    }
}

extension NewTripFlow {
    /// The map region for this step: the whole route above the sheet on New trip, else the pin at the top of the
    /// list. Nil when there is nothing to show.
    func region(bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        if let ready {
            let route = PastTripsMapLogic.route(id: "new-trip", name: ready.place.name, destinationName: ready.place.name,
                                                destination: ready.place.coordinate, encodedRoute: ready.route.polyline)
            return PickedTripLogic.fit(route, bottomObscured: bottomObscured, topObscured: topObscured)
        }
        guard let target = focusTarget else { return nil }
        return PickedTripLogic.focus(on: target.coordinate, span: 0.2, bottomObscured: bottomObscured, topObscured: topObscured)
    }

    /// Changes whenever the camera should move: the step, or the pin at the top of the list.
    var cameraKey: String { "\(ready?.place.id ?? "-")|\(focusTarget?.id ?? "-")" }
}
