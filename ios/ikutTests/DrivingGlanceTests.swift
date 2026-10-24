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

struct DrivingGlanceWiringTests {
    @Test func aLaterSuccessClearsASendError() {
        var error = GlanceError()
        error.actionFinished(failure: "Could not reach the convoy.")
        #expect(error.message != nil)
        error.actionFinished(failure: nil)
        #expect(error.message == nil)
    }

    @Test func aSuccessLeavesAPauseErrorAlone() {
        var error = GlanceError()
        error.show("Could not pause.", cause: .pause)
        error.actionFinished(failure: nil)
        #expect(error.message == "Could not pause.")
    }

    @Test func theStopPillAnnouncesOncePerRequestWhateverItsDistance() {
        let near = StopPill.question(eventId: "e1", symbol: "fuelpump", title: "Wyna needs fuel · 2 km behind", detail: "Car 2 · asked 1 min ago")
        let far = StopPill.question(eventId: "e1", symbol: "fuelpump", title: "Wyna needs fuel · 3 km behind", detail: "Car 2 · asked 2 min ago")
        let other = StopPill.question(eventId: "e2", symbol: "fuelpump", title: "Wyna needs fuel", detail: "Car 2")
        #expect(near.id == far.id)
        #expect(near.id != other.id)
    }
}
