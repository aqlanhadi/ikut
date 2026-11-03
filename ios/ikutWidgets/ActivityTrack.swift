import SwiftUI

/// The close-up of the convoy: my car (one size step bigger, white ring) among the others, the next stop as a ring, the
/// hazard as a diamond, all centred on one 20 pt line, with a row of dots at each end that is the bar going on and
/// fading out (the route goes on; note 18). Every size comes from the bar's height (`ActivityTrackMetrics`). No start,
/// no destination, no coordinates.
struct ActivityTrack: View {
    typealias M = ActivityTrackMetrics
    let state: ConvoyActivityAttributes.ContentState
    var dimmed = false

    /// One uniform colour for the bar and both rows of end dots: nothing is filled up to my car, so the bar can't read
    /// as trip progress (the window is centred on my car, not on a route). Stale is the greyed, fainter look.
    private var track: Color { (dimmed ? ActivityPalette.grey : Color.white).opacity(M.trackOpacity) }

    var body: some View {
        HStack(spacing: M.endSpacing) {
            ends(reversed: false)
            GeometryReader { box in
                let w = box.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(track).frame(height: M.bar)
                    if let ring = state.stopRing {
                        Circle().strokeBorder(.white, lineWidth: M.ring).background(Circle().fill(ActivityPalette.trackGap))
                            .frame(width: M.base, height: M.base).offset(x: w * ring - M.base / 2)
                    }
                    if let hazard = state.hazardMark {
                        Rectangle().fill(ActivityPalette.yellow).frame(width: M.diamondSide, height: M.diamondSide)
                            .rotationEffect(.degrees(45)).offset(x: w * hazard - M.diamondSide / 2)
                    }
                    ForEach(Array(state.cars.sorted { !$0.isMine && $1.isMine }.enumerated()), id: \.offset) { _, car in
                        let d = M.carSize(isMine: car.isMine)
                        Circle().fill(ActivityPalette.hex(car.color) ?? ActivityPalette.accent)
                            .overlay(Circle().strokeBorder(car.isMine ? .white : ActivityPalette.trackGap, lineWidth: M.ring))
                            .frame(width: d, height: d).offset(x: w * car.at - d / 2)
                    }
                }
                .frame(height: ActivitySize.trackHeight)
            }
            ends(reversed: true)
        }
        .frame(height: ActivitySize.trackHeight)
        .opacity(dimmed ? M.dimmedOpacity : 1)
        .accessibilityHidden(true)
    }

    /// The bar going on: dots the bar's height and gap in the bar's colour, each fainter than the last, the same on both sides. The left end is listed far dot first, so the nearest dot is next to the bar on both sides.
    private func ends(reversed: Bool) -> some View {
        let fades = reversed ? M.endFade : Array(M.endFade.reversed())
        return HStack(spacing: M.endSpacing) {
            ForEach(Array(fades.enumerated()), id: \.offset) { _, f in
                Circle().fill(track.opacity(f)).frame(width: M.endDotSize, height: M.endDotSize)
            }
        }
    }
}
