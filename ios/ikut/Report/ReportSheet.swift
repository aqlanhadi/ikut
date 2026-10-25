import CoreLocation
import SwiftUI
import UIKit

/// "What’s on the road?": 8 road reports in a grid, 3 car statuses below. Tapping one sends
/// the report through `toast` (which shows "Reported … · Undo"), then dismisses at once.
struct ReportSheet: View {
    let context: ReportContext
    let toast: ReportToastModel
    var onReported: (EventType) -> Void
    @Environment(\.dismiss) private var dismiss
    /// Where the car was when the sheet opened; that's where the pin goes.
    @State private var pinned: ReportSnapshot?

    init(context: ReportContext, toast: ReportToastModel, onReported: @escaping (EventType) -> Void) {
        self.context = context
        self.toast = toast
        self.onReported = onReported
        _pinned = State(initialValue: context.snapshot())
    }

    var body: some View {
        // The same frame as the stop cards (title, close button, 20 pt padding); the grid needs no cap, so it never
        // scrolls inside one.
        CardSheetFrame(
            title: "What’s on the road?", bodyCap: .infinity, closeIdentifier: "sheet.close",
            containerIdentifier: "report.card", onClose: { dismiss() }
        ) {
            pinCard
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gap), count: 2), spacing: Spacing.gap) {
                ForEach(ReportOption.events) { option in
                    eventButton(option)
                }
            }
            CardHeader("About your car", inset: Spacing.xs, top: 0, bottom: 0)
            HStack(spacing: Spacing.s) {
                ForEach(ReportOption.statuses) { option in
                    statusButton(option)
                }
            }
        }
    }

    private var pinCard: some View {
        HStack(spacing: Spacing.gap) {
            Image(systemName: pinned == nil ? "location.slash.fill" : "mappin.circle.fill")
                .font(.title3)
                .foregroundStyle(pinned == nil ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 1) {
                if let pinned {
                    Text("Pinned where you tapped").font(.subheadline.weight(.semibold))
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(Self.pinDetail(pinned: pinned, now: timeline.date, current: context.snapshot()?.coordinate))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text("Waiting for your location").font(.subheadline.weight(.semibold))
                    Text("You can report once your phone finds where you are.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.cozy)
        .ikutTile()
        .accessibilityElement(children: .combine)
        .task(id: pinned == nil) {
            // No fix when the sheet opened: pin to the first one that arrives.
            while pinned == nil, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                pinned = context.snapshot()
            }
        }
    }

    private func eventButton(_ option: ReportOption) -> some View {
        Button { send(option) } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: option.symbol)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(option.tint, in: Circle())
                Text(option.label)
                    .font(.headline)
                    .wrapsAtAccessibilitySizes(lines: 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m)
            .frame(maxWidth: .infinity, minHeight: 72)
            .ikutTile()
            .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pinned == nil)
        .accessibilityLabel(option.label)
    }

    private func statusButton(_ option: ReportOption) -> some View {
        Button { send(option) } label: {
            Text(option.label)
                .font(.subheadline.weight(.semibold))
                .wrapsAtAccessibilitySizes(lines: 2)
                .frame(maxWidth: .infinity, minHeight: 60)
                .ikutSurface(.quaternary, radius: Radius.tile)
                .contentShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(pinned == nil)
        .accessibilityLabel(option.label)
    }

    private func send(_ option: ReportOption) {
        guard let pinned else { return }
        toast.submit(option, context: context, snapshot: pinned)
        onReported(option.type)
        dismiss()
    }

    /// "12 s ago · 320 m behind you now".
    nonisolated static func pinDetail(pinned: ReportSnapshot, now: Date, current: CLLocationCoordinate2D?) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(pinned.capturedAt)))
        let ago = seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(String(format: "%02d", seconds % 60)) s"
        guard let current else { return "\(ago) ago" }
        let meters = Int(RouteLine.haversine(pinned.coordinate, current).rounded())
        let distance = meters < 1000 ? "\(meters) m" : String(format: "%.1f km", Double(meters) / 1000)
        return "\(ago) ago · \(distance) behind you now"
    }
}

// MARK: Preview

private struct PreviewReportService: ReportService {
    var failing = false
    func report(_ request: ReportRequest) async throws -> String {
        try await Task.sleep(for: .milliseconds(400))
        if failing { throw URLError(.notConnectedToInternet) }
        return UUID().uuidString
    }
    func undo(tripId: String, eventId: String) async throws {}
}

private struct ReportPreviewHost: View {
    @State private var toast: ReportToastModel
    @State private var showing = true
    private let context = ReportContext(tripId: "t", carId: "c", authorId: "u") {
        ReportSnapshot(
            coordinate: .init(latitude: 3, longitude: 101), heading: 90, route: nil,
            previousOffset: nil, capturedAt: Date().addingTimeInterval(-6))
    }

    init(failing: Bool) {
        _toast = State(initialValue: ReportToastModel(service: PreviewReportService(failing: failing)))
    }

    var body: some View {
        Color(.systemGroupedBackground)
            .ignoresSafeArea()
            .overlay(alignment: .bottom) { ReportToastView(model: toast, edge: .bottom).padding(.horizontal, Spacing.l).padding(.bottom, Spacing.xl) }
            .overlay { Button("Report") { showing = true }.buttonStyle(.borderedProminent) }
            .sheet(isPresented: $showing) {
                ScrollView { ReportSheet(context: context, toast: toast) { _ in } }
                    .presentationDetents([.large])
            }
    }
}

#Preview("Report sheet") { ReportPreviewHost(failing: false) }
#Preview("Report fails") { ReportPreviewHost(failing: true) }
