import Foundation

/// Decides when positions are written: throttled, one write in flight, latest-only.
///
/// - A new fix is written at most once per `minInterval` (5 s).
/// - With no new fix, the newest position is re-written after `movingInterval` (10 s) when moving,
///   or `heartbeatInterval` (30 s) when stationary, so followers see the car is alive.
/// - While the convoy is stopped and the car is at rest (`lowPower`, D124) the newest position is re-written every
///   `lowHeartbeatInterval` (45 s, under the 60 s a car counts as stale) whatever its speed, and a fix that shows
///   nothing new (`urgent: false`) waits for that heartbeat. A fix that shows the car moved (`urgent: true`) goes out
///   after `minInterval` as usual.
/// - Only one write is in flight. Firestore acknowledges a write only once the server has it, so
///   while the network is down the write simply stays in flight; fixes arriving meanwhile replace
///   the single pending position instead of adding writes. When the write completes, at most one
///   follow-up goes out, carrying the newest fix. There is never a backlog of our own.
@MainActor
final class PositionPublisher {
    struct Timing: Sendable {
        var minInterval: TimeInterval = 5
        var movingInterval: TimeInterval = 10
        var heartbeatInterval: TimeInterval = 30
        /// The heartbeat of a car at rest while the convoy is stopped. Cars are stale after 60 s, so this leaves 15 s.
        var lowHeartbeatInterval: TimeInterval = 45
        /// At or above this speed (m/s) the car counts as moving.
        var movingSpeed: Double = 1
    }

    private let tripId: String
    private let carId: String
    private let writer: PositionWriting
    private let clock: TrackingClock
    private let timing: Timing

    private var latest: Position?
    /// True when `latest` has not been written yet.
    private var dirty = false
    private var lastSendAt: TimeInterval?
    private var inFlight = false
    private var stopped = false
    private(set) var lowPower = false
    /// The pending position shows the car moved: it is not held for the low-power heartbeat.
    private var urgent = true
    /// Refreshes what changes without a fix (the battery) on a re-write of an old position.
    var refresh: (@MainActor (Position) -> Position)?
    private var wake: Task<Void, Never>?
    private var wakeDeadline: TimeInterval?

    private(set) var writeCount = 0

    init(tripId: String, carId: String, writer: PositionWriting, clock: TrackingClock, timing: Timing = Timing()) {
        self.tripId = tripId
        self.carId = carId
        self.writer = writer
        self.clock = clock
        self.timing = timing
    }

    /// Records the newest position, replacing any unsent one.
    func submit(_ position: Position, urgent: Bool = true) {
        guard !stopped else { return }
        latest = position
        self.urgent = (dirty && self.urgent) || urgent
        dirty = true
        evaluate()
    }

    /// Slow heartbeat on or off (the convoy is stopped and this car is at rest, or not). Re-plans the next write.
    func setLowPower(_ on: Bool) {
        guard on != lowPower else { return }
        lowPower = on
        evaluate()
    }

    /// Drops the pending position and ignores any write still in flight.
    func stop() {
        stopped = true
        latest = nil
        dirty = false
        wake?.cancel()
        wake = nil
        wakeDeadline = nil
    }

    private func evaluate() {
        guard !stopped, !inFlight, let position = latest else { return }
        let now = clock.now
        let due: TimeInterval
        if let lastSendAt {
            if dirty {
                due = lastSendAt + (lowPower && !urgent ? timing.lowHeartbeatInterval : timing.minInterval)
            } else if lowPower {
                due = lastSendAt + timing.lowHeartbeatInterval
            } else {
                let moving = position.speed >= timing.movingSpeed
                due = lastSendAt + (moving ? timing.movingInterval : timing.heartbeatInterval)
            }
        } else {
            due = now
        }
        if now >= due {
            send(position, at: now)
        } else {
            schedule(at: due)
        }
    }

    private func send(_ position: Position, at now: TimeInterval) {
        var position = position
        if !dirty, let refresh { position = refresh(position) }
        urgent = false
        wake?.cancel()
        wake = nil
        wakeDeadline = nil
        inFlight = true
        dirty = false
        lastSendAt = now
        writeCount += 1
        Task {
            var failed = false
            do {
                try await writer.write(position, tripId: tripId, carId: carId)
            } catch {
                failed = true
            }
            writeFinished(failed: failed)
        }
    }

    private func writeFinished(failed: Bool) {
        inFlight = false
        guard !stopped else { return }
        // Retry the failed position later unless a newer one has replaced it.
        if failed { dirty = true }
        evaluate()
    }

    private func schedule(at deadline: TimeInterval) {
        if wakeDeadline == deadline, wake != nil { return }
        wake?.cancel()
        wakeDeadline = deadline
        wake = Task { [clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self.wake = nil
            self.wakeDeadline = nil
            self.evaluate()
        }
    }
}
