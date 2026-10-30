import Foundation
import SwiftUI
import Testing
@testable import ikut

/// The one map bottom padding for the lobby and driving (D101), and the camera room that works inside it.
struct MapPaddingTests {
    // MARK: the padding

    /// D114: the padding is the minimum resting sheet's line, Home's short list sheet and its gap, at the text size.
    @Test(arguments: [CGFloat(470), 560, 658, 900])
    func thePaddingIsHomesShortSheetLineAtTheTextSize(scaledMedium: CGFloat) {
        let scale = scaledMedium / LobbySheet.compactHeight
        let compact = HomeSheet.compact(scaled: HomeSheet.compactHeight * scale)
        // The scale is computed in a different order than the code's, so compare within rounding.
        #expect(abs(LobbySheet.mapPadding(scaledMedium: scaledMedium) - (compact + BottomSheet.detentExtra)) < 1e-9)
        #expect(abs(LobbySheet.mapPadding(scaledMedium: scaledMedium) - HomeSheet.reach(.list, compact: compact)) < 1e-9)
    }

    @Test func thePaddingAtTheDefaultAndExtremeSizes() {
        #expect(LobbySheet.defaultMapPadding == HomeSheet.compactHeight + BottomSheet.detentExtra)
        // Capped at 1.5x like the collapsed stop, and never 0.
        #expect(LobbySheet.mapPadding(scaledMedium: 5000) == 239 * 1.5 + BottomSheet.detentExtra)
        #expect(LobbySheet.mapPadding(scaledMedium: 0) > 0)
        // Never above the lobby's medium sheet, so the lobby's sheet always covers the logo.
        for scaled in [CGFloat(470), 560, 658, 900] {
            #expect(LobbySheet.mapPadding(scaledMedium: scaled)
                    <= LobbySheet.cover(compact: LobbySheet.compact(scaled: scaled)).bottom)
        }
    }

    // MARK: one constant for every screen (D109)

    /// The padding is a function of the text size alone (`TripMapSpec` has no padding field, no layer sets one), so a
    /// mode switch (Leave, Back to trips, End, Start trip) can never change it. At each text size, every Home mode's
    /// sheet and the lobby's are read relative to it, and the strip's bottom edge on screen (the padding plus the
    /// fraction of the frame) is the cover itself, as before the padding moved.
    @Test(arguments: [CGFloat(470), 560, 658, 900])
    func everyScreenSharesOnePaddingAndKeepsItsStripEdge(scaledMedium: CGFloat) {
        let padding = LobbySheet.mapPadding(scaledMedium: scaledMedium)
        let scale = scaledMedium / LobbySheet.compactHeight
        let compact = HomeSheet.compact(scaled: HomeSheet.compactHeight * scale)
        let frame = Double(874 - padding)
        for mode in [HomeSheet.Mode.list, .whereTo, .newTrip, .leftTrip, .join] {
            let cover = HomeSheet.cover(mode, compact: compact)
            let reach = HomeSheet.reach(mode, compact: compact)
            let insets = TripsHomeView.obscured(mapHeight: 874, sheet: cover.bottom, reach: reach, padding: padding)
            #expect(abs(Double(padding) + insets.bottom * frame - Double(max(cover.bottom, reach))) < 1e-9, "\(mode)")
            #expect(abs(insets.top * frame - 110) < 1e-9)
            let create = HomeSheet.createInsets(mapHeight: 874, sheet: cover.bottom, compact: compact, padding: padding)
            let cleared = max(HomeSheet.reach(.list, compact: compact), cover.bottom + HomeSheet.createMargin)
            #expect(abs(Double(padding) + create.bottom * frame - Double(cleared)) < 1e-9, "\(mode)")
        }
        // The lobby keeps the trip above its medium sheet: positive now, the edge still its sheet's top.
        let lobbyCompact = LobbySheet.compact(scaled: scaledMedium)
        let lobby = LobbySheet.cover(compact: lobbyCompact)
        let fraction = LobbyMapLogic.bottomFraction(mapHeight: 874, safeTop: 62, cover: lobby.bottom, bottomPadding: padding)
        #expect(fraction > 0)
        #expect(abs(Double(padding) + fraction * frame - Double(lobby.bottom)) < 1e-9)
    }

    /// The list's camera at a scaled text size: the strip's bottom edge, measured from the screen's bottom, is the list's
    /// reach (the sheet and its gap), whatever the padding is, so the camera is not framed by the default padding.
    @Test(arguments: [CGFloat(300), 450], [CGFloat(470), 658])
    @MainActor func theListsStripEdgeIsItsReachAtAScaledTextSize(compact: CGFloat, scaledMedium: CGFloat) {
        let padding = LobbySheet.mapPadding(scaledMedium: scaledMedium)
        let reach = HomeSheet.reach(.list, compact: compact)
        let insets = TripsHomeView.obscured(mapHeight: 874, reach: reach, padding: padding)
        let frame = Double(874 - padding)
        // Frame bottom is `padding` above the screen's bottom; the strip's bottom edge is `bottom * frame` above that.
        let edgeFromBottom = Double(padding) + insets.bottom * frame
        #expect(abs(edgeFromBottom - Double(reach)) < 1e-9)
        #expect(abs(insets.top * frame - 110) < 1e-9)
        // The entry camera takes the same numbers.
        let route = PastTripRoute(id: "r", name: "R", destinationName: "D", destinationLatitude: 5, destinationLongitude: 101,
                                  points: [[3, 101.5], [5, 101]])
        let model = HomeModel(routes: [route])
        #expect(model.entryCamera(mapHeight: 874, reach: reach, padding: padding)
            == PastTripsMapLogic.region(fitting: [route], bottomObscured: insets.bottom, topObscured: insets.top).map { .region($0) })
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
    private let coverBottom: CGFloat = 239
    private let truth = 3.1e-8

    private func room(padding: CGFloat, coverBottom: CGFloat? = nil) -> MapCameraRoom {
        let coverBottom = coverBottom ?? self.coverBottom
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

    /// Driving at the default text size (D115): the folded sheet is the convoy's own 239 (193 content plus the 46 bar),
    /// which is Home's short sheet, a gap under the padding (269), so the room's bottom is slightly negative and the logo
    /// shows above it; the unfolded one (capped at the mid stop, 470) is taller, so it is positive and covers the logo. Either way my car
    /// sits at the middle of the strip above the sheet.
    @Test(arguments: [PanelSheet.foldedEstimate + PanelSheet.barEstimate, SheetStops.midBase])
    func drivingFollowsAboveItsSheetAtTheDefaultPadding(sheet: CGFloat) {
        let padding = LobbySheet.defaultMapPadding
        let room = room(padding: padding, coverBottom: sheet)
        #expect((room.bottom < 0) == (sheet < padding))
        let centre = MapCoordinate(latitude: 3, longitude: 101)
        let y = carY(room, padding: padding, centre: centre)
        #expect(abs((y ?? 0) - Double(top + 874 - sheet) / 2) < 0.01)
        // The whole convoy fit lands in the same strip.
        let region = GeoRegion(center: centre, latitudeSpan: 0.02, longitudeSpan: 0.02)
        let fit = room.fit(region)
        let height = Double(874 - padding), perPoint = fit.latitudeSpan / height
        let fitY = height / 2 + (fit.center.latitude - region.center.latitude) / perPoint
        #expect(abs(fitY - Double(top + 874 - sheet) / 2) < 0.01)
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
