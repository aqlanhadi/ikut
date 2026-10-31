import Foundation
import CoreLocation
import UIKit

/// Broadcasts this phone's car position while a trip is active. Used on the tracker phone only.
///
/// Fixes from the `LocationSource` go through `PositionBuilder` (offsets, heading, speed) and then
/// `PositionPublisher` (throttle, one write in flight, latest-only).
@MainActor
final class TrackingService {
    private let source: LocationSource
    private let writer: PositionWriting
    private let clock: TrackingClock
    private let batteryLevel: @MainActor () -> Float
    private let timing: PositionPublisher.Timing

    private var builder: PositionBuilder?
    private var publisher: PositionPublisher?
    private var generation = 0

    private(set) var isTracking = false
    /// The convoy is stopped (D124), as `TripSession` last said. Kept across a restart of tracking.
    private(set) var convoyStopped = false
    /// Low power is on: this car has been at rest through a stopped phase.
    private(set) var power: TrackingPower = .full
    /// Where the car last was at rest, and since when (the clock's time); the settle timer runs from it.
    private var restAnchor: CLLocationCoordinate2D?
    private var restSince: TimeInterval = 0
    private var restTask: Task<Void, Never>?
    /// Called on the main actor with every fix that was published, after the position is built.
    var onFix: ((LocationFix) -> Void)?
    private var fixWaiter: CheckedContinuation<LocationFix?, Never>?

    init(
        source: LocationSource? = nil,
        writer: PositionWriting = FirestorePositionWriter(),
        clock: TrackingClock? = nil,
        timing: PositionPublisher.Timing = .init(),
        batteryLevel: @escaping @MainActor () -> Float = { UIDevice.current.batteryLevel }
    ) {
        self.source = source ?? CoreLocationSource()
        self.writer = writer
        self.clock = clock ?? SystemTrackingClock()
        self.timing = timing
        self.batteryLevel = batteryLevel
    }

    /// Starts location updates and position writes. Restarts if already tracking.
    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?) {
        resolveFirstFix(nil)
        stop()
        generation += 1
        let current = generation
        isTracking = true
        UIDevice.current.isBatteryMonitoringEnabled = true
        builder = PositionBuilder(mainRoute: mainRoute, carRoute: carRoute)
        let publisher = PositionPublisher(
            tripId: tripId, carId: carId, writer: writer, clock: clock, timing: timing)
        // A re-write of an old position (heartbeat) still carries today's battery.
        publisher.refresh = { [batteryLevel] position in
            var position = position
            position.battery = PositionBuilder.battery(batteryLevel())
            return position
        }
        self.publisher = publisher
        power = .full
        restAnchor = nil
        if convoyStopped { armRestTimer() }
        source.start { [weak self] fix in
            Task { @MainActor in self?.handle(fix, generation: current) }
        }
    }

    /// Waits for one fix without tracking, then stops location updates. Nil if cancelled, if
    /// tracking is already running, or if another wait is pending.
    func firstFix() async -> LocationFix? {
        guard !isTracking, fixWaiter == nil else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fixWaiter = continuation
                source.start { [weak self] fix in
                    Task { @MainActor in self?.resolveFirstFix(fix) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveFirstFix(nil) }
        }
    }

    private func resolveFirstFix(_ fix: LocationFix?) {
        guard let waiter = fixWaiter else { return }
        fixWaiter = nil
        source.stop()
        waiter.resume(returning: fix)
    }

    /// Stops location updates immediately and drops anything not yet written.
    func stop() {
        guard isTracking else { return }
        isTracking = false
        generation += 1
        source.stop()
        publisher?.stop()
        publisher = nil
        builder = nil
        restTask?.cancel()
        restTask = nil
        power = .full
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func handle(_ fix: LocationFix, generation: Int) {
        guard isTracking, generation == self.generation, var builder, let publisher else { return }
        let position = builder.build(from: fix, battery: PositionBuilder.battery(batteryLevel()))
        self.builder = builder
        // Before a stopped phase the anchor just follows the car, so it begins where the car is when the phase does.
        if !convoyStopped { restAnchor = fix.coordinate }
        let moved = convoyStopped && noteMovement(of: fix)
        publisher.submit(position, urgent: power == .full || moved)
        if moved, power == .low { setPower(.full) }
        onFix?(fix)
    }

    // MARK: - Low power while the convoy is stopped (D124)

    /// How far from where it rested a car counts as moved, in meters: the rest radius `MoveOff` uses.
    nonisolated static let restRadius: CLLocationDistance = ConvoyStop.restRadius
    /// How long a car at rest in a stopped phase waits before dropping to low power: the settle time `MoveOff` uses.
    nonisolated static let settleTime: TimeInterval = ConvoyStop.settleTime

    /// `TripSession` says the convoy is stopped (We’ve stopped) or not (Continue, the 90 minute cap, the trip ending).
    /// Only a stopped phase can lower the power, and ending it brings full accuracy back at once.
    func setConvoyStopped(_ stopped: Bool) {
        guard stopped != convoyStopped else { return }
        convoyStopped = stopped
        if stopped {
            if isTracking { armRestTimer() }
        } else {
            restTask?.cancel()
            restTask = nil
            if power == .low { setPower(.full) }
        }
    }

    /// True when the fix shows the car is moving (a valid speed over `parkedSpeed`, the same speed `MoveOff` reads) or
    /// is more than `restRadius` from where it rested; the place and the settle timer then start afresh from it.
    private func noteMovement(of fix: LocationFix) -> Bool {
        let speeding = fix.speed >= ConvoyOrdering.Config.default.parkedSpeed
        let here = fix.coordinate
        if let anchor = restAnchor, !speeding {
            let d = CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)
                .distance(from: CLLocation(latitude: here.latitude, longitude: here.longitude))
            if d <= Self.restRadius { return false }
        } else if restAnchor == nil, !speeding {
            restAnchor = here
            return false
        }
        restAnchor = here
        if power == .full { armRestTimer() }
        return true
    }

    /// Drops to low power after `settleTime` without a moving fix; a fix that moved re-arms it.
    private func armRestTimer() {
        restTask?.cancel()
        restSince = clock.now
        let deadline = restSince + Self.settleTime
        let current = generation
        restTask = Task { [clock] in
            do { try await clock.sleep(until: deadline) } catch { return }
            guard !Task.isCancelled else { return }
            self.restTimerFired(generation: current)
        }
    }

    private func restTimerFired(generation: Int) {
        guard isTracking, convoyStopped, generation == self.generation, power == .full else { return }
        setPower(.low)
    }

    private func setPower(_ new: TrackingPower) {
        guard new != power else { return }
        power = new
        source.setPower(new)
        publisher?.setLowPower(new == .low)
        if new == .full, convoyStopped { armRestTimer() }
    }
}
