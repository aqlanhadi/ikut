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
        #expect(Motion.follow(interval: 2, reduceMotion: true) == Motion.reduced)
        #expect(Motion.camera(reduceMotion: true) == nil)
        #expect(Motion.reduced == .easeInOut(duration: 0.2))
    }

    @Test func followNeverGetsAZeroInterval() {
        #expect(Motion.follow(interval: 0, reduceMotion: false) == .linear(duration: 0.05))
    }
}
