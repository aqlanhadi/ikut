#if DEBUG
import MapKit
import SwiftUI

/// `IKUT_SCREEN=camera-tour` (D57): plays the camera's long and short hops on the driving map, then steps through the
/// recap map, so the pace (`CameraPace`) can be watched by hand. A caption says which move is playing. It loops.
struct CameraTourDemo: View {
    private enum Phase { case driving, recap }

    @State private var phase = Phase.driving
    @State private var caption = "Watch the camera"
    @State private var stage = TripMapStage(mode: .driving, tripId: "demo")
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
                .accessibilityIdentifier("cameraTour.caption")
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
#endif
