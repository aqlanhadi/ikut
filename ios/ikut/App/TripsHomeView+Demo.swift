import MapKit
import SwiftUI

#if DEBUG
// Home's Debug-only demo states and tours (D63 B1), cut from TripsHomeView. The tours need the view's state, so the
// few members they use are internal rather than private.
extension TripsHomeView {
    /// The camera `init(demo:)` opens on, worked out for the join sheet, the create sheet and a picked trip (or the routes).
    static func demoJoinCamera(_ joinStepper: JoinStepper) -> MapCameraPosition? {
        let insets = HomeSheet.createInsets(
            mapHeight: 0, sheet: HomeSheet.joinHeight, compact: HomeSheet.compactHeight)
        guard let region = JoinSteps.region(for: joinStepper.model.preview, bottomObscured: insets.bottom, topObscured: insets.top) else { return nil }
        return .region(region)
    }

    static func demoCreateCamera(_ createFlow: NewTripFlow) -> MapCameraPosition? {
        let insets = HomeSheet.createInsets(
            mapHeight: 0, sheet: HomeSheet.height(HomeSheet.mode(flow: createFlow), compact: HomeSheet.compactHeight),
            compact: HomeSheet.compactHeight)
        guard let region = createFlow.region(bottomObscured: insets.bottom, topObscured: insets.top) else { return nil }
        return .region(region)
    }

    /// A picked trip: its route, and the camera on its selected stop or on the whole route.
    static func demoPickedCamera(_ picked: PickedTrip, selecting itemId: String?, routes: [PastTripRoute])
        -> (route: PastTripRoute?, camera: MapCameraPosition?) {
        if let itemId, let item = picked.model.recap?.timeline.first(where: { $0.id == itemId }) { picked.select(item) }
        let route = PickedTripLogic.route(for: picked.entry, snapshot: picked.model.snapshot, drawn: routes, fetched: nil)
        let insets = Self.obscured(mapHeight: 0)
        if let c = picked.selectedItem?.coordinate {
            return (route, .region(PickedTripLogic.focus(on: c, bottomObscured: insets.bottom, topObscured: insets.top)))
        } else if let route, let r = PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top) {
            return (route, .region(r))
        }
        return (route, nil)
    }

    /// `tour`: picks the first trip and closes it again by itself, the second time pulling it up and down first.
    func playTour() async {
        guard tour, let first = past.first else { return }
        for cycle in 0..<2 {
            try? await Task.sleep(for: .seconds(2.5))
            open(first)
            try? await Task.sleep(for: .seconds(3.5))
            if cycle == 1 {
                // Pulled up and back down, to see that the map and Legal stay put under the tall sheet.
                expanded = true
                try? await Task.sleep(for: .seconds(3))
                expanded = false
                try? await Task.sleep(for: .seconds(2.5))
            }
            closePicked()
        }
    }

    /// Home's hops for `home-camera-tour`, looping: the first fix (the country to your street), the street to every
    /// trip, a pick, a stop on it, the whole trip, back to trips, and a far hop to Johor Bahru and back.
    func playCameraTour() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        let insets = Self.obscured(mapHeight: mapHeight)
        let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
        let country = MKCoordinateRegion(center: .init(latitude: 4.2, longitude: 102.0), span: .init(latitudeDelta: 8, longitudeDelta: 6))
        let johor = HomeCamera.around(.init(latitude: 1.4927, longitude: 103.7414), bottomObscured: insets.bottom, topObscured: insets.top)
        while !Task.isCancelled {
            tourCaption = "The country"
            move(to: .region(country), animated: false)
            await pause(2.5)
            tourCaption = "First fix: the country to your street"
            move(to: .region(HomeCamera.around(kl, bottomObscured: insets.bottom, topObscured: insets.top)), animated: true)
            await pause(3.5)
            tourCaption = "Your street to every trip"
            fit(animated: true)
            await pause(3)
            guard let first = past.first else { return }
            tourCaption = "Pick a trip"
            open(first)
            await pause(3)
            if let stop = picked?.model.recap?.timeline.first(where: { $0.kind == .stop && $0.coordinate != nil }) {
                tourCaption = "A stop on its route"
                selectItem(stop)
                await pause(3)
                tourCaption = "The whole trip again"
                showWholeTrip()
                await pause(3)
            }
            tourCaption = "Back to trips"
            closePicked()
            await pause(3)
            tourCaption = "To Johor Bahru: out, across and in"
            move(to: .region(johor), animated: true)
            await pause(4.5)
            tourCaption = "Back to trips: out, across and in"
            fit(animated: true)
            await pause(4.5)
        }
    }
}
#endif
