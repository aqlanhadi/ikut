import SwiftUI

/// The card for a planned stop, opened from the panel's Next stop cell (RoadStops.dc.html): "3 of 4 here" and a
/// row per car, "Here" or "3 min away". With a meeting point this is the meet's count, joining cars included.
/// Read-only: Leave and Skip come with later pieces. It reads positions only, so it writes nothing.
struct StopArrivalCard: View {
    var model: TripMapModel
    var stopId: String
    /// Fixed clock for the demo states; live cards re-read the time every few seconds.
    var frozenNow: Date?
    var onClose: () -> Void

    var body: some View {
        if let frozenNow {
            card(now: frozenNow)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in card(now: context.date) }
        }
    }

    @ViewBuilder private func card(now: Date) -> some View {
        if let stop = model.stops.first(where: { $0.id == stopId && $0.isActive }),
           let target = StopArrival.target(stopId: stopId, in: model.stops) {
            let tally = StopArrival.tally(
                target: target, convoy: model.convoy.convoy, joining: model.convoy.joining, pace: model.stopPace(), now: now)
            let mine = tally.rows.first { $0.id == model.myCarId }
            StopCardFrame(title: stop.name, subtitle: subtitle(stop), onClose: onClose) {
                if let mine { me(mine.status, stop: stop) }
                progress(tally)
                VStack(spacing: 0) {
                    ForEach(Array(tally.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider() }
                        carRow(row)
                    }
                }
            } actions: {
            }
            .accessibilityIdentifier("stop.arrival")
        }
    }

    private func subtitle(_ stop: PlannedStop) -> String {
        if stop.isMeeting {
            return stop.meetAt.map { "Meeting point · \(ConvoyFormat.clock($0))" } ?? "Meeting point"
        }
        return ([stop.kind.word] + (stop.minutes.map { ["\($0) min planned"] } ?? [])).joined(separator: " · ")
    }

    /// "You're here" in a pill, or how far my car has to go ("18 km ahead", "About 12 min · stop 1 of 2").
    @ViewBuilder private func me(_ status: StopArrival.Status, stop: PlannedStop) -> some View {
        switch status {
        case .here:
            Text("You’re here")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.ikutPositive)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.ikutPositive.opacity(0.14), in: Capsule())
                .accessibilityIdentifier("stop.arrival.you")
        case .away(let distance, let seconds):
            let inConvoy = model.convoy.convoy.contains { $0.id == model.myCarId }
            let place = StopArrival.place(of: stopId, in: model.stops)
            let second = ([seconds.map { "About \(ConvoyFormat.duration($0))" }]
                + [place.flatMap { stop.isMeeting ? nil : "stop \($0.index) of \($0.count)" }]).compactMap { $0 }.joined(separator: " · ")
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: 0) {
                    if let distance { Text("\(ConvoyFormat.distance(distance)) \(inConvoy ? "ahead" : "away")").font(.body) }
                    if !second.isEmpty { Text(second).font(.footnote).foregroundStyle(Color.surfaceSecondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .accessibilityElement(children: .combine)
        case .unknown:
            EmptyView()
        }
    }

    /// HERE, a segment per car (green once there), "3 of 4 here".
    private func progress(_ tally: StopArrival.Tally) -> some View {
        HStack(spacing: Spacing.m) {
            Text("HERE").font(.caption2.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
            HStack(spacing: 3) {
                ForEach(tally.rows) { row in
                    Capsule().fill(row.isHere ? Color.ikutPositive : Color(.systemGray5)).frame(height: 6)
                }
            }
            Text(tally.title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(tally.here == 0 ? Color.surfaceSecondary : Color.ikutPositive)
                .monospacedDigit()
        }
        .padding(.horizontal, Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tally.title)
        .accessibilityIdentifier("stop.arrival.count")
    }

    private func carRow(_ row: StopArrival.Row) -> some View {
        HStack(spacing: Spacing.m) {
            CarBadge(number: row.car.number, colorHex: row.car.color, size: 26)
            Text(row.car.name).font(.body).lineLimit(1)
            Spacer(minLength: Spacing.s)
            if row.isHere {
                Label("Here", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ikutPositive)
            } else {
                Text(StopArrival.words(row.status))
                    .font(.subheadline)
                    .foregroundStyle(Color.surfaceSecondary)
                    .monospacedDigit()
            }
        }
        .frame(minHeight: 46)
        .padding(.horizontal, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
