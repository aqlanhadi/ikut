import SwiftUI

extension TripsHomeView {
    /// The name as the first step of Where to? in Home's one sheet (D112): the same step joining opens with, with Close
    /// back to the list. Once the name is signed in, `onNamed` carries on to Where to?.
    @ViewBuilder func nameStepSheet(_ step: NameStepState) -> some View {
        @Bindable var step = step
        VStack(alignment: .leading, spacing: 0) {
            SheetTopRow(title: "Welcome to ikut") {
                EmptyView()
            } trailing: {
                RoundGlassIconButton(systemImage: Symbol.close, label: "Close") { model.closeNaming() }
                    .accessibilityIdentifier(AXID.Sheet.close).disabled(step.isWorking)
            }
            .padding(.top, Spacing.xs)
            .padding(.horizontal, Spacing.l)

            List {
                NameStepSections(name: $step.name, isWorking: step.isWorking, error: step.error,
                                 footer: "The convoy sees this name. You don’t need an account to start a trip.",
                                 focused: $nameFocused, onSubmit: { submitName(step) })
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, Spacing.l, for: .scrollContent)
            .onChange(of: step.name) { step.error = nil }

            NameStepButton(isWorking: step.isWorking, enabled: step.isValid) { submitName(step) }
                .padding(.horizontal, Spacing.l)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .environment(\.inPanelSheet, true)
        .buttonSurface(.glass)
        .task {
            if step.name.isEmpty { step.name = auth.displayName ?? "" }
            nameFocused = true
        }
    }

    private func submitName(_ step: NameStepState) {
        Task {
            if await step.submit(signIn: { try await auth.signInAsGuest(name: $0) }) { onNamed() }
        }
    }
}
