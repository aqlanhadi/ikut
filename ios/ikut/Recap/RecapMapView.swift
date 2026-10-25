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

    @State private var index = 0
    @State private var camera: MapCameraPosition = .automatic
    /// The map's bottom safe area: up to the top of the stepper card, so the logo and Legal sit above it.
    @State private var legalReach: CGFloat = 0
    @State private var stepperTop: CGFloat = 0
    @State private var screenHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [RecapTimelineItem] { recap.timeline }
    private var current: RecapTimelineItem? { steps.indices.contains(index) ? steps[index] : nil }

    var body: some View {
        RecapRouteMap(recap: recap, snapshot: snapshot, interactive: true, selectedId: current?.id,
                      legalInset: legalReach, camera: $camera)
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height + $0.safeAreaInsets.top + $0.safeAreaInsets.bottom }) { screenHeight = $0 }
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { stepper }
            // Legal follows the card's top in the same transaction as the step (the card's new height is known
            // at once), so it moves with the card and nothing jumps afterwards.
            .onChange(of: stepperTop) { _, _ in
                legalReach = MapLegal.reach(sheetTop: stepperTop, screenHeight: screenHeight, current: legalReach)
            }
            .onChange(of: screenHeight) { _, _ in
                legalReach = MapLegal.reach(sheetTop: stepperTop, screenHeight: screenHeight, current: legalReach)
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
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.s)
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
            HStack(spacing: Spacing.gap) {
                Button { step(to: max(0, index - 1)) } label: { Image(systemName: "chevron.left").frame(width: 50, height: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(index == 0)
                    .accessibilityLabel("Previous")
                Text(steps.isEmpty ? "No events" : "\(index + 1) of \(steps.count)")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                Button { step(to: min(steps.count - 1, index + 1)) } label: { Image(systemName: "chevron.right").frame(width: 50, height: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(index >= steps.count - 1)
                    .accessibilityLabel("Next")
            }
            Text("Cars are shown where they finished. ikut doesn’t keep the path each car drove.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { stepperTop = $0 }
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    /// One step: the card's text and height change on the camera's motion (a fade with Reduce Motion), and the
    /// camera glides there on the same clock, or jumps when it is far or Reduce Motion is on.
    private func step(to new: Int) {
        guard new != index, steps.indices.contains(new) else { return }
        let move = RecapLogic.stepMove(from: current?.coordinate, to: steps[new].coordinate, span: Self.span)
        let cardMotion = reduceMotion ? Motion.reduced : Motion.camera(reduceMotion: false)
        withAnimation(cardMotion) { index = new }
        let target = steps[new].coordinate.map {
            MapCameraPosition.region(MKCoordinateRegion(center: $0, span: MKCoordinateSpan(latitudeDelta: Self.span, longitudeDelta: Self.span)))
        } ?? .automatic
        if move == .glide {
            withAnimation(Motion.camera(reduceMotion: reduceMotion)) { camera = target }
        } else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { camera = target }
        }
    }

    private static let span = 0.15
}

#if DEBUG
#Preview {
    let model = RecapModel(snapshot: .demo(), originName: "Tanjung Malim")
    if let recap = model.recap, let snapshot = model.snapshot {
        RecapMapView(recap: recap, snapshot: snapshot, onClose: {})
    }
}
#endif
