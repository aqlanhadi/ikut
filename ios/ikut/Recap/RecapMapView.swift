import MapKit
import SwiftUI

/// Full-screen route map after the trip (design/project/RecapMap.dc.html). The design animates the
/// cars along their drive; ikut keeps only each car’s last position, so instead this steps through
/// the timeline: each step highlights its marker and moves the map there, and cars sit where they
/// finished.
struct RecapMapView: View {
    var recap: Recap
    var snapshot: RecapSnapshot
    var onClose: () -> Void
    /// The camera tour (`IKUT_SCREEN=camera-tour`) steps the map from outside.
    var tourStep: Int? = nil

    @State private var index = 0
    @State private var camera: MapCameraPosition = .automatic
    @State private var flight = CameraFlight()
    /// The camera as last drawn, mid-move or after a pan; outside observation so a move redraws nothing.
    @State private var seen = CameraBox()
    /// The map's bottom safe area: up to the top of the stepper card, so the logo and Legal sit above it.
    @State private var legalReach: CGFloat = 0
    @State private var stepperTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @State private var screenWidth: CGFloat = 0
    /// The header's bottom edge, in the screen's points.
    @State private var headerBottom: CGFloat = 0
    /// True while the camera shows the whole route (the opening view, or a step with no place); the fit follows the
    /// header and card until a step moves the camera or the person pans it.
    @State private var overview = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [RecapTimelineItem] { recap.timeline }
    private var current: RecapTimelineItem? { steps.indices.contains(index) ? steps[index] : nil }

    var body: some View {
        RecapRouteMap(recap: recap, snapshot: snapshot, interactive: true, selectedId: current?.id,
                      legalInset: legalReach, camera: $camera, onCamera: { seen.record($0, latitudeDelta: $1) })
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom }) { screenHeight = $0 }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { screenWidth = $0 }
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { stepper }
            // Legal follows the card's top in the same transaction as the step (the card's new height is known
            // at once), so it moves with the card and nothing jumps afterwards.
            .onChange(of: stepperTop) { _, _ in
                legalReach = MapLegal.reach(sheetTop: stepperTop, screenHeight: screenHeight, current: legalReach)
                refit()
            }
            .onChange(of: headerBottom) { _, _ in refit() }
            .onChange(of: screenWidth) { _, _ in refit() }
            .onChange(of: tourStep) { _, step in if let step { self.step(to: min(step, steps.count - 1)) } }
            .onChange(of: screenHeight) { _, _ in
                legalReach = MapLegal.reach(sheetTop: stepperTop, screenHeight: screenHeight, current: legalReach)
                refit()
            }
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            MapCloseButton(action: onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text("Route map").font(.headline)
                Text([snapshot.name, recap.routeDistance.map(RouteFormat.distance)].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, CornerButton.edge)
        .padding(.top, CornerButton.top)
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) { headerBottom = $0 }
    }

    /// The whole route in the strip between the header and the card, once both are measured (D120).
    private var fit: MKCoordinateRegion? {
        RecapFit.region(snapshot: snapshot, headerBottom: headerBottom, cardTop: stepperTop, width: screenWidth)
    }

    /// Refits the overview as the header or card measure or change (large text, a taller step card), in place.
    private func refit() {
        guard overview, !camera.positionedByUser, let region = fit else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { camera = .region(region) }
    }

    private var stepper: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if let item = current {
                HStack(alignment: .top, spacing: Spacing.m) {
                    RecapEventDot(kind: item.kind, symbol: item.symbol, size: 36)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(RecapLogic.clock(item.time)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        Text(item.title).font(.headline)
                        if !item.detail.isEmpty { Text(item.detail).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
                .id(item.id)
                .transition(.opacity)
            }
            HStack(spacing: Spacing.s) {
                Button { step(to: max(0, index - 1)) } label: { Image(systemName: Symbol.back).frame(width: 50) }
                    .ikutButton(.secondary)
                    .disabled(index == 0)
                    .accessibilityLabel("Previous")
                Text(steps.isEmpty ? "No events" : "\(index + 1) of \(steps.count)")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                Button { step(to: min(steps.count - 1, index + 1)) } label: { Image(systemName: Symbol.forward).frame(width: 50) }
                    .ikutButton(.secondary)
                    .disabled(index >= steps.count - 1)
                    .accessibilityLabel("Next")
            }
            Text("Cars are shown where they finished. ikut doesn’t keep the path each car drove.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { stepperTop = $0 }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    /// One step: the card's text and height change on the camera's motion (a fade with Reduce Motion), and the
    /// camera flies there at the pace of `CameraPace`: a glide to a step nearby, out-across-and-in to a far one. A step
    /// without a place, from or to, jumps.
    private func step(to new: Int) {
        guard new != index, steps.indices.contains(new) else { return }
        overview = steps[new].coordinate == nil
        let move = RecapLogic.stepMove(from: current?.coordinate, to: steps[new].coordinate)
        // From where the camera is: the landing of a flight still in the air, else the camera as drawn (after a pan
        // too), else the step on screen.
        let drawn = seen.seen.map {
            CameraView(latitude: $0.camera.centerCoordinate.latitude, longitude: $0.camera.centerCoordinate.longitude,
                       latitudeSpan: $0.latitudeDelta)
        }
        let from = flight.destination ?? drawn ?? current?.coordinate.map { CameraView(region: Self.region(at: $0)) }
        let cardMotion = reduceMotion ? Motion.reduced : Motion.camera(reduceMotion: false)
        withAnimation(cardMotion) { index = new }
        guard move == .fly, let center = steps[new].coordinate else {
            flight.cancel()
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { camera = steps[new].coordinate.map { .region(Self.region(at: $0)) } ?? fit.map { .region($0) } ?? .automatic }
            return
        }
        let region = Self.region(at: center)
        flight.fly(to: .region(region), view: CameraView(region: region), from: from, reduceMotion: reduceMotion,
                   continues: { camera.positionedByUser == false }) { camera = $0 }
    }

    private static func region(at center: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    private static let span = 0.15
}

/// Where the recap map's overview camera goes (D120): every point of the route and its pins centred in the strip the
/// header and the step card leave, with the same shared fit as the lobby and Home. MapKit frames the map from the top
/// of the screen down to the card's top (the card is the map's bottom padding), so that height is the frame.
enum RecapFit {
    /// The destination's pin stands about this far above its coordinate, kept clear of the header.
    static let pinRoom: CGFloat = 40
    /// A little air under the header.
    static let headerGap: CGFloat = Spacing.xs

    static func region(snapshot: RecapSnapshot, headerBottom: CGFloat, cardTop: CGFloat, width: CGFloat) -> MKCoordinateRegion? {
        guard headerBottom > 0, cardTop > headerBottom + pinRoom * 2, width > 0 else { return nil }
        let points = Polyline.decode(snapshot.route) + snapshot.positions.map(\.coordinate)
        let route = PastTripRoute(id: snapshot.tripId, name: "", destinationName: "", destinationLatitude: snapshot.destination.latitude,
                                  destinationLongitude: snapshot.destination.longitude, points: points.map { [$0.latitude, $0.longitude] })
        let top = headerBottom + headerGap + pinRoom
        guard let region = PastTripsMapLogic.region(fitting: [route], bottomObscured: 0, topObscured: Double(top / cardTop),
                                                    aspect: MapFit.aspect(width: width, height: cardTop, padding: 0)) else { return nil }
        return balanced(region, points: points + [snapshot.destination], width: width, top: top, bottom: cardTop)
    }

    /// The shared fit centres by degrees of latitude, but a tall route in a short strip spans enough of the Mercator
    /// projection for that to leave the margins a couple of points apart: nudge the centre by the difference, worked out
    /// with MapKit's own framing (the larger scale of the two spans never exceeded).
    static func balanced(_ region: MKCoordinateRegion, points: [CLLocationCoordinate2D], width: CGFloat, top: CGFloat,
                         bottom: CGFloat) -> MKCoordinateRegion {
        func mapPoint(_ lat: Double, _ lng: Double) -> MKMapPoint { MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lng)) }
        let nw = mapPoint(region.center.latitude + region.span.latitudeDelta / 2, region.center.longitude - region.span.longitudeDelta / 2)
        let se = mapPoint(region.center.latitude - region.span.latitudeDelta / 2, region.center.longitude + region.span.longitudeDelta / 2)
        let scale = min(Double(width) / abs(se.x - nw.x), Double(bottom) / abs(se.y - nw.y))
        let ys = points.map { MKMapPoint($0).y }
        guard scale > 0, let north = ys.min(), let south = ys.max() else { return region }
        let centre = MKMapPoint(region.center)
        let topMargin = Double(bottom / 2) + (north - centre.y) * scale - Double(top)
        let bottomMargin = Double(bottom) - (Double(bottom / 2) + (south - centre.y) * scale)
        var moved = centre
        moved.y -= (bottomMargin - topMargin) / 2 / scale
        return MKCoordinateRegion(center: moved.coordinate, span: region.span)
    }
}

#if DEBUG
#Preview {
    let model = RecapModel(snapshot: .demo(), originName: "Tanjung Malim")
    if let recap = model.recap, let snapshot = model.snapshot {
        RecapMapView(recap: recap, snapshot: snapshot, onClose: {})
    }
}
#endif
