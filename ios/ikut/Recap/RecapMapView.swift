import MapKit
import SwiftUI

/// Full-screen route map after the trip (design/project/RecapMap.dc.html). The design animates the
/// cars along their drive; ikut keeps only each car's last position, so instead this steps through
/// the timeline: each step highlights its marker and moves the map there, and cars sit where they
/// finished.
struct RecapMapView: View {
    var recap: Recap
    var snapshot: RecapSnapshot
    var onClose: () -> Void

    @State private var index = 0
    @State private var camera: MapCameraPosition = .automatic

    private var steps: [RecapTimelineItem] { recap.timeline }
    private var current: RecapTimelineItem? { steps.indices.contains(index) ? steps[index] : nil }

    var body: some View {
        RecapRouteMap(recap: recap, snapshot: snapshot, interactive: true, selectedId: current?.id, camera: $camera)
            .ignoresSafeArea()
            .overlay(alignment: .top) { header }
            .overlay(alignment: .bottom) { stepper }
            .onChange(of: index) { _, _ in focus() }
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            MapCloseButton(action: onClose)
            VStack(alignment: .leading, spacing: 1) {
                Text("Route Map").font(.headline)
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
            }
            HStack(spacing: Spacing.gap) {
                Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left").frame(width: 50, height: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(index == 0)
                    .accessibilityLabel("Previous")
                Text(steps.isEmpty ? "No events" : "\(index + 1) of \(steps.count)")
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                Button { index = min(steps.count - 1, index + 1) } label: { Image(systemName: "chevron.right").frame(width: 50, height: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(index >= steps.count - 1)
                    .accessibilityLabel("Next")
            }
            Text("Cars are shown where they finished. ikut doesn't keep the path each car drove.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(Spacing.l)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
        .padding(.horizontal, Spacing.m)
        .padding(.bottom, Spacing.s)
    }

    private func focus() {
        guard let c = current?.coordinate else {
            withAnimation { camera = .automatic }
            return
        }
        withAnimation {
            camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)))
        }
    }
}
