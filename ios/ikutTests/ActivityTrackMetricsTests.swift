import Testing
@testable import ikut

/// The track's sizes follow from the bar's height, so the bar, the dots and the marks read as one drawing (D3 note 18).
struct ActivityTrackMetricsTests {
    typealias M = ActivityTrackMetrics

    @Test func endDotsAreTheBarsHeightAndGap() {
        #expect(M.endDotSize == M.bar)
        #expect(M.endSpacing == M.bar)
    }

    @Test func endDotsFadeAwayFromTheBar() {
        #expect(M.endFade.count == M.endDots)
        #expect(M.endFade.first == 1)
        #expect(zip(M.endFade, M.endFade.dropFirst()).allSatisfy { $0 > $1 })
        #expect(M.endFade.last! > 0)
    }

    @Test func carsShareOneRingAndMineIsOneStepBigger() {
        let (other, mine, disc, ring): (Double, Double, Double, Double) = (M.carSize(isMine: false), M.carSize(isMine: true), M.disc, M.ring)
        #expect(other == disc + 2 * ring)
        #expect(mine == other + 2 * ring)
        #expect(M.base == 14)
        #expect(M.mine == 18)
    }

    @Test func stopRingAndHazardReachTheBaseSize() {
        #expect(abs(M.diamondSide * 2.0.squareRoot() - M.base) < 0.0001)
    }

    @Test func everythingFitsTheTwentyPointLine() {
        #expect(M.mine <= ActivitySize.trackHeight)
        #expect(M.bar < M.base)
    }
}
