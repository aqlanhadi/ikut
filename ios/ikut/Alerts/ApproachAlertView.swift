import MapKit
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

/// The spoken approach alert, full screen (Alert.dc.html): what's ahead, a live distance, where it
/// was pinned and who reported it, then back to the map by itself after a few seconds.
struct ApproachAlertView: View {
    let alert: TripAlert
    let model: TripMapModel
    var onBack: () -> Void

    static let autoBack: TimeInterval = 6
    @State private var opened = Date()

    private var marker: HazardMarker? { model.hazards.markers.first { $0.id == alert.eventId } }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let distance = max(0, model.approachDistance(eventId: alert.eventId, now: context.date) ?? alert.distance ?? 0)
            let left = max(0, Self.autoBack - context.date.timeIntervalSince(opened))
            VStack(spacing: 0) {
                Label("Speaking now", systemImage: "speaker.wave.2.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.14), in: Capsule())

                Image(systemName: marker?.symbol ?? "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 64, height: 64)
                    .background(tint, in: Circle())
                    .padding(.top, 32)
                    .accessibilityHidden(true)
                Text(alert.title)
                    .font(.title.weight(.semibold))
                    .padding(.top, 18)
                distanceText(distance)
                    .padding(.top, 4)
                if let seconds = model.secondsToCover(distance) {
                    Text("In about \(Int(seconds.rounded())) s")
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }

                pinnedCard
                    .padding(.top, 28)

                Spacer(minLength: 12)

                Text("Read aloud through the car speakers. No need to touch the phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)
                Button(action: onBack) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        GeometryReader { proxy in
                            Capsule()
                                .fill(.white.opacity(0.22))
                                .frame(width: proxy.size.width * (1 - left / Self.autoBack))
                        }
                        Text("Back to Map in \(Int(left.rounded(.up)))s")
                            .font(.headline)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity)
                    }
                    .frame(height: 50)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to Map")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        .task {
            opened = Date()
            try? await Task.sleep(for: .seconds(Self.autoBack))
            if !Task.isCancelled { onBack() }
        }
    }

    private var tint: Color {
        switch alert.severity {
        case .high: .orange
        case .medium: .yellow
        case .low: .white
        }
    }

    /// "480 m" in big rounded digits, to the nearest 10 m.
    private func distanceText(_ meters: Double) -> some View {
        let shown = Int((meters / 10).rounded()) * 10
        return (Text("\(shown)").font(.system(size: 112, weight: .bold, design: .rounded))
            + Text(" m").font(.system(size: 40, weight: .bold, design: .rounded)))
            .kerning(-2)
            .monospacedDigit()
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText(countsDown: true))
            .accessibilityLabel("\(shown) meters ahead")
    }

    /// A small map with the hazard where it was reported and my car, then who reported it.
    private var pinnedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let marker {
                let hazard = CLLocationCoordinate2D(latitude: marker.latitude, longitude: marker.longitude)
                Map(initialPosition: .automatic, interactionModes: []) {
                    Annotation("", coordinate: hazard) {
                        Image(systemName: marker.symbol)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 30, height: 30)
                            .background(tint, in: Circle())
                            .overlay(Circle().strokeBorder(.black, lineWidth: 2.5))
                    }
                    if let me = myCoordinate {
                        Annotation("", coordinate: me) {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        }
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .frame(height: 130)
                .overlay(alignment: .topLeading) {
                    Text("Pinned where it was reported")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .padding(8)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(alert.body)
                    .font(.subheadline.weight(.semibold))
                Text("“\(alert.spoken)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var myCoordinate: CLLocationCoordinate2D? {
        guard let myCarId = model.myCarId,
              let me = model.convoy.convoy.first(where: { $0.id == myCarId }) else { return nil }
        return CLLocationCoordinate2D(latitude: me.position.location.latitude, longitude: me.position.location.longitude)
    }
}

/// After the full alert goes back to the map (MapHazard.dc.html): the hazard ahead as a small pill
/// with a live distance; tap to open the full alert again.
struct ApproachPill: View {
    let alert: TripAlert
    let model: TripMapModel
    var onOpen: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let distance = max(0, model.approachDistance(eventId: alert.eventId, now: context.date) ?? alert.distance ?? 0)
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Color.yellow, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(alert.title).font(.body.weight(.semibold))
                        if let seconds = model.secondsToCover(distance) {
                            Text("In about \(Int(seconds.rounded())) s")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(ConvoyFormat.distance(distance))
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.yellow)
                }
                .foregroundStyle(.white)
                .padding(.leading, 10)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
                .background(Color(white: 0.11).opacity(0.96), in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(alert.title), \(ConvoyFormat.distance(distance)). Open the alert")
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
