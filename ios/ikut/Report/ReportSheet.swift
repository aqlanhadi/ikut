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
        // The same frame, sheet and tiles as the stop cards (title, close button, 20 pt padding, the message tile's
        // fill); the grid needs no cap, so it never scrolls inside one.
        CardSheetFrame(
            title: "What’s on the road?", bodyCap: .infinity, closeIdentifier: "sheet.close",
            containerIdentifier: "report.card", onClose: { dismiss() }
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 2), spacing: Spacing.s) {
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
        .task(id: pinned == nil) {
            // No fix when the sheet opened: pin to the first one that arrives. The buttons wait for it.
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
            .surfaceTile()
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
                .surfaceTile()
                .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
            .overlay { Button { showing = true } label: { Text("Report").padding(.horizontal, Spacing.l) }.ikutButton(.primary) }
            .sheet(isPresented: $showing) {
                ScrollView { ReportSheet(context: context, toast: toast) { _ in } }
                    .presentationDetents([.large])
            }
    }
}

#Preview("Report sheet") { ReportPreviewHost(failing: false) }
#Preview("Report fails") { ReportPreviewHost(failing: true) }
