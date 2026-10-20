import SwiftUI

extension TripMapModel {
    /// Meters from my car to a hazard along the main route, carried forward from my last fix at my
    /// speed so it counts down between fixes. Nil when the hazard isn't on the main route or my car
    /// isn't in the convoy yet. Negative once passed.
    func approachDistance(eventId: String, now: Date = Date()) -> Double? {
        guard let hazard = hazards.markers.first(where: { $0.id == eventId })?.mainOffset,
              let myCarId, let me = convoy.convoy.first(where: { $0.id == myCarId }) else { return nil }
        var mine = me.convoyOffset
        if let at = me.position.updatedAt, !me.isPaused {
            mine += me.speed * min(max(now.timeIntervalSince(at), 0), 30)
        }
        return hazard - mine
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
                        .padding(.trailing, 6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(alert.title), \(ConvoyFormat.distance(distance)). Show it on the map")
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
