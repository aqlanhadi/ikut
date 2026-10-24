import SwiftUI

/// First screen until "Get started": what ikut does, then on to Home (or straight to Join).
struct WelcomeView: View {
    var onGetStarted: () -> Void
    var onJoin: () -> Void

    private struct Feature: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let features = [
        Feature(
            symbol: "map", title: "Every car on one map",
            detail: "See the whole convoy live, and how far each car is behind the lead."),
        Feature(
            symbol: "fuelpump", title: "Call a stop in one tap",
            detail: "Ask for fuel, food or a rest, and every car taps OK."),
        Feature(
            symbol: "exclamationmark.triangle", title: "Warn the cars behind you",
            detail: "Hazards you report are read aloud to the cars following."),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 88)
                    .background(Color.ikutAccent, in: RoundedRectangle(cornerRadius: Radius.hero, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 9, y: 3)
                    .accessibilityHidden(true)

                Text("Welcome to ikut")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)
                    .accessibilityAddTraits(.isHeader)
                Text("Drive together. Arrive together.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.s)

                VStack(alignment: .leading, spacing: 28) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: Spacing.l) {
                            Image(systemName: feature.symbol)
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(Color.ikutAccent)
                                .frame(width: 36, height: 36)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: Spacing.xxs) {
                                Text(feature.title).font(.subheadline.weight(.semibold))
                                Text(feature.detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 44)
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            .padding(.bottom, Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.tight) {
                Text("Joining needs only a name, no account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, Spacing.cozy)
                Button(action: onGetStarted) { Text("Get Started").frame(maxWidth: .infinity) }
                    .actionButton(.primary)
                Button(action: onJoin) {
                    Label("Join with a code", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .actionButton(.link)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, Spacing.m)
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {}, onJoin: {})
}
