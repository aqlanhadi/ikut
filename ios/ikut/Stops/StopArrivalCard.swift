import SwiftUI

/// The card for a planned stop, opened from the panel's Next stop cell (RoadStops.dc.html): "3 of 4 here" and a
/// row per car, "Here" or "3 min away". With a meeting point this is the meet's count, joining cars included.
/// The lead car's tracker and the organizer also see "Leaving at 12:40" and Leave (D25 4a), with one sentence to
/// confirm because it has no undo; everyone else sees who taps it. Skip comes with a later piece. The counts
/// are worked out from positions; Leave is the card's only write.
struct StopArrivalCard: View {
    var model: TripMapModel
    var stopId: String
    /// Fixed clock for the demo states; live cards re-read the time every few seconds.
    var frozenNow: Date?
    /// The viewer is the trip's organizer (the lead car's tracker is read from the cars).
    var isOrganizer = false
    /// Taps Leave for the stop; true once the write is sent. Nil in demos.
    var leave: (@MainActor (String) async -> StopLeave.Result)?
    var onClose: () -> Void

    /// For the demo: opens on the confirm sentence.
    var startConfirming = false

    @State private var confirming = false
    @State private var leaving = false
    @State private var couldNotLeave = false
    /// Leave is saved on this phone and goes through when it is back online.
    @State private var queued = false

    var body: some View {
        if let frozenNow {
            card(now: frozenNow)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { context in card(now: context.date) }
        }
    }

    @ViewBuilder private func card(now: Date) -> some View {
        if let stop = model.stops.first(where: { $0.id == stopId && $0.isOpen }),
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
                leavingRow(stop)
            } actions: {
                leaveActions(stop, tally: tally)
            }
            .accessibilityIdentifier("stop.arrival")
            .onAppear { if startConfirming { confirming = true } }
        }
    }

    /// "Leaving at 12:40" over "Planned stop" (or "Meeting point"); none without a time.
    @ViewBuilder private func leavingRow(_ stop: PlannedStop) -> some View {
        if let line = StopLeave.leavingLine(stop) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "clock").foregroundStyle(Color.surfaceSecondary).accessibilityHidden(true)
                Text(line).font(.body.weight(.semibold)).monospacedDigit()
                Spacer(minLength: 0)
                Text(stop.isMeeting ? "Meeting point" : "Planned stop").font(.footnote).foregroundStyle(Color.surfaceSecondary)
            }
            .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("stop.arrival.leavingAt")
        }
    }

    /// Leave for the lead car's tracker and the organizer; the others read who taps it.
    @ViewBuilder private func leaveActions(_ stop: PlannedStop, tally: StopArrival.Tally) -> some View {
        let isLeadTracker = model.myCar?.isLead == true && model.isTracker
        let leadHere = tally.rows.contains { $0.car.isLead && $0.isHere }
        if StopLeave.canLeave(
            stop: stop, isLeadTracker: isLeadTracker, isOrganizer: isOrganizer, tripStarted: model.tripStarted,
            leadHere: leadHere
        ) {
            let waiting = StopLeave.waitingLine(tally.rows, leaving: model.myCarId)
            VStack(spacing: Spacing.xs) {
                if queued {
                    Text("No signal. Leave goes through when you’re back online.")
                        .font(.footnote).foregroundStyle(Color.surfaceSecondary).multilineTextAlignment(.center)
                        .accessibilityIdentifier("stop.leave.queued")
                } else if couldNotLeave {
                    Text("That didn’t go through. Try Leave again.")
                        .font(.footnote).foregroundStyle(Color.surfaceSecondary).accessibilityIdentifier("stop.leave.retry")
                }
                if confirming {
                    Text(StopLeave.confirmSentence(stop: stop, waiting: waiting))
                        .font(.subheadline).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .accessibilityIdentifier("stop.leave.confirm.text")
                    StopActionButton(title: "Leave", style: .primary, height: 52, id: "stop.leave.confirm") { send(stop) }
                        .disabled(leaving)
                    StopActionButton(title: "Not yet, we’ll wait", style: .ghost, height: 44, id: "stop.leave.cancel") {
                        confirming = false
                    }
                } else {
                    StopActionButton(title: "Leave", subtitle: waiting, style: .primary, height: 56, id: "stop.leave") {
                        couldNotLeave = false
                        confirming = true
                    }
                }
            }
        } else if model.tripStarted {
            Text(StopLeave.waitingForLead(leadCar: model.cars.first { $0.isLead }))
                .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .accessibilityIdentifier("stop.leave.waiting")
        }
    }

    private func send(_ stop: PlannedStop) {
        guard let leave, let id = stop.id, !leaving else { return }
        leaving = true
        Task {
            let result = await leave(id)
            leaving = false
            // Sent: the stop is left, so the card closes by itself when the stop reaches this phone.
            switch result {
            case .sent: break
            case .queued: queued = true; confirming = false
            case .refused: couldNotLeave = true; confirming = false
            }
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
        case .unknown, .lastSeenHere:
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
