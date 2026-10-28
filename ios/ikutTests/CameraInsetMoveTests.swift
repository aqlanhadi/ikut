import SwiftUI
import Testing
@testable import ikut

/// D67: what a change of what the map can see does to the driving camera (`CameraInsetMove`).
struct CameraInsetMoveTests {
    typealias Inputs = CameraInsetMove.Inputs

    private let car = MapCoordinate(latitude: 3.139, longitude: 101.687)
    private var follow: CameraTarget { .follow(center: car, distance: 2_500) }
    private let fit = CameraTarget.fit(GeoRegion(center: MapCoordinate(latitude: 3.2, longitude: 101.7), latitudeSpan: 0.3, longitudeSpan: 0.2))
    /// An 800 pt frame with the folded sheet's 150 pt under it: the strip is 0-650 and my car in its middle, 325.
    private let frame: CGFloat = 800

    private func inputs(_ target: CameraTarget?, top: CGFloat = 0, bottom: CGFloat = 150) -> Inputs {
        Inputs(target: target, top: top, bottom: bottom)
    }

    @Test func aBannerWithMyCarStillComfortablyInViewMovesNothing() {
        // A 100 pt pill: the strip is 100-650 and its middle 60% is 210-540; the car is at 325.
        let plan = CameraInsetMove.plan(old: inputs(follow), new: inputs(follow, top: 100), frameHeight: frame, aimedTop: 0)
        #expect(plan == nil)
    }

    @Test func aBannerThatPushesMyCarOutOfTheMiddleMovesOnceOnTheBannersMotion() {
        let plan = CameraInsetMove.plan(old: inputs(follow), new: inputs(follow, top: 400), frameHeight: frame, aimedTop: 0)
        #expect(plan == CameraInsetMove.Plan(targetChanged: false, cause: .banner))
    }

    @Test func theBannerLeavingAfterOneThatMovedNothingMovesNothing() {
        // The car never moved: still where the camera aimed with no banner (aimedTop 0).
        let plan = CameraInsetMove.plan(old: inputs(follow, top: 100), new: inputs(follow), frameHeight: frame, aimedTop: 0)
        #expect(plan == nil)
    }

    @Test func aBannerAfterAMoveThatAimedUnderTheOldBannerKnowsWhereTheCarIs() {
        // Aimed under a 300 pt banner: the strip 300-650, the car at 475. A second banner of 380 makes the strip
        // 380-650 with 60% at 407-623: still comfortable. 500 makes it 500-650, 60% at 530-620: the car is out.
        #expect(CameraInsetMove.plan(old: inputs(follow, top: 300), new: inputs(follow, top: 380), frameHeight: frame, aimedTop: 300) == nil)
        #expect(CameraInsetMove.plan(old: inputs(follow, top: 300), new: inputs(follow, top: 500), frameHeight: frame, aimedTop: 300)?.cause == .banner)
    }

    @Test func theComfortZoneIsTheMiddleSixtyPercent() {
        // Strip 0-600, car aimed at 300: always comfortable. Strip shrunk from the top to 400-600: zone 440-560, car 300 out.
        #expect(CameraInsetMove.carIsComfortable(aimedTop: 0, top: 0, bottom: 200, frameHeight: 800))
        #expect(!CameraInsetMove.carIsComfortable(aimedTop: 0, top: 400, bottom: 200, frameHeight: 800))
        // Nothing visible: not comfortable.
        #expect(!CameraInsetMove.carIsComfortable(aimedTop: 0, top: 700, bottom: 200, frameHeight: 800))
    }

    @Test func aBannerOverTheWholeConvoyFitStillRefitsIt() {
        let plan = CameraInsetMove.plan(old: inputs(fit), new: inputs(fit, top: 100), frameHeight: frame, aimedTop: 0)
        #expect(plan == CameraInsetMove.Plan(targetChanged: false, cause: .banner))
    }

    @Test func theSheetFoldingOrUnfoldingOrACardOpeningMovesOnceOnTheSheetsMotion() {
        let unfolded = CameraInsetMove.plan(old: inputs(follow), new: inputs(follow, bottom: 450), frameHeight: frame, aimedTop: 0)
        #expect(unfolded == CameraInsetMove.Plan(targetChanged: false, cause: .sheet))
        let folded = CameraInsetMove.plan(old: inputs(follow, bottom: 450), new: inputs(follow), frameHeight: frame, aimedTop: 0)
        #expect(folded == CameraInsetMove.Plan(targetChanged: false, cause: .sheet))
        // Even a small change of the sheet (a car joined, the text grew): the frame itself may have changed with it.
        let small = CameraInsetMove.plan(old: inputs(follow), new: inputs(follow, bottom: 160), frameHeight: frame, aimedTop: 0)
        #expect(small?.cause == .sheet)
    }

    @Test func aSheetAndABannerInOneUpdateAreOneMoveOnTheSheetsMotion() {
        let plan = CameraInsetMove.plan(old: inputs(follow), new: inputs(follow, top: 100, bottom: 450), frameHeight: frame, aimedTop: 0)
        #expect(plan == CameraInsetMove.Plan(targetChanged: false, cause: .sheet))
    }

    @Test func theAimMovingWithABannerInTheSameUpdateIsOneMoveWithTheBannerKept() {
        let moved = MapCoordinate(latitude: car.latitude + 0.001, longitude: car.longitude)
        let plan = CameraInsetMove.plan(
            old: inputs(follow), new: inputs(.follow(center: moved, distance: 2_500), top: 100), frameHeight: frame, aimedTop: 0)
        #expect(plan == CameraInsetMove.Plan(targetChanged: true, cause: .banner))
    }

    @Test func aFollowStepOrAModeSwitchMovesAsBefore() {
        let moved = MapCoordinate(latitude: car.latitude + 0.001, longitude: car.longitude)
        #expect(CameraInsetMove.plan(old: inputs(follow), new: inputs(.follow(center: moved, distance: 2_500)), frameHeight: frame, aimedTop: 0)
                == CameraInsetMove.Plan(targetChanged: true, cause: .none))
        #expect(CameraInsetMove.plan(old: inputs(follow), new: inputs(fit), frameHeight: frame, aimedTop: 0)
                == CameraInsetMove.Plan(targetChanged: true, cause: .none))
    }

    @Test func nothingChangedOrNothingToAimAtMovesNothing() {
        #expect(CameraInsetMove.plan(old: inputs(follow), new: inputs(follow), frameHeight: frame, aimedTop: 0) == nil)
        // A free camera has no target: the sheet or a banner moving leaves the map where the person put it.
        #expect(CameraInsetMove.plan(old: inputs(nil), new: inputs(nil, bottom: 450), frameHeight: frame, aimedTop: 0) == nil)
        #expect(CameraInsetMove.plan(old: inputs(follow), new: inputs(nil), frameHeight: frame, aimedTop: 0) == nil)
    }

    // MARK: How the move is made

    @Test func theCoverAloneIsNeverAFlightButTheAimMayBe() {
        let sheet = CameraInsetMove.Plan(targetChanged: false, cause: .sheet)
        // The cover alone: a short move on its own motion, even when pacing would call it a flight.
        #expect(CameraInsetMove.action(sheet, paced: .fly, flying: false) == .nudge(.sheet))
        #expect(CameraInsetMove.action(sheet, paced: .nudge, flying: false) == .nudge(.sheet))
        // While a flight is in the air it lands on the new aim, with no move after the landing.
        #expect(CameraInsetMove.action(sheet, paced: .hold, flying: true) == .retarget)
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: false, cause: .banner), paced: .fly, flying: true) == .retarget)
        // The aim moving a lot (a hazard framed as the sheet folds) is the flight, once.
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: true, cause: .sheet), paced: .fly, flying: false) == .fly)
        // The aim moving a little keeps the cause's motion; mid-flight it joins the landing; with no cause it waits.
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: true, cause: .banner), paced: .nudge, flying: false) == .nudge(.banner))
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: true, cause: .banner), paced: .hold, flying: true) == .retarget)
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: true, cause: .none), paced: .hold, flying: true) == .hold)
        #expect(CameraInsetMove.action(CameraInsetMove.Plan(targetChanged: true, cause: .none), paced: .nudge, flying: false) == .nudge(.none))
    }

    @Test func theCameraRidesTheMotionOfWhatMovedIt() {
        #expect(CameraInsetMove.animation(.sheet, reduceMotion: false) == Motion.sheet(reduceMotion: false))
        #expect(CameraInsetMove.animation(.banner, reduceMotion: false) == Motion.banner(reduceMotion: false))
        #expect(CameraInsetMove.animation(.none, reduceMotion: false) == DrivingGlance.cameraAnimation(reduceMotion: false))
        // With Reduce Motion the camera jumps, as every camera move.
        for cause in [CameraInsetMove.Cause.none, .sheet, .banner] {
            #expect(CameraInsetMove.animation(cause, reduceMotion: true) == nil)
        }
    }
}
