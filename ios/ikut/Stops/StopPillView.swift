import SwiftUI

/// The pill at the top of the map for a stop. A question has one big button (64 pt or more, one
/// word); the others are a slim line. It never covers the route: the map stays visible.
struct StopPillView: View {
    let pill: StopPill
    /// The one big button: OK.
    var onButton: (_ eventId: String) -> Void

    var body: some View {
        Group {
            switch pill {
            case .question(let eventId, let symbol, let title, let detail):
                question(eventId: eventId, symbol: symbol, title: title, detail: detail)
            case .confirm(let symbol, let title, let detail):
                slim(symbol: symbol, title: title, detail: detail, id: "stop.pill.confirm")
            case .asked(let title, let detail):
                slim(symbol: "checkmark", title: title, detail: detail, id: "stop.pill.asked")
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .glanceTransition(edge: .top)
        .announces(announcement, id: pill.id)
    }

    private var announcement: String {
        switch pill {
        case .question(_, _, let title, let detail), .confirm(_, let title, let detail), .asked(let title, let detail):
            "\(title), \(detail)"
        }
    }

    private func question(eventId: String, symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                StopReasonIcon(symbol: symbol, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(Color.surfaceSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stop.pill.text")
            Button { onButton(eventId) } label: {
                Text("OK")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Color.ikutOK, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stop.pill.button")
        }
        .padding(Spacing.m)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.banner, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("stop.pill")
    }

    private func slim(symbol: String, title: String, detail: String, id: String) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.ikutPositive, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Capsule().fill(.regularMaterial))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

#if DEBUG
#Preview("Every pill") {
    // As the planner picks them on the demo trip, seen from the lead car.
    let now = Date()
    @MainActor func pill(_ scene: String, confirmed: Bool = false) -> StopPill? {
        let requests = MapDemo.stopBoard(scene, now: now).requests
        var memory = StopPillMemory()
        memory.observe(requests, now: now)
        if confirmed, let request = requests.first { memory.noteOK(request, now: now) }
        return StopPillPlanner.current(requests: requests, memory: memory, now: now)
    }
    let pills = [pill("message"), pill("responder"), pill("responder", confirmed: true), pill("asker")]
        .compactMap { $0 }
    return VStack(spacing: Spacing.m) {
        ForEach(pills.indices, id: \.self) { StopPillView(pill: pills[$0]) { _ in } }
    }
    .padding(Spacing.m)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(.systemGray4))
}
#endif
