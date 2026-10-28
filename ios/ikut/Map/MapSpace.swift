import SwiftUI

/// What covers the one map, in points from its edges (D63 C4). `top`: what the mode lays over the map from a layer's top
/// (`MapSpace.above` below the map's): driving's pill and banners, the lobby's round button; nothing on Home. `bottom`: the one sheet at the size the
/// camera keeps clear (the convoy sheet and the stop card while driving; the lobby's medium and Home's short sheet,
/// which their tall sizes cover on purpose, #343).
struct MapCover: Equatable {
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}

/// Where the layers sit, as one proxy (the host's content) measures it: its global top, its bottom edge plus the bottom
/// safe area (the screen's bottom edge, under the home indicator), its height and its top safe area.
struct LayerFrame: Equatable {
    var minY: CGFloat = 0
    var bottomEdge: CGFloat = 0
    var height: CGFloat = 0
    var safeTop: CGFloat = 0
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
    /// Where the layers sit (measured outside the map, which ignores the safe area, so in it the insets read 0).
    private(set) var layer = LayerFrame()
    /// The top safe area over the map: the status bar, and a navigation bar while one shows.
    var safeTop: CGFloat { layer.safeTop }
    /// What covers the map, as `coverMode` last wrote it (`TripScreenModel.cover(_:from:)`).
    private(set) var cover = MapCover()
    private(set) var coverMode: TripScreenMode?

    func measure(frame: CGRect) {
        if frame != self.frame { self.frame = frame }
    }

    func measure(layer: LayerFrame) {
        if layer != self.layer { self.layer = layer }
    }

    /// How far below the map's measured top the layers start (main's `mapMinY - mapFrame.minY`): 0 while both are the
    /// safe area's frame.
    var above: CGFloat { max(layer.minY - frame.minY, 0) }
    /// From the map's measured top down to the screen's bottom edge, under the home indicator (main's
    /// `mapMaxY - mapFrame.minY`): driving's camera frame. 0 before the layers are measured.
    var fullHeight: CGFloat { layer.bottomEdge > 0 ? layer.bottomEdge - frame.minY : 0 }
    /// A layer's own height (the driving layer's `size.height` on main).
    var layerHeight: CGFloat { layer.height }

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
