import SwiftUI

/// The "Reported debris · Undo" banner. Overlay it at the top or bottom of the host screen.
struct ReportToastView: View {
    @Bindable var model: ReportToastModel
    /// Where it comes from: the top on the map, the bottom in the report sheet.
    var edge: Edge = .top
    /// True under the map's banner slot, which owns the coming and going.
    var inSlot = false
    /// The map plays them from its banner slot instead (`reportHaptics`), since the toast is only drawn while it has the slot.
    var haptics = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .sending(let label):
                DarkBanner(title: "Sending \(label)…", circle: .white.fill(.tint)) {
                    ProgressView().tint(.white)
                } trailing: {
                    EmptyView()
                }
                .modifier(Placement(edge: edge, inSlot: inSlot))
            case .reported(let label, _):
                DarkBanner(title: "Reported \(label)", symbol: "checkmark", circle: .green) {
                    Button("Undo") { Task { await model.undo() } }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .ikutRow()
                        .background(.white.fill(.tint), in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityHint("Removes the report")
                }
                .modifier(Placement(edge: edge, inSlot: inSlot))
                .announces("Reported \(label). You can undo it.")
                .accessibilityAction(named: "Close") { model.dismiss() }
            case .failed(let message):
                DarkBanner(title: message, symbol: "exclamationmark.triangle.fill", circle: .orange) {
                    Button { model.dismiss() } label: {
                        RoundIconSymbol(systemImage: "xmark", glyph: .body.weight(.semibold), style: .bare, color: .white)
                    }
                    .accessibilityLabel("Close")
                }
                .modifier(Placement(edge: edge, inSlot: inSlot))
                .announces(message)
            }
        }
        .animation(DrivingGlance.animation(Motion.pill, reduceMotion: reduceMotion), value: model.state)
        .modifier(HapticsIf(model: model, on: haptics))
    }

    private struct OptionalTransition: ViewModifier {
        let edge: Edge
        let on: Bool
        @ViewBuilder func body(content: Content) -> some View {
            if on { content.glanceTransition(edge: edge) } else { content }
        }
    }

    private struct HapticsIf: ViewModifier {
        let model: ReportToastModel
        let on: Bool
        func body(content: Content) -> some View {
            if on { content.reportHaptics(model) } else { content }
        }
    }

    /// How each state comes and goes; the host places and pads the toast.
    private struct Placement: ViewModifier {
        let edge: Edge
        let inSlot: Bool
        func body(content: Content) -> some View {
            content
                .modifier(OptionalTransition(edge: edge, on: !inSlot))
                .accessibilityElement(children: .contain)
        }
    }
}

extension View {
    /// The tap, success and failure haptics of a report, for a view that is always on screen while the report runs.
    func reportHaptics(_ model: ReportToastModel) -> some View {
        self
            .sensoryFeedback(.impact(weight: .medium), trigger: model.submittedCount)
            .sensoryFeedback(.success, trigger: model.reportedCount)
            .sensoryFeedback(.error, trigger: model.failureCount)
    }
}

#if DEBUG
#Preview("Every state") {
    let states: [ReportToastModel.State] = [
        .sending(label: "debris"),
        .reported(label: "debris", eventId: "demo-debris"),
        .failed(message: "Couldn’t report debris. Check your signal."),
    ]
    let models = states.map { state in
        let model = ReportToastModel()
        model.showForDemo(state)
        return model
    }
    return VStack(spacing: Spacing.m) {
        ForEach(models.indices, id: \.self) { ReportToastView(model: models[$0]) }
    }
    .padding(Spacing.m)
}
#endif
