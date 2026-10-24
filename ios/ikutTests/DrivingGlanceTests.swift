import Foundation
import SwiftUI
import Testing
@testable import ikut

struct DrivingGlanceTests {
    @Test func legalInsetSitsTenPointsAboveTheFoldedSheet() {
        #expect(DrivingGlance.legalInset(foldedSheetHeight: 180) == 190)
        #expect(DrivingGlance.legalInset(foldedSheetHeight: 0) == 0)
    }

    @Test func modeControlFadesWhileTheSheetIsTall() {
        #expect(DrivingGlance.modeControlOpacity(panelExpanded: true) == 0)
        #expect(DrivingGlance.modeControlOpacity(panelExpanded: false) == 1)
    }

    @Test func reduceMotionTurnsASlideIntoAFade() {
        #expect(DrivingGlance.motion(edge: .top, reduceMotion: false) == .move(.top))
        #expect(DrivingGlance.motion(edge: .top, reduceMotion: true) == .fade)
    }

    @Test func reduceMotionStopsTheCameraFlying() {
        #expect(DrivingGlance.cameraAnimation(reduceMotion: true) == nil)
        #expect(DrivingGlance.cameraAnimation(reduceMotion: false) != nil)
        #expect(DrivingGlance.animation(.snappy, reduceMotion: true) == .linear(duration: 0.2))
        #expect(DrivingGlance.animation(.snappy, reduceMotion: false) == .snappy)
    }

    @Test func passedHoldsWhileVoiceOverRuns() {
        #expect(DrivingGlance.passedDuration(voiceOver: false) == .seconds(3))
        #expect(DrivingGlance.passedDuration(voiceOver: true) == nil)
    }

    @Test func anErrorStaysUntilItsCauseClearsOrItIsClosed() {
        var error = GlanceError()
        error.show("Could not reach the convoy.", cause: .send)
        error.resolve(.pause)
        #expect(error.message == "Could not reach the convoy.")
        error.resolve(.send)
        #expect(error.message == nil)

        error.show("Could not pause.", cause: .pause)
        error.close()
        #expect(error.message == nil)
        #expect(error.cause == nil)
    }
}
