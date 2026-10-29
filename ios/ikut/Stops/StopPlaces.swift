import Observation
import SwiftUI

/// The places a request card lists: worked out from the trip's route, the convoy front's offset and pace and the
/// open requests' reasons, so every phone gets the same list (nothing here reads the phone's own location).
/// Recomputed when the reasons change and once a minute of driving, off the main actor.
@MainActor @Observable
final class StopPlacesModel {
    private(set) var places: [RequestPlace] = []
    /// The demo shows a fixed list; the live work leaves it alone.
    private(set) var isFixed = false

    func showForDemo(_ places: [RequestPlace]) {
        self.places = places
        isFixed = true
    }

    /// How often the list is worked out again while a request is open.
    static let refreshEvery: Duration = .seconds(60)

    /// Works the list out now. Nothing without a route, a front car or a reason.
    func refresh(reasons: [RequestNeed], context: StopContext) async {
        guard !isFixed else { return }
        guard let route = context.mainRoute, let front = context.front(), !reasons.isEmpty else {
            places = []
            return
        }
        let list = await Task.detached(priority: .utility) {
            RequestPlaces.list(reasons: reasons, front: front, route: route)
        }.value
        // A refresh that was cancelled (new reasons, a new route) never overwrites a newer one.
        guard !Task.isCancelled else { return }
        if list != places { places = list }
    }

    /// Refreshes now and then once a minute, until the task is cancelled (the card closes or the reasons change).
    func keepFresh(reasons: [RequestNeed], context: StopContext) async {
        while !Task.isCancelled {
            await refresh(reasons: reasons, context: context)
            try? await Task.sleep(for: Self.refreshEvery)
        }
    }
}

/// Up to three places under a request, with the OpenStreetMap credit once underneath. Nothing to tap yet.
struct StopPlaceRows: View {
    var places: [RequestPlace]

    var body: some View {
        if !places.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(places) { place in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(place.name).font(.body.weight(.semibold)).lineLimit(2)
                        Text(place.whereText).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                        Text(place.whyText).font(.footnote).foregroundStyle(Color.surfaceSecondary)
                    }
                    .ikutRow(fillWidth: true, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("stop.place.\(place.id)")
                }
                Text("© OpenStreetMap contributors")
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary)
                    .accessibilityIdentifier("stop.places.credit")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
