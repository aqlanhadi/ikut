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

    /// The icon's gap from the top and the features' gap from the title: 48 (the hero margin and one more step).
    private static let introTop = Spacing.hero + Spacing.l

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // The official icon (ikut.icon exported with ictool, already masked to the app-icon shape).
                Image("WelcomeIcon")
                    .resizable()
                    .frame(width: 88, height: 88)
                    .elevation(.floating)
                    .accessibilityHidden(true)

                Text("Welcome to ikut")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.xl)
                    .accessibilityAddTraits(.isHeader)
                Text("Drive together. Arrive together.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, Spacing.s)

                VStack(alignment: .leading, spacing: Spacing.xl) {
                    ForEach(features) { feature in
                        HStack(alignment: .top, spacing: Spacing.l) {
                            Image(systemName: feature.symbol)
                                .ikutGlyph(28, cap: 1.15)
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
                .padding(.top, Self.introTop)
            }
            .padding(.horizontal, Spacing.hero)
            .padding(.top, Self.introTop)
            .padding(.bottom, Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Spacing.s) {
                Text("Joining needs only a name, no account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, Spacing.l)
                Button(action: onGetStarted) { Text("Get started").frame(maxWidth: .infinity) }
                    .ikutButton(.primary)
                Button(action: onJoin) {
                    Label("Join with a code", systemImage: "qrcode").frame(maxWidth: .infinity)
                }
                .ikutButton(.link)
                .accessibilityIdentifier("welcomeJoin")
            }
            .padding(.horizontal, Spacing.hero)
            .padding(.bottom, Spacing.m)
            .background(Color(.systemBackground))
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {}, onJoin: {})
}
