import Foundation
import SwiftUI
import Testing
@testable import ikut

/// The one map bottom padding for the lobby and driving (D101), and the camera room that works inside it.
struct MapPaddingTests {
    // MARK: the padding

    @Test func thePaddingIsTheMediumSheetLineAtTheTextSize() {
        #expect(LobbySheet.mapPadding(scaledMedium: LobbySheet.compactHeight)
                == LobbySheet.compactHeight + BottomSheet.detentExtra)
        #expect(LobbySheet.mapPadding(scaledMedium: 520) == 520 + BottomSheet.detentExtra)
        // Capped like the sheet, and never 0.
        #expect(LobbySheet.mapPadding(scaledMedium: 5000) == LobbySheet.compactHeight * 1.4 + BottomSheet.detentExtra)
        #expect(LobbySheet.mapPadding(scaledMedium: 0) > 0)
    }

    @Test func theLobbyPassesItsAlreadyCappedHeightAndGetsTheSameValue() {
        // The lobby layer hands over `compact` (already capped), the driving layer the raw scaled height.
        for scaled in [CGFloat(300), 470, 520, 640, 900] {
            #expect(LobbySheet.mapPadding(scaledMedium: LobbySheet.compact(scaled: scaled))
                    == LobbySheet.mapPadding(scaledMedium: scaled))
        }
    }

    // MARK: one constant for every screen (D109)

    /// The padding is a function of the text size alone (`TripMapSpec` has no padding field, no layer sets one), so a
    /// mode switch (Leave, Back to trips, End, Start trip) can never change it. At each text size the lobby's cover is
    /// that line, and every Home mode's sheet is read relative to it: the room is the cover less the padding.
    @Test(arguments: [CGFloat(470), 560, 658, 900])
    func everyScreenSharesOnePaddingAndReadsItsCoverRelativeToIt(scaledMedium: CGFloat) {
        let padding = LobbySheet.mapPadding(scaledMedium: scaledMedium)
        let scale = LobbySheet.compact(scaled: scaledMedium) / LobbySheet.compactHeight
        let compact = HomeSheet.compact(scaled: HomeSheet.compactHeight * scale)
        #expect(LobbySheet.cover(compact: LobbySheet.compact(scaled: scaledMedium)).bottom == padding)
        for mode in [HomeSheet.Mode.list, .whereTo, .newTrip, .leftTrip, .join] {
            let cover = HomeSheet.cover(mode, compact: compact)
            let insets = TripsHomeView.obscured(mapHeight: 874, sheet: cover.bottom,
                                                reach: HomeSheet.reach(mode, compact: compact), padding: padding)
            #expect(abs(insets.bottom * Double(874 - padding)
                        - Double(max(cover.bottom, HomeSheet.reach(mode, compact: compact)) - padding)) < 1e-9)
        }
        // The same value however it is asked for: from the raw scaled height or the sheet's capped one.
        #expect(padding == LobbySheet.mapPadding(scaledMedium: LobbySheet.compact(scaled: scaledMedium)))
    }

    // MARK: the scale read off the map

    /// What MapKit reports for a camera `distance` away over a map `mapHeight` tall with `padding` at the bottom: the
    /// region of the padded frame.
    private func reportedSpan(perPoint: Double, mapHeight: CGFloat, padding: CGFloat, distance: Double) -> Double {
        perPoint * distance * Double(mapHeight - padding)
    }

    @Test func theScaleDoesNotDependOnThePadding() {
        let truth = 3.1e-8
        for padding in [CGFloat(0), 200, 304, 500] {
            let span = reportedSpan(perPoint: truth, mapHeight: 874, padding: padding, distance: 2500)
            let read = MapCameraRoom.latitudePerPointPerMeter(latitudeDelta: span, mapHeight: 874, padding: padding, distance: 2500)
            #expect(abs((read ?? 0) - truth) < 1e-12)
        }
    }

    @Test func noFrameLeftReadsNoScale() {
        #expect(MapCameraRoom.latitudePerPointPerMeter(latitudeDelta: 0.01, mapHeight: 500, padding: 500, distance: 2500) == nil)
        #expect(MapCameraRoom.latitudePerPointPerMeter(latitudeDelta: 0.01, mapHeight: 400, padding: 500, distance: 2500) == nil)
        #expect(MapCameraRoom.latitudePerPointPerMeter(latitudeDelta: 0.01, mapHeight: 874, padding: 500, distance: 0) == nil)
    }

    // MARK: the room inside the padding

    private let top: CGFloat = 130
    private let coverBottom: CGFloat = 282
    private let truth = 3.1e-8

    private func room(padding: CGFloat) -> MapCameraRoom {
        let span = reportedSpan(perPoint: truth, mapHeight: 874, padding: padding, distance: 2500)
        let scale = MapCameraRoom.latitudePerPointPerMeter(latitudeDelta: span, mapHeight: 874, padding: padding, distance: 2500)
        return MapCameraRoom(width: 402, height: max(874 - padding, 0), top: top, bottom: coverBottom - padding,
                             latitudePerPointPerMeter: scale ?? 0)
    }

    /// Where a follow target puts the car, in points from the map's top: MapKit centres the shifted camera in the padded
    /// frame, so the car sits that far below the frame's middle.
    private func carY(_ room: MapCameraRoom, padding: CGFloat, centre: MapCoordinate) -> Double? {
        guard case .follow(let to, let distance)? = room.target(.follow(center: centre, distance: 2500)) else { return nil }
        let shiftPoints = (to.latitude - centre.latitude) / (room.latitudePerPointPerMeter * distance)
        return Double(874 - padding) / 2 + shiftPoints
    }

    @Test func theBottomCanBeNegativeWhenTheCoverIsLowerThanThePadding() {
        #expect(room(padding: 500).bottom < 0)
        #expect(room(padding: 200).bottom > 0)
    }

    @Test func followPutsTheCarAtTheStripCentreForAnyPadding() {
        let centre = MapCoordinate(latitude: 3, longitude: 101)
        let stripCentre = Double(top + 874 - coverBottom) / 2
        for padding in [CGFloat(200), 304, 500] {
            let y = carY(room(padding: padding), padding: padding, centre: centre)
            #expect(abs((y ?? 0) - stripCentre) < 0.01, "padding \(padding)")
        }
    }

    @Test func fitShowsTheSameStripForAnyPadding() {
        let region = GeoRegion(center: MapCoordinate(latitude: 3, longitude: 101), latitudeSpan: 0.02, longitudeSpan: 0.02)
        let stripCentre = Double(top + 874 - coverBottom) / 2
        var perPoints: [Double] = []
        for padding in [CGFloat(200), 304, 500] {
            let fit = room(padding: padding).fit(region)
            let height = Double(874 - padding)
            let perPoint = fit.latitudeSpan / height
            perPoints.append(perPoint)
            // The region's middle lands at the strip's middle in the padded frame.
            let y = height / 2 + (fit.center.latitude - region.center.latitude) / perPoint
            #expect(abs(y - stripCentre) < 0.01, "padding \(padding)")
        }
        #expect(perPoints.allSatisfy { abs($0 - perPoints[0]) < 1e-12 })
    }

    @Test func aShortScreenAtThePaddingLeavesAFitAndAFollowUnharmed() {
        // About 667 pt tall: the frame is 167 pt; at the largest text none.
        let region = GeoRegion(center: MapCoordinate(latitude: 3, longitude: 101), latitudeSpan: 0.02, longitudeSpan: 0.02)
        for height in [CGFloat(167), 0] {
            let room = MapCameraRoom(width: 375, height: height, top: 130, bottom: 282 - 500, latitudePerPointPerMeter: 0)
            let fit = room.fit(region)
            #expect(fit.latitudeSpan.isFinite && fit.latitudeSpan > 0)
            if height == 0 { #expect(fit == region) }
            #expect(room.target(.follow(center: region.center, distance: 2500)) != nil)
        }
    }
}
