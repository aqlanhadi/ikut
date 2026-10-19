import SwiftUI

/// The request the other cars see: who asked, the place, a row per car, and the buttons.
/// Pure view: state in, `actions` out.
struct StopRequestCard: View {
    let state: StopRequestState
    let actions: StopRequestActions

    /// The voter list (and pin choices) is as tall as its rows, and gives way when the card is
    /// squeezed into less room by its parent, then scrolls; the header and the buttons stay put,
    /// so "Agree to Stop" is always reachable on a small screen.
    @State private var listHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.fixedSize(horizontal: false, vertical: true)
            placeCard.fixedSize(horizontal: false, vertical: true)
            tally
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    votes
                    if state.canPin && state.place == nil { pinSection }
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in listHeight = height }
                    })
            }
            .frame(minHeight: min(listHeight ?? 88, 88), maxHeight: listHeight)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            buttons.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 18)
        // The design's 94% white over a blur: thick enough that nothing behind the card reads through.
        .background {
            let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
            shape.fill(.regularMaterial)
            shape.fill(Color(.systemBackground).opacity(0.94))
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: Self.symbol(for: state.type))
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.title2.bold())
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    Text(state.subtitle(now: timeline.date)).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var placeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.red, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(placeTitle).font(.body).lineLimit(2)
                Text(placeDetail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var placeTitle: String {
        guard let place = state.shownPlace else { return "No place yet" }
        return [place.name, state.distanceText].compactMap { $0 }.joined(separator: " · ")
    }

    private var placeDetail: String {
        guard state.shownPlace != nil else { return "The lead car pins where to stop" }
        let who = state.place != nil ? "pinned by the lead car" : "proposed by Car \(state.requesterNumber.map(String.init) ?? "?")"
        return [state.etaText, who].compactMap { $0 }.joined(separator: " · ")
    }

    /// "VOTES", a bar filled by the cars that agreed, then "3 of 4 agreed".
    private var tally: some View {
        let agreed = state.rows.filter { $0.status == .agreed }.count
        let text = "\(agreed) of \(state.rows.count) agreed"
        return HStack(spacing: 10) {
            StatCaption("Votes")
            ProgressView(value: Double(agreed), total: Double(max(state.rows.count, 1)))
                .tint(.green)
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.ikutPositive)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Votes: \(text)")
    }

    private var votes: some View {
        VStack(spacing: 0) {
            ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                HStack(spacing: 12) {
                    CarBadge(number: row.number, colorHex: row.colorHex, size: 26)
                    Text(row.name).font(.body).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Self.statusText(row.status)).font(.subheadline).foregroundStyle(Self.statusColor(row.status))
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Lead car and organizer: pin the proposal or one of the suggestions.
    @ViewBuilder private var pinSection: some View {
        VStack(spacing: 8) {
            if let proposal = state.proposal {
                pinButton("Pin this stop", subtitle: proposal.name, place: proposal, prominent: true)
            }
            ForEach(state.alternatives) { row in
                if let suggestion = row.suggestion {
                    pinButton("Pin \(suggestion.name)", subtitle: "Suggested by Car \(row.number.map(String.init) ?? "?")", place: suggestion, prominent: false)
                }
            }
        }
    }

    private func pinButton(_ title: String, subtitle: String, place: StopPlace, prominent: Bool) -> some View {
        Button { actions.pin(place) } label: {
            VStack(spacing: 0) {
                Text(title).font(.headline).lineLimit(1)
                if prominent { Text(subtitle).font(.caption).lineLimit(1).opacity(0.85) }
                else { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            // Secondary style: the soft accent fill and accent text of the lobby's Share Link button.
            .background(prominent ? Color.ikutAccent.opacity(0.14) : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(prominent ? Color.ikutAccent : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var buttons: some View {
        VStack(spacing: 4) {
            let agreed = state.viewerAgrees
            Button { actions.vote(!agreed) } label: {
                Text(agreed ? (state.place != nil ? "Agreed · Pinned for Everyone" : "Agreed") : "Agree to Stop")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(agreed ? Color.green.opacity(0.16) : Color.accentColor, in: Capsule())
                    .foregroundStyle(agreed ? Color(red: 0.12, green: 0.48, blue: 0.21) : Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint(agreed ? "Double tap to withdraw your agreement" : "")
            Button { actions.suggestAnother() } label: {
                Text("Suggest Another Stop")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            if state.canResolve {
                Button { actions.resolve() } label: {
                    Text(state.place != nil ? "Everyone has arrived" : "Cancel request")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func statusText(_ status: StopRequestState.VoteStatus) -> String {
        switch status {
        case .agreed: "Agreed"
        case .waiting: "Waiting"
        case .suggested: "Suggested another"
        }
    }

    static func statusColor(_ status: StopRequestState.VoteStatus) -> Color {
        switch status {
        case .agreed: Color(red: 0.12, green: 0.48, blue: 0.21)
        case .waiting: .secondary
        case .suggested: Color(red: 0.71, green: 0.28, blue: 0.03)
        }
    }

    static func symbol(for type: EventType) -> String {
        switch type {
        case .stopFuel: "fuelpump.fill"
        case .stopFood: "fork.knife"
        case .stopToilet: "toilet.fill"
        default: "cup.and.saucer.fill"
        }
    }
}

#Preview {
    let rows: [StopRequestState.Row] = [
        .init(carId: "1", number: 1, colorHex: "#2563EB", name: "Aqlan’s Myvi (you)", isMine: true, status: .waiting, suggestion: nil),
        .init(carId: "2", number: 2, colorHex: "#D9480F", name: "Wyna’s X70", isMine: false, status: .agreed, suggestion: nil),
        .init(carId: "3", number: 3, colorHex: "#0F766E", name: "Hafiz’s Hilux", isMine: false, status: .agreed, suggestion: nil),
        .init(carId: "4", number: 4, colorHex: "#7C3AED", name: "Daniel’s City", isMine: false, status: .waiting, suggestion: nil),
    ]
    let place = StopPlace(name: "R&R Tapah", coordinate: .init(latitude: 4, longitude: 101), routeOffset: 18_000, pinnedBy: "x")
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        StopRequestCard(
            state: StopRequestState(
                eventId: "e", type: .stopFuel, requesterCarId: "2", requesterNumber: 2, requesterName: "Wyna",
                askedAt: Date().addingTimeInterval(-60), rows: rows, place: place, proposal: nil, alternatives: [],
                viewerAgrees: false, canPin: false, canResolve: true, viewerOffset: 0, isResolved: false),
            actions: .none)
            .padding(8)
    }
}
