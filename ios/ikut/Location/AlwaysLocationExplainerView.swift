import SwiftUI

/// Sheet shown before the Always prompt, explaining why the trip needs background location.
struct AlwaysLocationExplainerView: View {
    let permission: LocationPermission
    let onFinish: (LocationPermission.Status) -> Void

    @State private var isRequesting = false

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                illustration
                    .padding(.top, 32)

                VStack(spacing: Spacing.m) {
                    Text(LocationAskContent.heading)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Your car keeps showing on the map for everyone in your trip, even when your screen is off. Sharing stops when the trip ends.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: Spacing.m) {
                    Button {
                        isRequesting = true
                        Task {
                            let status = await permission.requestAlways()
                            isRequesting = false
                            onFinish(status)
                        }
                    } label: {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isRequesting)

                    Button("Not now") { onFinish(permission.status) }
                        .controlSize(.large)
                        .disabled(isRequesting)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .presentationDetents([.large])
    }

    private var illustration: some View {
        HStack(spacing: 20) {
            Image(systemName: "car.fill")
                .foregroundStyle(.tint)
            Image(systemName: "location.fill")
                .foregroundStyle(.secondary)
            Image(systemName: "iphone.gen3.slash")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 44))
        .imageScale(.large)
        .accessibilityHidden(true)
    }
}

#Preview {
    Text("Trip")
        .sheet(isPresented: .constant(true)) {
            AlwaysLocationExplainerView(permission: LocationPermission(), onFinish: { _ in })
        }
}

#Preview("Large text") {
    AlwaysLocationExplainerView(permission: LocationPermission(), onFinish: { _ in })
        .dynamicTypeSize(.accessibility3)
}
