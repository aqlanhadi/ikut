import SwiftUI

/// The "Reported debris · Undo" banner. Overlay it at the top or bottom of the host screen.
struct ReportToastView: View {
    @Bindable var model: ReportToastModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .sending(let label):
                DarkBanner(title: "Sending \(label)…", circle: .white.opacity(0.16)) {
                    ProgressView().tint(.white)
                } trailing: {
                    EmptyView()
                }
                .modifier(Placement())
            case .reported(let label, _):
                DarkBanner(title: "Reported \(label)", symbol: "checkmark", circle: .green) {
                    Button("Undo") { Task { await model.undo() } }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityHint("Removes the report")
                }
                .modifier(Placement())
                .announces("Reported \(label). Undo is available.")
                .accessibilityAction(named: "Close") { model.dismiss() }
            case .failed(let message):
                DarkBanner(title: message, symbol: "exclamationmark.triangle.fill", circle: .orange) {
                    Button { model.dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Close")
                }
                .modifier(Placement())
                .announces(message)
            }
        }
        .animation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion), value: model.state)
        .sensoryFeedback(.success, trigger: model.reportedCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
    }

    /// How each state comes and goes; the host places and pads the toast.
    private struct Placement: ViewModifier {
        func body(content: Content) -> some View {
            content
                .glanceTransition(edge: .top)
                .accessibilityElement(children: .contain)
        }
    }
}

#if DEBUG
#Preview("Every state") {
    let states: [ReportToastModel.State] = [
        .sending(label: "debris"),
        .reported(label: "debris", eventId: "demo-debris"),
        .failed(message: "Couldn't report debris. Check your connection."),
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
