import SwiftUI

/// What ikut says before iOS asks for location (design H2): why, and what is shared with whom. Used as the join
/// sheet's location step; the lobby's Always explainer shares its heading.
struct LocationAskContent: View {
    static let heading = "Keep sharing while the screen is off or another app is open"
    static let intro = "Most drivers keep Waze in front. ikut keeps the convoy up to date behind it."
    static let next = "Next, iOS asks. Choose Allow While Using App, then Change to Always Allow."

    private struct Promise: Identifiable {
        let symbol: String, title: String, detail: String
        var id: String { title }
    }

    private let promises = [
        Promise(symbol: Symbol.duringTrip, title: "Only during a trip", detail: "From Start until you arrive or leave the trip"),
        Promise(symbol: Symbol.convoyMembers, title: "Only to this convoy", detail: "They see your first name and how far away you are"),
        Promise(symbol: Symbol.pauseAnytime, title: "Pause any time", detail: "From the lobby, for 30 min"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(Self.heading)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(Self.intro).font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(promises) { promise in
                    HStack(alignment: .top, spacing: Spacing.m) {
                        Image(systemName: promise.symbol)
                            .ikutGlyph(22, cap: 1.25)
                            .foregroundStyle(Color.ikutAccent)
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(promise.title).font(.subheadline.weight(.semibold))
                            Text(promise.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, Spacing.xs)
            Text(Self.next).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
