import MapKit
import SwiftUI

/// Where to? (MapFirst B2) as the content of Home's sheet: a search field with Cancel, then the results.
/// The pins and the camera are Home's map; this only reports the list's scroll position through `flow`.
struct WhereToSheet: View {
    @Bindable var flow: NewTripFlow
    var onClose: () -> Void
    @FocusState private var searchFocused: Bool

    private var model: CreateTripModel { flow.search }

    var body: some View {
        @Bindable var model = flow.search
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.gap) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search a town, place or address", text: $model.query)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .disabled(model.isWorking)
                        .accessibilityLabel("Destination")
                        .onChange(of: model.query) { model.queryChanged() }
                        .onSubmit { model.submit() }
                    if !model.query.isEmpty {
                        Button {
                            model.query = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary).frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, Spacing.m)
                .frame(minHeight: 44)
                .background(Color(.tertiarySystemFill), in: Capsule())
                Button("Cancel", action: onClose)
                    .foregroundStyle(Color.ikutAccent)
                    .frame(minHeight: 44)
            }
            .padding(.top, Spacing.xs)

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
        .task {
            searchFocused = true
            await model.locate()
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
            HStack {
                circleButton("chevron.left", label: "Back to search", action: onBack)
                Spacer()
                Text("New trip").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                circleButton("xmark", label: "Close", action: onClose)
            }
            .padding(.top, Spacing.xs)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(ready.place.name).font(.largeTitle.bold()).minimumScaleFactor(0.7).lineLimit(2)
                Text(NewTripFlow.detailLine(place: ready.place, route: ready.route))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.xs)
            .padding(.top, Spacing.xs)
            .accessibilityElement(children: .combine)

            HStack(spacing: Spacing.m) {
                Text("Name")
                    .frame(width: 80, alignment: .leading)
                TextField(flow.namePlaceholder, text: $flow.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .disabled(flow.isCreating)
                    .accessibilityLabel("Trip name")
            }
            .padding(.horizontal, Spacing.l)
            .frame(minHeight: 46)
            .ikutCard()
            .padding(.top, Spacing.m)

            if let message = flow.createError {
                InlineNote(message, tone: .alert)
                    .padding(.top, Spacing.m)
                    .accessibilityIdentifier("createTripError")
            }

            Spacer(minLength: Spacing.m)

            Text("Next you get a code for the group chat. Add a meeting point and stops once the trip is made.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Button(action: onCreate) {
                Group {
                    if flow.isCreating { ProgressView().accessibilityLabel("Creating trip") } else { Text("Create trip") }
                }
                .frame(maxWidth: .infinity)
            }
            .actionButton(.primary, onGlass: true)
            .disabled(flow.isCreating)
            .padding(.top, Spacing.s)
            .padding(.bottom, Spacing.s)
        }
    }

    private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(Color(.tertiarySystemFill), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(flow.isCreating)
        .accessibilityLabel(label)
    }
}

/// The pins and the route of the create flow, as content for Home's map.
@MainActor
enum NewTripMapContent {
    @MapContentBuilder
    static func content(_ flow: NewTripFlow) -> some MapContent {
        UserAnnotation()
        if let ready = flow.ready {
            let line = Polyline.decode(ready.route.polyline)
            if line.count > 1 {
                MapPolyline(coordinates: line)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            Annotation(ready.place.name, coordinate: ready.place.coordinate, anchor: .bottom) {
                pin(focused: false, color: Color(.label))
            }
            .annotationTitles(.visible)
        } else {
            let target = flow.focusTarget?.id
            ForEach(flow.pins) { place in
                let focused = place.id == target
                Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                    pin(focused: focused, color: .red)
                }
                .annotationTitles(focused ? .visible : .hidden)
            }
        }
    }

    private static func pin(focused: Bool, color: Color) -> some View {
        let size: CGFloat = focused ? 36 : 28
        return Image(systemName: "mappin")
            .font(.system(size: focused ? 16 : 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .accessibilityHidden(true)
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
