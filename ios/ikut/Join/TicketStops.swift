import SwiftUI

/// The planned stops on the Join ticket, one line each in the organizer's order.
struct TicketStops: View {
    var stops: [PreviewStop]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            StatCaption("Stops")
            ForEach(Array(stops.enumerated()), id: \.offset) { _, stop in
                Text(stop.line)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
