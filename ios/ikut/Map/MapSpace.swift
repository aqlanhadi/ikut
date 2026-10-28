import SwiftUI

/// What covers the one map, in points from its edges (D63 C4). `top`: what the mode lays over the map from a layer's top
/// (`MapSpace.above` below the map's): driving's pill and banners, the lobby's round button; nothing on Home. `bottom`: the one sheet at the size the
/// camera keeps clear (the convoy sheet and the stop card while driving; the lobby's medium and Home's short sheet,
/// which their tall sizes cover on purpose, #343).
struct MapCover: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

/// The one map's space (D63 C4): its frame, the status bar over it and what covers it, measured once by the host and
/// written by the mode on screen, for Home's, the lobby's and driving's cameras to read instead of measuring their own.
/// Observed apart from the camera and the sheet, and written only when a value changes, so a banner while driving
/// redraws nothing on the other layers.
@Observable @MainActor
final class MapSpace {
    /// The map's frame on screen as the host measures it. It runs under the status bar and the home indicator, but this
    /// reads the safe area's frame (y 62, 778 tall on an iPhone 17), as every camera has always measured it.
    private(set) var frame: CGRect = .zero
    /// The top safe area over the map (the status bar, and a navigation bar while one shows), measured outside the map.
    private(set) var safeTop: CGFloat = 0
    /// The bottom safe area (the home indicator), which the map runs on under.
    private(set) var safeBottom: CGFloat = 0
    /// What covers the map, as `coverMode` last wrote it (`TripScreenModel.cover(_:from:)`).
    private(set) var cover = MapCover()
    private(set) var coverMode: TripScreenMode?

    func measure(frame: CGRect) {
        if frame != self.frame { self.frame = frame }
    }

    func measure(safeTop: CGFloat, safeBottom: CGFloat = 0) {
        if safeTop != self.safeTop { self.safeTop = safeTop }
        if safeBottom != self.safeBottom { self.safeBottom = safeBottom }
    }

    /// How far below the map's measured top a layer starts (it keeps to the top safe area): 0 while the frame is the safe
    /// area's.
    var above: CGFloat { max(safeTop - frame.minY, 0) }
    /// From the map's measured top down to the screen's bottom edge, under the home indicator: driving's camera frame.
    var fullHeight: CGFloat { frame.height > 0 ? frame.maxY + safeBottom - frame.minY : 0 }
    /// A layer's own height: from its top (`above`) to the bottom of the safe area.
    var layerHeight: CGFloat { max(frame.height - above, 0) }

    /// What `mode` wrote, nil while another mode's cover is the last one written.
    func cover(in mode: TripScreenMode) -> MapCover? { coverMode == mode ? cover : nil }

    /// Writes `cover` for `mode`; true when it changed what the camera keeps clear.
    func write(_ cover: MapCover, mode: TripScreenMode) -> Bool {
        if coverMode != mode { coverMode = mode }
        guard cover != self.cover else { return false }
        self.cover = cover
        return true
    }
}
