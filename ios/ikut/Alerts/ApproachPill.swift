import SwiftUI

/// The hazard ahead while its approach alert is up (MapHazard.dc.html), with a live distance; the
/// map frames my car and the hazard meanwhile. Tap to frame them again after moving the map.
struct ApproachPill: View {
    let alert: TripAlert
    let model: TripMapModel
    var onShow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let distance = max(0, model.approachDistance(eventId: alert.eventId, now: context.date) ?? alert.distance ?? 0)
            Button(action: onShow) {
                DarkBanner(
                    title: alert.title,
                    subtitle: model.secondsToCover(distance).map { "In about \(Int($0.rounded())) s" },
                    symbol: "exclamationmark.triangle.fill", circle: .yellow
                ) {
                    Text(ConvoyFormat.distance(distance))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.yellow)
                        .padding(.trailing, Spacing.s)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(alert.title), \(ConvoyFormat.distance(distance)). Show it on the map")
        }
        .announces(alert.title, id: alert.id)
    }
}

/// The planned stop coming up (RoadStops.dc.html): "R&R Tapah in 2 km" over "Take the exit · Fuel · 20 min",
/// with the live distance. It is info, not a hazard: it has no action and the map is left alone.
struct StopApproachPill: View {
    let alert: TripAlert
    let kind: PlannedStopKind
    let model: TripMapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let distance = max(0, model.stopDistance(alert.eventId, now: context.date) ?? alert.distance ?? 0)
            DarkBanner(title: alert.title, subtitle: alert.body, symbol: kind.symbol, circle: .ikutPillBlue) {
                Text(ConvoyFormat.distance(distance))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.ikutPillBlue)
                    .padding(.trailing, Spacing.s)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(alert.title), \(alert.body), \(ConvoyFormat.distance(distance))")
            .accessibilityIdentifier("stopapproach.pill")
        }
        .announces("\(alert.title), \(alert.body)", id: alert.id)
    }
}

/// "Aisha’s car is behind you" (D26), on the phones of a car parked ahead on the route, from about 2
/// minutes before the nearest car behind reaches it until it has: that car's live distance, and the
/// time while it is moving. Spoken once as "Aisha’s car is 3.3 km behind you."
struct CatchUpPill: View {
    let alert: TripAlert
    let model: TripMapModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let distance = max(0, model.catchUpDistance(alert, now: context.date) ?? alert.distance ?? 0)
            let title = alert.title
            let subtitle = model.catchUpSeconds(alert, distance: distance).map { "About \(ConvoyFormat.duration($0)) away" }
            DarkBanner(title: title, subtitle: subtitle, symbol: "car.2.fill", circle: .green) {
                Text(ConvoyFormat.distance(distance))
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.green)
                    .padding(.trailing, Spacing.s)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([title, subtitle, ConvoyFormat.distance(distance)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("catchup.pill")
        }
        .announces(alert.title, id: alert.id)
    }
}

/// "Passed the debris", for a few seconds once the hazard being followed is behind.
struct PassedBanner: View {
    let text: String
    /// What VoiceOver's Close action does: the banner is held while VoiceOver runs.
    var onClose: () -> Void = {}

    var body: some View {
        DarkBanner(title: text, symbol: "checkmark", circle: .green)
            .accessibilityAction(named: "Close", onClose)
            .accessibilityAddTraits(.updatesFrequently)
            .announces(text)
    }
}

/// The organizer's line once the route is rebuilt mid-trip ("The route now goes through R&R Tapah and Ipoh"), or
/// while it waits for signal (D25 4d).
struct RouteNoticeBanner: View {
    let notice: RouteRebuilder.Notice

    var body: some View {
        DarkBanner(
            title: notice.text, symbol: notice.waiting ? "antenna.radiowaves.left.and.right.slash" : "arrow.triangle.turn.up.right.diamond.fill",
            circle: notice.waiting ? Color.white.dimmed(.faded) : .green)
            .announces(notice.text)
            .accessibilityIdentifier("route.notice")
    }
}

#if DEBUG
#Preview {
    // The demo's debris, 3 km ahead of my car.
    VStack(spacing: Spacing.m) {
        ApproachPill(alert: MapDemo.debrisAlert, model: MapDemo.model()) {}
        PassedBanner(text: "Passed the debris")
    }
    .padding(Spacing.m)
}
#endif
