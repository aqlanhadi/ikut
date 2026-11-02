import SwiftUI

/// The close-up of the convoy: my car (bigger, white ring) among the others, the next stop as a ring, the hazard as a
/// diamond, all centred on one 20 pt line, with three small dots at each end (the route goes on; note 18). No start,
/// no destination, no coordinates.
struct ActivityTrack: View {
    let state: ConvoyActivityAttributes.ContentState
    var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            ends
            GeometryReader { box in
                let w = box.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.2)).frame(height: 4)
                    Capsule().fill(dimmed ? ActivityPalette.grey : .white)
                        .frame(width: w * (state.cars.first(where: \.isMine)?.at ?? 0.5), height: 4)
                    if let ring = state.stopRing {
                        Circle().strokeBorder(.white, lineWidth: 2.5).background(Circle().fill(ActivityPalette.trackGap))
                            .frame(width: 14, height: 14).offset(x: w * ring - 7)
                    }
                    if let hazard = state.hazardMark {
                        Rectangle().fill(ActivityPalette.yellow).frame(width: 10, height: 10)
                            .rotationEffect(.degrees(45)).offset(x: w * hazard - 5)
                    }
                    ForEach(Array(state.cars.sorted { !$0.isMine && $1.isMine }.enumerated()), id: \.offset) { _, car in
                        let d: CGFloat = car.isMine ? 18 : 14
                        Circle().fill(ActivityPalette.hex(car.color) ?? ActivityPalette.accent)
                            .overlay(Circle().strokeBorder(car.isMine ? .white : ActivityPalette.trackGap, lineWidth: 2))
                            .frame(width: d, height: d).offset(x: w * car.at - d / 2)
                    }
                }
                .frame(height: ActivitySize.trackHeight)
                .opacity(dimmed ? 0.5 : 1)
            }
            ends
        }
        .frame(height: ActivitySize.trackHeight)
        .accessibilityHidden(true)
    }

    private var ends: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in Circle().fill(Color.white.opacity(0.4)).frame(width: 4, height: 4) }
        }
    }
}
