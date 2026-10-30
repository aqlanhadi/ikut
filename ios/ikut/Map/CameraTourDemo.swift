#if DEBUG
import FirebaseFirestore
import MapKit
import SwiftUI

/// `IKUT_SCREEN=camera-tour` (D57): plays the camera's long and short hops on the driving map, then steps through the
/// recap map, so the pace (`CameraPace`) can be watched by hand. A caption says which move is playing. It loops.
struct CameraTourDemo: View {
    private enum Phase { case driving, recap }

    @State private var phase = Phase.driving
    @State private var caption = "Watch the camera"
    @State private var stage = TripScreenModel(mode: .driving)
    @State private var model = MapDemo.model()
    @State private var recapStep = 0

    /// Peninsular Malaysia, as Home shows it before it knows where you are.
    private static let country = MKCoordinateRegion(
        center: .init(latitude: 4.2, longitude: 102.0), span: .init(latitudeDelta: 8, longitudeDelta: 6))
    /// A street in Johor Bahru, about 330 km from the convoy.
    private static let johor = MKCoordinateRegion(
        center: .init(latitude: 1.4927, longitude: 103.7414), span: .init(latitudeDelta: 0.03, longitudeDelta: 0.02))

    var body: some View {
        Group {
            switch phase {
            case .driving:
                NavigationStack {
                    TripScreenHost(stage: stage) {
                        TripMapView(session: TripSession(tripId: "demo", userId: "u-c1"), model: model,
                                    stopBoard: .empty, alerts: AlertCenter(bannerDuration: .seconds(3_600)),
                                    stopService: DemoStopService())
                    }
                }
            case .recap:
                let recapModel = RecapModel(snapshot: .demo(), originName: "Tanjung Malim")
                if let recap = recapModel.recap, let snapshot = recapModel.snapshot {
                    RecapMapView(recap: recap, snapshot: snapshot, onClose: {}, tourStep: recapStep)
                }
            }
        }
        .overlay(alignment: .center) {
            Text(caption)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.xs)
                .background(.regularMaterial, in: Capsule())
                .offset(y: -140)
                .allowsHitTesting(false)
                .accessibilityIdentifier(AXID.Map.cameraTourCaption)
        }
        .task { await play() }
    }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    private func play() async {
        while !Task.isCancelled {
            phase = .driving
            await pause(2.5)
            // Long: the whole country to your car (it's in view, so one slow zoom in).
            model.mode = .free
            caption = "The country"
            stage.place(.region(Self.country))
            await pause(2)
            caption = "Country to your car: long, zooms in"
            model.mode = .follow
            await pause(3.5)
            caption = "Your car to the convoy: short"
            model.mode = .fit
            await pause(3)
            caption = "The convoy to your car: short"
            model.mode = .follow
            await pause(3)
            // Long: far across the map, out, across and in.
            caption = "To Johor Bahru: long, out and across"
            model.mode = .free
            stage.fly(to: .region(Self.johor), view: CameraView(region: Self.johor), reduceMotion: false)
            await pause(4)
            caption = "Back to your car: long"
            model.mode = .follow
            await pause(4)
            // A new move takes over one in flight.
            caption = "Johor Bahru, then back halfway: takes over"
            model.mode = .free
            stage.fly(to: .region(Self.johor), view: CameraView(region: Self.johor), reduceMotion: false)
            await pause(0.8)
            model.mode = .follow
            await pause(4)

            phase = .recap
            recapStep = 0
            caption = "Recap: each step"
            await pause(2.5)
            for step in 1..<8 {
                recapStep = step
                await pause(2.5)
            }
        }
    }
}

/// `IKUT_SCREEN=follow-drive` (D70): my car (the lead, this phone its tracker) drives north on the E1 at 100 km/h
/// with a fix every second, the camera following; Wyna and Daniel write their positions every 5 s, as the tracker
/// does. The map should glide on steadily, with no step every 5 s, and the other cars move smoothly between their
/// writes. Tap Fit to watch the cars move within the frame; a pan stops the camera and leaves the cars moving.
/// `follow-drive-still`: the same drive with the map held still on the convoy, to watch the cars alone.
/// `follow-drive-interrupts`: the drive, with the sheet, a banner, Fit, Follow and a hazard landing mid-glide.
struct FollowDriveDemo: View {
    var still = false
    var interrupts = false

    @State private var model: TripMapModel = {
        let model = MapDemo.model()
        model.mode = .follow
        return model
    }()

    var body: some View {
        NavigationStack {
            TripScreenHost(mode: .driving) {
                TripMapView(session: TripSession(tripId: "demo", userId: "u-c1"), model: model, stopBoard: .empty,
                            alerts: AlertCenter(bannerDuration: .seconds(3_600)), demoInterrupts: interrupts,
                            stopService: DemoStopService())
            }
        }
        .task {
            if still { model.mode = .fit }
            await drive()
        }
    }

    private func drive() async {
        let main = RouteLine(MapDemo.densify(MapDemo.mainWaypoints))
        let tapah = main.project(.init(latitude: 4.2000, longitude: 101.2600))?.offset ?? 0
        /// Where each car starts on the route and how fast it goes, m/s.
        let cars: [String: (start: Double, speed: Double)] = [
            "c1": (tapah, 100 / 3.6), "c2": (tapah - 1_800, 92 / 3.6), "c4": (tapah - 6_400, 96 / 3.6),
        ]
        func spot(_ id: String, _ seconds: Double) -> (MapCoordinate, Double, Double)? {
            guard let car = cars[id] else { return nil }
            let offset = car.start + car.speed * seconds
            guard let here = main.coordinate(atOffset: offset), let ahead = main.coordinate(atOffset: offset + 50) else { return nil }
            return (MapCoordinate(here), PlaceSide.bearing(here, ahead), offset)
        }
        let begin = Date()
        var second = 0.0
        while !Task.isCancelled {
            if still, second == 2 { model.mode = .free }
            let now = Date()
            if let (here, course, _) = spot("c1", second) {
                model.receive(DeviceFix(coordinate: here, course: course, speed: cars["c1"]!.speed, at: now), now: now)
            }
            // Every 5 s, the cars' written positions, as their trackers write them.
            if Int(second) % 5 == 0 {
                var positions: [String: Position] = [:]
                for id in ["c1", "c2", "c3", "c4"] {
                    if let (here, course, offset) = spot(id, second), let speed = cars[id]?.speed {
                        positions[id] = Position(
                            id: nil, location: GeoPoint(latitude: here.latitude, longitude: here.longitude), speed: speed,
                            heading: course, routeOffset: offset, convoyOffset: offset, battery: 0.8, updatedAt: now)
                    } else if let kept = model.carPosition(id) {
                        positions[id] = kept
                    }
                }
                model.apply(trip: nil, myCar: model.myCar, myCarId: "c1", positions: positions, isTracker: true)
            }
            second += 1
            try? await Task.sleep(for: .seconds(max(begin.addingTimeInterval(second).timeIntervalSinceNow, 0)))
        }
    }
}
#endif
