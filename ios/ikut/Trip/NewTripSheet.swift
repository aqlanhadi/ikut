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

    private var model: CreateTripModel { flow.search }

    var body: some View {
        @Bindable var model = flow.search
        // The search row stays put and the results fade out under it (the system's soft top edge).
        Group {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let message = model.errorMessage {
                        InlineNote(message, tone: .alert)
                            .padding(.top, Spacing.m)
                            .accessibilityIdentifier("createTripError")
                    }
                    PlaceSearchResults(model: model, distance: .fromYou, workingLabel: "Finding the route") { place in
                        searchFocused = false
                        Task { await flow.pick(place) }
                    }
                }
                .padding(.bottom, Spacing.l)
            }
            .scrollPosition(id: $flow.topResultID, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
        }
        .sheetTopBar {
            HStack(spacing: Spacing.gap) {
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
                        .accessibilityIdentifier("destinationField")
                        .onChange(of: model.query) { model.queryChanged() }
                        .onSubmit { model.submit() }
                }
                .trackingHeight($barHeight)
                glassCapsule("Cancel", action: onClose)
            }
            .padding(.top, Spacing.xs)
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
            Button(action: action) { Text(title).frame(maxHeight: .infinity) }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).tint(.primary)
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
                RoundGlassIconButton(systemImage: "xmark", label: "Close", action: onClose)
                    .accessibilityIdentifier("sheet.close").disabled(flow.isCreating)
            }
            .padding(.top, Spacing.xs)

            HStack(spacing: Spacing.m) {
                Text("Name")
                    .frame(width: 80, alignment: .leading)
                TextField(flow.namePlaceholder, text: $flow.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(flow.isCreating)
                    .accessibilityLabel("Trip name")
                    .accessibilityIdentifier("newTripNameField")
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 46)
            .surfaceTile()
            .padding(.top, Spacing.m)

            if let message = flow.createError {
                InlineNote(message, tone: .alert)
                    .padding(.top, Spacing.m)
                    .accessibilityIdentifier("createTripError")
            }

            Spacer(minLength: Spacing.m)

            Text("Next you get a code for the group chat. Add a meeting point and stops once the trip is made.")
                .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Button(action: onCreate) {
                Group {
                    if flow.isCreating { ProgressView().accessibilityLabel("Creating trip") } else { Text("Create trip") }
                }
                .barActionLabel()
            }
            .actionBarStyle(prominent: true)
            .disabled(flow.isCreating)
            // The same bar as every sheet's: as tall, and as far above the sheet's bottom edge as from its sides
            // (`PanelSheet.sideGap`, what `barLift` gives the other bars). Home's sheet gives the side insets; the bar
            // runs into the home indicator's strip rather than measuring it, which looped the layout.
            .sheetActionBar(sides: false)
            .padding(.bottom, PanelSheet.sideGap)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
    }

    private var backButton: some View {
        RoundGlassIconButton(systemImage: "chevron.left", label: "Back to search", action: onBack)
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
