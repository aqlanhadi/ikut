import CoreLocation
import Testing
@testable import ikut

struct RouteGeometryTests {
    private static let r = RouteLine.earthRadius
    private static let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)

    /// Moves `north`/`east` meters from `c` (local planar, fine at these scales).
    private func move(_ c: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: c.latitude + north / Self.r * 180 / .pi,
            longitude: c.longitude + east / (Self.r * cos(c.latitude * .pi / 180)) * 180 / .pi
        )
    }

    private func eastLine(from start: CLLocationCoordinate2D = origin, km: Int, step: Double = 1000) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: Double(km) * 1000, by: step).map { move(start, east: $0) }
    }

    private func close(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    @Test func lengthMatchesHaversineAlongMeridian() {
        let pts = (0...10).map { CLLocationCoordinate2D(latitude: 1.0 + Double($0) * 0.1, longitude: 103.0) }
        let line = RouteLine(pts)
        let expected = RouteLine.haversine(pts[0], pts[10])
        #expect(abs(line.length - expected) / expected < 0.005)
        #expect(abs(line.length - 1.1119e5) / 1.1119e5 < 0.005)
    }

    @Test func lengthMatchesHaversineAlongParallel() {
        let pts = (0...10).map { CLLocationCoordinate2D(latitude: 45, longitude: Double($0) * 0.1) }
        let line = RouteLine(pts)
        let expected = RouteLine.haversine(pts[0], pts[10])
        #expect(abs(line.length - expected) / expected < 0.005)
    }

    @Test func pointOnRoute() throws {
        let line = RouteLine(eastLine(km: 10))
        let p = try #require(line.project(move(Self.origin, east: 3500)))
        #expect(close(p.offset, 3500, 1))
        #expect(p.distance < 1)
        #expect(p.segmentIndex == 3)
        #expect(p.clamp == .none)
    }

    @Test func pointOffRoute() throws {
        let line = RouteLine(eastLine(km: 10))
        let p = try #require(line.project(move(Self.origin, north: 100, east: 4200)))
        #expect(close(p.distance, 100, 1))
        #expect(close(p.offset, 4200, 1))
        #expect(close(p.coordinate.latitude, Self.origin.latitude, 1e-6))
    }

    @Test func clampsBeforeStartAndAfterEnd() throws {
        let line = RouteLine(eastLine(km: 5))
        let before = try #require(line.project(move(Self.origin, east: -300)))
        #expect(before.clamp == .beforeStart)
        #expect(before.offset == 0)
        #expect(close(before.distance, 300, 1))
        let after = try #require(line.project(move(Self.origin, north: 40, east: 5400)))
        #expect(after.clamp == .afterEnd)
        #expect(close(after.offset, line.length, 0.001))
        #expect(close(after.distance, hypot(400, 40), 1))
    }

    @Test func duplicatePointsAreHarmless() throws {
        var pts = eastLine(km: 4)
        pts.insert(pts[2], at: 2)
        pts.insert(pts[0], at: 0)
        let line = RouteLine(pts)
        #expect(close(line.length, 4000, 5))
        let p = try #require(line.project(move(Self.origin, east: 2500)))
        #expect(close(p.offset, 2500, 1))
        #expect(p.distance < 1)
    }

    @Test func doublingBackUsesHint() throws {
        let out = eastLine(km: 5)
        let route = out + out.reversed().dropFirst()
        let line = RouteLine(route)
        let spot = move(Self.origin, east: 2000)
        let noHint = try #require(line.project(spot))
        #expect(close(noHint.offset, 2000, 1))
        let hinted = try #require(line.project(spot, hint: 7))
        #expect(close(hinted.offset, 8000, 1))
        #expect(hinted.segmentIndex == 7)
        let outbound = try #require(line.project(spot, hint: 1))
        #expect(close(outbound.offset, 2000, 1))
    }

    @Test func hintFallsBackToFullScanWhenFarOff() throws {
        let line = RouteLine(eastLine(km: 200, step: 500))
        let p = try #require(line.project(move(Self.origin, north: 20, east: 150_000), hint: 3))
        #expect(close(p.offset, 150_000, 2))
        #expect((299...300).contains(p.segmentIndex))
    }

    @Test func coordinateAtOffsetRoundTrip() throws {
        let pts = (0...200).map { i in
            CLLocationCoordinate2D(latitude: 3 + Double(i) * 0.002, longitude: 101 + sin(Double(i) / 10) * 0.01)
        }
        let line = RouteLine(pts)
        for offset in stride(from: 0.0, through: line.length, by: line.length / 37) {
            let c = try #require(line.coordinate(atOffset: offset))
            let p = try #require(line.project(c))
            #expect(close(p.offset, offset, 1))
            #expect(p.distance < 1)
        }
        let beyond = try #require(line.coordinate(atOffset: line.length + 500))
        #expect(RouteLine.haversine(beyond, pts[200]) < 0.001)
        #expect(line.distance(fromOffset: 100, toOffset: 350) == 250)
        #expect(line.distance(fromOffset: 350, toOffset: 100) == -250)
    }

    @Test func emptyAndSinglePointRoutes() throws {
        let empty = RouteLine([])
        #expect(empty.project(Self.origin) == nil)
        #expect(empty.coordinate(atOffset: 10) == nil)
        #expect(empty.length == 0)
        #expect(empty.mergeOffset(of: RouteLine(eastLine(km: 2))) == nil)

        let single = RouteLine([Self.origin])
        let p = try #require(single.project(move(Self.origin, north: 70)))
        #expect(p.offset == 0)
        #expect(close(p.distance, 70, 1))
        #expect(p.segmentIndex == 0)
        #expect(single.coordinate(atOffset: 5)?.latitude == Self.origin.latitude)
    }

    // MARK: Merge

    private var main: RouteLine { RouteLine(eastLine(km: 20)) }

    @Test func sideRoadJoiningMainRoad() throws {
        let junction = move(Self.origin, east: 10_000)
        let start = move(junction, north: 5000)
        let side = RouteLine([start, junction] + eastLine(from: junction, km: 5).dropFirst())
        let m = try #require(main.mergeOffset(of: side))
        #expect(close(m.otherOffset, 5000 - 50, 5))
        #expect(close(m.mainOffset, 10_000, 5))
    }

    @Test func routeThatNeverJoins() {
        let parallel = RouteLine(eastLine(from: move(Self.origin, north: 500), km: 15))
        #expect(main.mergeOffset(of: parallel) == nil)
    }

    @Test func routeThatTouchesThenLeaves() {
        let cross = move(Self.origin, east: 5000)
        let wander = RouteLine([move(cross, north: -3000), cross, move(cross, north: 3000)])
        #expect(main.mergeOffset(of: wander) == nil)
    }

    @Test func routeEntirelyOnMainMergesAtStart() throws {
        let sub = RouteLine(eastLine(from: move(Self.origin, east: 2000), km: 6))
        let m = try #require(main.mergeOffset(of: sub))
        #expect(m.otherOffset == 0)
        #expect(close(m.mainOffset, 2000, 1))
    }

    // MARK: Performance

    @Test func projectingWithHintsIsFast() throws {
        let pts = (0..<5000).map { i in
            CLLocationCoordinate2D(latitude: 3 + Double(i) * 0.0003, longitude: 101 + sin(Double(i) / 50) * 0.02)
        }
        let line = RouteLine(pts)
        let probes = (0..<1000).map { i in
            let c = pts[i * 5 + 2]
            return CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + 0.0003)
        }
        var hint: Int?
        var checksum = 0.0
        let elapsed = ContinuousClock().measure {
            for probe in probes {
                if let p = line.project(probe, hint: hint) {
                    hint = p.segmentIndex
                    checksum += p.offset
                }
            }
        }
        #expect(checksum > 0)
        #expect(elapsed < .milliseconds(50))
    }
}
