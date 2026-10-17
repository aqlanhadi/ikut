import SwiftUI

/// The "Reported debris · Undo" banner. Overlay it at the top or bottom of the host screen.
struct ReportToastView: View {
    @Bindable var model: ReportToastModel

    var body: some View {
        Group {
            switch model.state {
            case .hidden:
                EmptyView()
            case .sending(let label):
                row(symbol: nil, text: "Sending \(label)…", tint: .white) { EmptyView() }
            case .reported(let label, _):
                row(symbol: "checkmark.circle.fill", text: "Reported \(label)", tint: .green) {
                    Button("Undo") { Task { await model.undo() } }
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                        .accessibilityHint("Removes the report")
                }
            case .failed(let message):
                row(symbol: "exclamationmark.triangle.fill", text: message, tint: .orange) {
                    Button { model.dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel("Dismiss")
                }
            }
        }
        .animation(.snappy, value: model.state)
        .sensoryFeedback(.success, trigger: model.reportedCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
    }

    private func row<Trailing: View>(
        symbol: String?, text: String, tint: Color, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(tint).font(.title3)
            } else {
                ProgressView().tint(.white)
            }
            Text(text)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color(white: 0.11).opacity(0.94), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}
