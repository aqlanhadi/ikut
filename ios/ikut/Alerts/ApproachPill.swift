import SwiftUI

extension TripMapModel {
    /// Meters from my car to a hazard along the main route, carried forward from my last fix at my
    /// speed so it counts down between fixes. Nil when the hazard isn't on the main route or my car
    /// isn't in the convoy yet. Negative once passed.
    func approachDistance(eventId: String, now: Date = Date()) -> Double? {
        guard let hazard = hazards.markers.first(where: { $0.id == eventId })?.mainOffset,
              let mine = myOffsetNow(now: now) else { return nil }
        return hazard - mine
    }

    /// My car's offset on the main route, carried forward from my last fix at my speed (at most 30 s).
    func myOffsetNow(now: Date = Date()) -> Double? {
        guard let myCarId, let me = convoy.convoy.first(where: { $0.id == myCarId }) else { return nil }
        var mine = me.convoyOffset
        if let at = me.position.updatedAt, !me.isPaused {
            mine += me.speed * min(max(now.timeIntervalSince(at), 0), 30)
        }
        return mine
    }

    /// Seconds to cover `distance` at my current speed; nil when unknown or barely moving.
    func secondsToCover(_ distance: Double) -> Double? {
        guard let myCarId, let me = convoy.convoy.first(where: { $0.id == myCarId }), me.speed > 1 else { return nil }
        return distance / me.speed
    }
}

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
                        .padding(.trailing, Spacing.tight)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(alert.title), \(ConvoyFormat.distance(distance)). Show it on the map")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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
                    .padding(.trailing, Spacing.tight)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(alert.title), \(alert.body), \(ConvoyFormat.distance(distance))")
            .accessibilityIdentifier("stopapproach.pill")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

extension Color {
    /// Blue of the planned-stop pill on its dark banner (#64B5FF on the canvas).
    static let ikutPillBlue = Color(red: 0.39, green: 0.71, blue: 1.0)
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
                    .padding(.trailing, Spacing.tight)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([title, subtitle, ConvoyFormat.distance(distance)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityIdentifier("catchup.pill")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// "Passed the debris", for a few seconds once the hazard being followed is behind.
struct PassedBanner: View {
    let text: String

    var body: some View {
        DarkBanner(title: text, symbol: "checkmark", circle: .green)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
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
