import SwiftUI
import Testing
@testable import ikut

struct MotionTests {
    @Test func normalMotionUsesTheSpec() {
        #expect(Motion.sheet(reduceMotion: false) == .smooth(duration: 0.4))
        #expect(Motion.banner(reduceMotion: false) == .snappy(duration: 0.3))
        #expect(Motion.quick(reduceMotion: false) == .easeOut(duration: 0.2))
        #expect(Motion.camera(reduceMotion: false) == .smooth(duration: 0.6))
        #expect(Motion.follow(interval: 2, reduceMotion: false) == .linear(duration: 2))
    }

    @Test func reduceMotionFadesEverythingButTheCameraJumps() {
        #expect(Motion.sheet(reduceMotion: true) == Motion.reduced)
        #expect(Motion.banner(reduceMotion: true) == Motion.reduced)
        #expect(Motion.quick(reduceMotion: true) == Motion.reduced)
        // The follow glide steps with Reduce Motion, as the camera does (D70).
        #expect(Motion.follow(interval: 2, reduceMotion: true) == nil)
        #expect(Motion.camera(reduceMotion: true) == nil)
        #expect(Motion.reduced == .easeInOut(duration: 0.2))
    }

    @Test func aFollowGlideOfNoTimeIsAStep() {
        #expect(Motion.follow(interval: 0, reduceMotion: false) == nil)
    }

    @Test func theDrivingGlanceMotionsKeepTheirTimingAndHonourReduceMotion() {
        #expect(Motion.fade == .linear(duration: 0.2))
        #expect(Motion.pill == .snappy)
        #expect(Motion.glance(reduceMotion: false) == .easeInOut(duration: 0.8))
        #expect(Motion.glance(reduceMotion: true) == nil)
        #expect(Motion.gentle(reduceMotion: false) == .smooth)
        #expect(Motion.line(reduceMotion: false) == .easeOut)
        #expect(Motion.gentle(reduceMotion: true) == Motion.reduced)
        #expect(Motion.line(reduceMotion: true) == Motion.reduced)
    }

    @Test func dimmedHasThreeSteps() {
        let amounts = [Dimmed.soft, .faded, .strong].map(\.amount)
        #expect(amounts == [0.3, 0.7, 0.9])
        #expect(amounts.allSatisfy { $0 > 0 && $0 < 1 } && amounts == amounts.sorted())
    }
}
