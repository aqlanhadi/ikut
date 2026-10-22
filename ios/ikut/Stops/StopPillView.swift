import SwiftUI

/// The pill at the top of the map for a stop. A question has one big button (64 pt or more, one
/// word); the others are a slim line. It never covers the route: the map stays visible.
struct StopPillView: View {
    let pill: StopPill
    /// The one big button: Yes, or Pin this stop.
    var onButton: (_ eventId: String) -> Void

    var body: some View {
        Group {
            switch pill {
            case .question(let eventId, let symbol, let title, let detail, let button, let isPin):
                question(eventId: eventId, symbol: symbol, title: title, detail: detail, button: button, isPin: isPin)
            case .confirm(let symbol, let title, let detail):
                slim(symbol: symbol, title: title, detail: detail, dark: false, positive: true, id: "stop.pill.confirm")
            case .pinned(let symbol, let title, let detail):
                slim(symbol: symbol, title: title, detail: detail, dark: true, positive: false, id: "stop.pill.pinned")
            case .asked(let title, let detail):
                slim(symbol: "checkmark", title: title, detail: detail, dark: false, positive: true, id: "stop.pill.asked")
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func question(
        eventId: String, symbol: String, title: String, detail: String, button: String, isPin: Bool
    ) -> some View {
        VStack(spacing: Spacing.m) {
            HStack(spacing: Spacing.m) {
                StopReasonIcon(symbol: symbol, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stop.pill.text")
            Button { onButton(eventId) } label: {
                Text(button)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(isPin ? Color.ikutAccent : Color(red: 0.12, green: 0.55, blue: 0.25), in: Capsule())
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

    private func slim(symbol: String, title: String, detail: String, dark: Bool, positive: Bool, id: String) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(positive ? Color.ikutPositive : (dark ? Color.white.opacity(0.2) : Color.orange), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(dark ? Color.white.opacity(0.75) : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background {
            if dark {
                Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.12))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }
}

#if DEBUG
#Preview("Every pill") {
    // As the planner picks them on the demo trip, seen from the lead car.
    let now = Date()
    @MainActor func pill(_ scene: String, answered: Bool = false) -> StopPill? {
        let requests = MapDemo.stopBoard(scene, now: now).requests
        var memory = StopPillMemory()
        memory.observe(requests, now: now)
        if answered, let request = requests.first { memory.noteAnswered(request, answer: .yes, now: now) }
        return StopPillPlanner.current(requests: requests, memory: memory, now: now)
    }
    let pills = [pill("lead"), pill("responder"), pill("responder", answered: true), pill("pinned"), pill("asker")]
        .compactMap { $0 }
    return VStack(spacing: Spacing.m) {
        ForEach(pills.indices, id: \.self) { StopPillView(pill: pills[$0]) { _ in } }
    }
    .padding(Spacing.m)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color(.systemGray4))
}
#endif
